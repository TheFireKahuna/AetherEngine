import CryptoKit
import CoreVideo
import Foundation
import Metal
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AV1 film grain on the GPU (docs/software-route-gpu.md Part 5), against the normative process: libdav1d's own grain,
/// which is verified bit exact on the Argon conformance streams, and the Argon streams' own checksums.
struct FilmGrainTests {

    // MARK: - Decoding

    /// libdav1d over `packets`, into slabs of `allocator`; `exportGrain` hands grain over as parameters instead of
    /// applying it. Every picture goes to `body`, in output order. `threads` 0 is libdav1d's default (one per core).
    static func decode(_ packets: [[UInt8]], allocator: DecodeFrameAllocator, exportGrain: Bool, threads: Int32 = 0,
                       _ body: (UnsafeMutablePointer<AVFrame>) throws -> Void) throws {
        let codec = try #require(avcodec_find_decoder_by_name("libdav1d"))
        var context = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&context) }
        let ctx = try #require(context)
        allocator.install(on: ctx)
        ctx.pointee.thread_count = threads
        if exportGrain { ctx.pointee.export_side_data |= Int32(AV_CODEC_EXPORT_DATA_FILM_GRAIN) }
        // Every operating point's frames, as the conformance checksums cover them.
        var options: OpaquePointer?
        av_dict_set(&options, "alllayers", "1", 0)
        defer { av_dict_free(&options) }
        try #require(avcodec_open2(ctx, codec, &options) >= 0)
        var packet = av_packet_alloc()
        var frame = av_frame_alloc()
        defer { av_packet_free(&packet); av_frame_free(&frame) }
        func drain() throws {
            while avcodec_receive_frame(ctx, frame) >= 0 {
                try body(frame!)
                av_frame_unref(frame)
            }
        }
        for unit in packets {
            try #require(av_new_packet(packet, Int32(unit.count)) >= 0)
            unit.withUnsafeBytes { _ = memcpy(packet!.pointee.data, $0.baseAddress!, unit.count) }
            let sent = avcodec_send_packet(ctx, packet)
            av_packet_unref(packet)
            try #require(sent >= 0 || sent == FFmpegErr.eagain, "send \(sent)")
            try drain()
        }
        _ = avcodec_send_packet(ctx, nil)
        try drain()
    }

    /// The picture's planes in a buffer the finisher reads: its own slab, or a copy in one.
    static func planes(of frame: UnsafeMutablePointer<AVFrame>, allocator: DecodeFrameAllocator)
        throws -> (planes: PlanarFrameFinisher.Planes, release: () -> Void) {
        if let slab = allocator.slab(of: frame), let own = PlanarFrameFinisher.planes(of: frame, in: slab) {
            return (own, {})
        }
        let copy = try #require(allocator.copy(frame))
        return (copy.planes, { allocator.release(copy.slab) })
    }

    /// A plan that reads `frame`'s format, at an output that takes every source bit.
    static func plan(for frame: UnsafePointer<AVFrame>, chroma: SoftwareVideoDecoder.OutputFormat.Chroma? = nil,
                     depth: SoftwareVideoDecoder.OutputFormat.Depth = .sixteen, grain: Bool) throws -> PlanarFrameFinisher.Plan {
        let format = AVPixelFormat(rawValue: frame.pointee.format)
        let desc = try #require(av_pix_fmt_desc_get(format)?.pointee)
        let rgb = desc.flags & UInt64(AV_PIX_FMT_FLAG_RGB) != 0
        let own: SoftwareVideoDecoder.OutputFormat.Chroma = rgb || desc.log2_chroma_w == 0 ? .yuv444
            : (desc.log2_chroma_h == 0 ? .yuv422 : .yuv420)
        let output = SoftwareVideoDecoder.OutputFormat(chroma: chroma ?? own, depth: depth, fullRange: false)
        return try #require(PlanarFrameFinisher.plan(source: format, output: output, sourceFullRange: false,
                                                     chromaLocation: AVCHROMA_LOC_LEFT, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                                                     grain: grain), "plan for \(String(cString: desc.name))")
    }

    // MARK: - Hashing (dav1d's md5 output: visible rows, luma then Cb, Cr; samples above 8 bits as 16-bit LE)

    static func hash(_ md5: inout Insecure.MD5, frame: UnsafePointer<AVFrame>, planes base: UnsafeRawPointer,
                     offsets: [Int], linesizes: [Int]) {
        let desc = av_pix_fmt_desc_get(AVPixelFormat(rawValue: frame.pointee.format))!.pointee
        let bytes = desc.comp.0.depth > 8 ? 2 : 1
        let w = Int(frame.pointee.width), h = Int(frame.pointee.height)
        for plane in 0..<(desc.nb_components < 3 ? 1 : 3) {
            let sx = plane == 0 ? 0 : Int(desc.log2_chroma_w), sy = plane == 0 ? 0 : Int(desc.log2_chroma_h)
            let pw = (w + (1 << sx) - 1) >> sx, ph = (h + (1 << sy) - 1) >> sy
            for y in 0..<ph {
                md5.update(bufferPointer: UnsafeRawBufferPointer(start: base + offsets[plane] + y * linesizes[plane], count: pw * bytes))
            }
        }
    }

    static func hashDecoded(_ md5: inout Insecure.MD5, frame: UnsafePointer<AVFrame>) {
        let data = [frame.pointee.data.0, frame.pointee.data.1, frame.pointee.data.2]
        let offsets = data.map { Int(bitPattern: $0) - Int(bitPattern: frame.pointee.data.0) }
        let linesizes = [frame.pointee.linesize.0, frame.pointee.linesize.1, frame.pointee.linesize.2].map(Int.init)
        hash(&md5, frame: frame, planes: UnsafeRawPointer(frame.pointee.data.0!), offsets: offsets, linesizes: linesizes)
    }

    // MARK: - The single pass equals the grained picture's

    /// The finisher fed the ungrained picture and its parameters writes, code for code, what it writes from libdav1d's
    /// own grained picture: grain inside the one pass is the normative grain. At the source's subsampling (pack) and
    /// resampled to 4:2:2 and 4:4:4 (every chroma tap grained on its own).
    @Test("the finisher's grain equals libdav1d's grained picture through the finisher", arguments: [
        SoftwareVideoDecoder.OutputFormat.Chroma.yuv420, .yuv422, .yuv444,
    ])
    func fusedEqualsReference(chroma: SoftwareVideoDecoder.OutputFormat.Chroma) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let allocator = try #require(DecodeFrameAllocator(device: device))
        let finisher = try PlanarFrameFinisher(device: device)
        var reference: [[UInt8]] = []
        try Self.decode(Dav1dSlabDecodeTests.temporalUnits, allocator: allocator, exportGrain: false) { frame in
            let (planes, release) = try Self.planes(of: frame, allocator: allocator)
            defer { release() }
            let plan = try Self.plan(for: frame, chroma: chroma, grain: false)
            reference.append(try Self.finished(finisher, planes: planes, plan: plan, frame: frame, grain: nil))
        }
        var ours: [[UInt8]] = []
        var grained = 0
        try Self.decode(Dav1dSlabDecodeTests.temporalUnits, allocator: allocator, exportGrain: true) { frame in
            let grain = FilmGrainParameters(frame: frame)
            if grain != nil { grained += 1 }
            let (planes, release) = try Self.planes(of: frame, allocator: allocator)
            defer { release() }
            let plan = try Self.plan(for: frame, chroma: chroma, grain: grain != nil)
            ours.append(try Self.finished(finisher, planes: planes, plan: plan, frame: frame, grain: grain))
        }
        #expect(grained > 0, "the fixture carries film grain")
        #expect(ours.count == reference.count)
        for (i, (a, b)) in zip(ours, reference).enumerated() { #expect(a == b, "picture \(i)") }
    }

    /// The display buffer's planes, rows packed.
    static func finished(_ finisher: PlanarFrameFinisher, planes: PlanarFrameFinisher.Planes, plan: PlanarFrameFinisher.Plan,
                         frame: UnsafePointer<AVFrame>, grain: FilmGrainParameters?) throws -> [UInt8] {
        let width = Int(frame.pointee.width), height = Int(frame.pointee.height)
        var buffer: CVPixelBuffer?
        let attributes = NSMutableDictionary(dictionary: DisplayBufferWriter.displayBufferAttributes as NSDictionary)
        let type = plan.wideOutput
            ? (plan.outputLog2 == [1, 1] ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
               : plan.outputLog2 == [1, 0] ? kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange : kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange)
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        try #require(CVPixelBufferCreate(nil, width, height, type, attributes, &buffer) == kCVReturnSuccess)
        let pb = try #require(buffer)
        try #require(finisher.finish(planes, plan: plan, width: width, height: height, into: pb, grain: grain))
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var out: [UInt8] = []
        for p in 0..<CVPixelBufferGetPlaneCount(pb) {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(pb, p))
            let rowBytes = CVPixelBufferGetWidthOfPlane(pb, p) * (plan.wideOutput ? 2 : 1) * (p == 0 ? 1 : 2)
            for y in 0..<CVPixelBufferGetHeightOfPlane(pb, p) {
                out += UnsafeRawBufferPointer(start: base + y * CVPixelBufferGetBytesPerRowOfPlane(pb, p), count: rowBytes)
            }
        }
        return out
    }

    // MARK: - Argon

    static let argon = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "argon-dl/extracted/argon")

    /// dav1d's Argon set: everything but large-scale tiles and the stress streams.
    static let argonDirectories = [
        "profile0_core", "profile0_core_special", "profile0_not_annexb", "profile0_not_annexb_special",
        "profile1_core", "profile1_core_special", "profile1_not_annexb", "profile1_not_annexb_special",
        "profile2_core", "profile2_core_special", "profile2_not_annexb", "profile2_not_annexb_special",
        "profile_switching",
    ]

    /// The decoder's input chunks: Annex B's OBUs one at a time (their sizes are the length fields; dav1d parses an
    /// OBU without a size field to the end of its chunk), Section 5's temporal units.
    static func chunks(_ data: Data, annexB: Bool) -> [[UInt8]]? {
        let bytes = [UInt8](data)
        var i = 0
        func leb128() -> Int? {
            var value = 0
            for k in 0..<8 {
                guard i < bytes.count else { return nil }
                let b = bytes[i]; i += 1
                value |= Int(b & 0x7F) << (7 * k)
                if b & 0x80 == 0 { return value }
            }
            return nil
        }
        var out: [[UInt8]] = []
        if annexB {
            while i < bytes.count {
                guard let temporal = leb128() else { return nil }
                let temporalEnd = i + temporal
                while i < temporalEnd {
                    guard let frameUnit = leb128() else { return nil }
                    let frameEnd = i + frameUnit
                    while i < frameEnd {
                        guard let length = leb128(), i + length <= bytes.count else { return nil }
                        out.append(Array(bytes[i..<(i + length)]))
                        i += length
                    }
                }
            }
            return out
        }
        var start = 0
        while i < bytes.count {
            let header = bytes[i]
            if (header >> 3) & 0xF == 2, i > start { out.append(Array(bytes[start..<i])); start = i }
            i += 1 + ((header & 0x4) != 0 ? 1 : 0)
            guard header & 0x2 != 0, let length = leb128() else { return nil }
            i += length
        }
        if i > start { out.append(Array(bytes[start..<min(i, bytes.count)])) }
        return out
    }

    /// Opt-in (`AETHER_ARGON=1`, with the streams beside the repositories): 1,512 streams, minutes of decoding.
    static let argonEnabled = ProcessInfo.processInfo.environment["AETHER_ARGON"] == "1"
        && FileManager.default.fileExists(atPath: argon.path)

    /// Every Argon stream with film grain (its checksum with grain differs from the one without), decoded with libdav1d's
    /// grain off and the GPU's applied, against Argon's checksum of the grained output. A miss is decoded again with
    /// libdav1d applying grain itself, so a harness fault is named as one rather than passing as a grain fault.
    @Test("Argon: the GPU's grain gives the conformance checksums", .enabled(if: FilmGrainTests.argonEnabled),
          .timeLimit(.minutes(30)), arguments: argonDirectories)
    func argonConformance(directory: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let allocator = try #require(DecodeFrameAllocator(device: device))
        let finisher = try PlanarFrameFinisher(device: device)
        let root = Self.argon.appending(path: directory)
        let streams = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "streams").path)
            .filter { $0.hasSuffix(".obu") }.sorted()
        var checked = 0, failures: [String] = []
        for name in streams {
            let stem = String(name.dropLast(4))
            func expected(_ kind: String) throws -> String {
                String(try String(contentsOf: root.appending(path: "\(kind)/\(stem).md5"), encoding: .utf8).prefix(32))
            }
            let reference = try expected("md5_ref")
            guard try expected("md5_no_film_grain") != reference else { continue }
            let packets = try #require(Self.chunks(try Data(contentsOf: root.appending(path: "streams/\(name)")),
                                                   annexB: !directory.contains("not_annexb")), "\(name) framing")

            var ours = Insecure.MD5()
            // One decoder thread a stream: the directories run side by side, about one thread a core in all.
            try Self.decode(packets, allocator: allocator, exportGrain: true, threads: 1) { frame in
                guard let grain = FilmGrainParameters(frame: frame) else { Self.hashDecoded(&ours, frame: frame); return }
                let (planes, release) = try Self.planes(of: frame, allocator: allocator)
                defer { release() }
                let plan = try Self.plan(for: frame, grain: true)
                let out = try #require(device.makeBuffer(length: planes.buffer.length, options: .storageModeShared))
                try #require(finisher.grainedPlanes(planes, plan: plan, width: Int(frame.pointee.width),
                                                    height: Int(frame.pointee.height), grain: grain, into: out))
                Self.hash(&ours, frame: frame, planes: UnsafeRawPointer(out.contents()),
                          offsets: (0..<3).map { Int(planes.offsets[$0]) }, linesizes: (0..<3).map { Int(planes.linesizes[$0]) })
            }
            let digest = ours.finalize().map { String(format: "%02x", $0) }.joined()
            checked += 1
            guard digest != reference else { continue }
            var control = Insecure.MD5()
            try Self.decode(packets, allocator: allocator, exportGrain: false, threads: 1) { Self.hashDecoded(&control, frame: $0) }
            let controlDigest = control.finalize().map { String(format: "%02x", $0) }.joined()
            failures.append(controlDigest == reference ? "\(name): \(digest), not \(reference)"
                            : "\(name): libdav1d's own grain gives \(controlDigest) too (harness)")
        }
        #expect(failures.isEmpty, "\(failures.count) of \(checked): \(failures.prefix(20).joined(separator: "; "))")
        #expect(checked > 0)
    }
}
