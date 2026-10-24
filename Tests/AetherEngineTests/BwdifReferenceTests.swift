import Foundation
import Metal
import Testing
import AetherLibavfilter
import AetherLibavutil
@testable import AetherEngine

/// The deinterlacer against its reference: the same frames through libavfilter's bwdif
/// (`bwdif=mode=send_field|send_frame:parity=auto:deint=interlaced`) and through ``BwdifWindow`` plus the GPU's
/// `pf_bwdif`, compared output by output: how many, their timestamps, and every sample of every plane. bwdif has no
/// specification beyond FFmpeg's C, so this is the conformance test.
///
/// The pictures have a static third (bwdif's zero-difference shortcut), a moving third (both interpolation branches
/// and the spatial check) and a noise third (clipping), on every plane. A semi-planar or packed source is compared
/// with bwdif on its planar equivalent, the picture the deinterlacer writes.
struct BwdifReferenceTests {

    struct Case: CustomStringConvertible, Sendable {
        var format: AVPixelFormat
        var width = 64
        var height = 48
        var topFieldFirst = true
        var fieldRate = true
        var frames = 7
        /// A picture flagged progressive (passed through), one with `repeat_pict` set, one without a timestamp.
        var progressiveAt: Int? = nil
        var repeatAt: Int? = nil
        var noPTSAt: Int? = nil

        var description: String {
            "\(av_get_pix_fmt_name(format).map { String(cString: $0) } ?? "?") \(width)x\(height) "
                + "\(topFieldFirst ? "tff" : "bff") \(fieldRate ? "field" : "frame") frames=\(frames)"
                + (progressiveAt.map { " progressive@\($0)" } ?? "") + (repeatAt.map { " repeat@\($0)" } ?? "")
                + (noPTSAt.map { " nopts@\($0)" } ?? "")
        }
    }

    static let formats: [AVPixelFormat] = [
        AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUV422P, AV_PIX_FMT_YUV444P, AV_PIX_FMT_YUV411P, AV_PIX_FMT_YUV440P,
        AV_PIX_FMT_YUV410P, AV_PIX_FMT_YUV420P10LE, AV_PIX_FMT_YUV422P10LE, AV_PIX_FMT_YUV444P12LE,
        AV_PIX_FMT_YUV420P16LE, AV_PIX_FMT_GRAY8, AV_PIX_FMT_GRAY16LE, AV_PIX_FMT_NV12, AV_PIX_FMT_P010LE,
        AV_PIX_FMT_UYVY422, AV_PIX_FMT_YUV420P10BE,
    ]

    static let cases: [Case] = formats.map { Case(format: $0) } + [
        Case(format: AV_PIX_FMT_YUV420P, topFieldFirst: false),
        Case(format: AV_PIX_FMT_YUV420P, fieldRate: false),
        Case(format: AV_PIX_FMT_YUV420P, topFieldFirst: false, fieldRate: false),
        Case(format: AV_PIX_FMT_YUV420P, width: 66, height: 50),
        Case(format: AV_PIX_FMT_YUV420P, width: 63, height: 37),
        Case(format: AV_PIX_FMT_YUV422P10LE, width: 63, height: 37, topFieldFirst: false),
        Case(format: AV_PIX_FMT_YUV420P, width: 16, height: 8),
        Case(format: AV_PIX_FMT_YUV420P, progressiveAt: 3),
        Case(format: AV_PIX_FMT_YUV420P, fieldRate: false, progressiveAt: 0),
        Case(format: AV_PIX_FMT_YUV420P, progressiveAt: 2, repeatAt: 2),
        Case(format: AV_PIX_FMT_YUV420P, noPTSAt: 4),
        Case(format: AV_PIX_FMT_YUV420P, frames: 1),
        Case(format: AV_PIX_FMT_YUV420P, frames: 2),
        Case(format: AV_PIX_FMT_YUV420P, fieldRate: false, frames: 2),
    ]

    /// One output: its timestamp and its samples, component by component, row by row.
    struct Picture: Equatable {
        var pts: Int64
        var samples: [[Int]]
    }

    @Test("bwdif on the GPU equals libavfilter's, field for field", arguments: BwdifReferenceTests.cases)
    func matchesLibavfilter(_ c: Case) throws {
        let planar = try #require(PlanarFrameFinisher.planarEquivalent(of: c.format), "no planar equivalent")
        let source = try (0..<c.frames).map { try Self.frame(c, format: c.format, index: $0) }
        let reference = try (0..<c.frames).map { try Self.frame(c, format: planar, index: $0) }
        defer {
            for var f in source + reference { av_frame_free(&f) }
        }
        let expected = try Self.libavfilter(reference.map { $0! }, format: planar, c)
        let got = try Self.gpu(source.map { $0! }, c)
        #expect(got.count == expected.count, "outputs: \(got.count) vs libavfilter's \(expected.count)")
        for (i, (g, e)) in zip(got, expected).enumerated() {
            #expect(g.pts == e.pts, "output \(i): pts \(g.pts) vs \(e.pts)")
            if let mismatch = Self.firstMismatch(g.samples, e.samples, c) {
                Issue.record("output \(i): \(mismatch)")
                return
            }
        }
    }

    @Test("every format the cases cover is one FFmpeg's bwdif defines, and grey10 is not")
    func referenceScope() {
        for format in Self.formats {
            let planar = PlanarFrameFinisher.planarEquivalent(of: format)
            #expect(planar.map { BwdifWindow.referenceFormats.contains($0.rawValue) } == true, "\(format)")
        }
        #expect(PlanarFrameFinisher.planarEquivalent(of: AV_PIX_FMT_GRAY10LE).map { BwdifWindow.referenceFormats.contains($0.rawValue) } == false)
    }

    // MARK: - Pictures

    private static func components(_ format: AVPixelFormat) -> Int {
        (av_pix_fmt_desc_get(format)?.pointee.nb_components ?? 0) < 3 ? 1 : 3
    }

    private static func size(_ format: AVPixelFormat, _ comp: Int, _ c: Case) -> (Int, Int) {
        guard comp > 0, let d = av_pix_fmt_desc_get(format)?.pointee else { return (c.width, c.height) }
        let sw = Int(d.log2_chroma_w), sh = Int(d.log2_chroma_h)
        return ((c.width + (1 << sw) - 1) >> sw, (c.height + (1 << sh) - 1) >> sh)
    }

    private static func hash(_ a: Int, _ b: Int, _ t: Int, _ comp: Int) -> Int {
        var h = UInt32(truncatingIfNeeded: a &* 73856093 ^ b &* 19349663 ^ t &* 83492791 ^ comp &* 2654435761)
        h ^= h >> 13
        h = h &* 0x5bd1e995
        h ^= h >> 15
        return Int(h)
    }

    /// The sample of component `comp` at (x, y) in picture `t`: static, moving or noise by column.
    private static func value(_ comp: Int, _ x: Int, _ y: Int, _ t: Int, width: Int, max: Int) -> Int {
        let v: Int
        if x < width / 3 {
            v = hash(x, y, 0, comp)
        } else if x < 2 * width / 3 {
            v = hash(x - 2 * t, y + t, 0, comp)
        } else {
            v = hash(x, y, t, comp)
        }
        return v % (max + 1)
    }

    private static func frame(_ c: Case, format: AVPixelFormat, index t: Int) throws -> UnsafeMutablePointer<AVFrame>? {
        let f = try #require(av_frame_alloc())
        f.pointee.width = Int32(c.width)
        f.pointee.height = Int32(c.height)
        f.pointee.format = format.rawValue
        try #require(av_frame_get_buffer(f, 0) >= 0)
        // av_write_image_line2 ORs each component into its bytes (packed layouts share them): start from zero.
        withUnsafeBytes(of: f.pointee.buf) { refs in
            for case let ref? in refs.bindMemory(to: UnsafeMutablePointer<AVBufferRef>?.self) {
                memset(ref.pointee.data, 0, ref.pointee.size)
            }
        }
        f.pointee.pts = c.noPTSAt == t ? Int64.min : Int64(t)
        f.pointee.sample_aspect_ratio = AVRational(num: 1, den: 1)
        if c.progressiveAt != t {
            f.pointee.flags |= AV_FRAME_FLAG_INTERLACED
            if c.topFieldFirst { f.pointee.flags |= AV_FRAME_FLAG_TOP_FIELD_FIRST }
        }
        if c.repeatAt == t { f.pointee.repeat_pict = 1 }
        var desc = try #require(av_pix_fmt_desc_get(format)).pointee
        for comp in 0..<components(format) {
            let depth = Int(withUnsafeBytes(of: desc.comp) { $0.bindMemory(to: AVComponentDescriptor.self)[comp].depth })
            let (w, h) = size(format, comp, c)
            for y in 0..<h {
                let row = (0..<w).map { UInt16(value(comp, $0, y, t, width: w, max: (1 << depth) - 1)) }
                row.withUnsafeBytes { src in
                    withUnsafeMutablePointer(to: &f.pointee.data) { dp in
                        withUnsafePointer(to: &f.pointee.linesize) { lp in
                            av_write_image_line2(src.baseAddress, UnsafeMutableRawPointer(dp).assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self),
                                                 UnsafeRawPointer(lp).assumingMemoryBound(to: Int32.self), &desc,
                                                 0, Int32(y), Int32(comp), Int32(w), 2)
                        }
                    }
                }
            }
        }
        return f
    }

    private static func samples(of f: UnsafeMutablePointer<AVFrame>, _ c: Case) -> [[Int]] {
        let format = AVPixelFormat(rawValue: f.pointee.format)
        var desc = av_pix_fmt_desc_get(format)!.pointee
        return (0..<components(format)).map { comp in
            let (w, h) = size(format, comp, c)
            var out: [Int] = []
            var row = [UInt32](repeating: 0, count: w)
            for y in 0..<h {
                withUnsafeMutablePointer(to: &f.pointee.data) { dp in
                    withUnsafePointer(to: &f.pointee.linesize) { lp in
                        av_read_image_line2(&row, UnsafeMutableRawPointer(dp).assumingMemoryBound(to: UnsafePointer<UInt8>?.self),
                                            UnsafeRawPointer(lp).assumingMemoryBound(to: Int32.self), &desc,
                                            0, Int32(y), Int32(comp), Int32(w), 0, 4)
                    }
                }
                out += row.map { Int($0) }
            }
            return out
        }
    }

    private static func firstMismatch(_ got: [[Int]], _ expected: [[Int]], _ c: Case) -> String? {
        guard got.count == expected.count else { return "components \(got.count) vs \(expected.count)" }
        for comp in got.indices {
            guard got[comp].count == expected[comp].count else { return "component \(comp): \(got[comp].count) samples vs \(expected[comp].count)" }
            let (w, _) = size(c.format, comp, c)
            if let i = got[comp].indices.first(where: { got[comp][$0] != expected[comp][$0] }) {
                let differing = zip(got[comp], expected[comp]).filter { $0 != $1 }.count
                return "component \(comp) (\(i % w), \(i / w)): \(got[comp][i]) vs \(expected[comp][i]), \(differing) samples differ"
            }
        }
        return nil
    }

    // MARK: - libavfilter

    private static func libavfilter(_ frames: [UnsafeMutablePointer<AVFrame>], format: AVPixelFormat, _ c: Case) throws -> [Picture] {
        var graph: UnsafeMutablePointer<AVFilterGraph>? = try #require(avfilter_graph_alloc())
        defer { avfilter_graph_free(&graph) }
        var src: UnsafeMutablePointer<AVFilterContext>?, deint: UnsafeMutablePointer<AVFilterContext>?, sink: UnsafeMutablePointer<AVFilterContext>?
        let args = "video_size=\(c.width)x\(c.height):pix_fmt=\(format.rawValue):time_base=1/25:pixel_aspect=1/1"
        try #require(avfilter_graph_create_filter(&src, avfilter_get_by_name("buffer"), "in", args, nil, graph) >= 0)
        try #require(avfilter_graph_create_filter(&deint, avfilter_get_by_name("bwdif"), "bwdif",
                                                  "mode=\(c.fieldRate ? "send_field" : "send_frame"):parity=auto:deint=interlaced",
                                                  nil, graph) >= 0)
        try #require(avfilter_graph_create_filter(&sink, avfilter_get_by_name("buffersink"), "out", nil, nil, graph) >= 0)
        try #require(avfilter_link(src, 0, deint, 0) >= 0)
        try #require(avfilter_link(deint, 0, sink, 0) >= 0)
        try #require(avfilter_graph_config(graph, nil) >= 0)
        var out: [Picture] = []
        var pulled = av_frame_alloc()
        defer { av_frame_free(&pulled) }
        func drain() {
            while av_buffersink_get_frame(sink, pulled) >= 0 {
                out.append(Picture(pts: pulled!.pointee.pts, samples: samples(of: pulled!, c)))
                av_frame_unref(pulled)
            }
        }
        for f in frames {
            try #require(av_buffersrc_add_frame_flags(src, f, Int32(AV_BUFFERSRC_FLAG_KEEP_REF)) >= 0)
            drain()
        }
        try #require(av_buffersrc_add_frame_flags(src, nil, 0) >= 0)
        drain()
        return out
    }

    // MARK: - The GPU

    private static func gpu(_ frames: [UnsafeMutablePointer<AVFrame>], _ c: Case) throws -> [Picture] {
        let device = try #require(MTLCreateSystemDefaultDevice(), "needs a Metal device")
        let allocator = try #require(DecodeFrameAllocator(device: device))
        let finisher = try PlanarFrameFinisher(device: device)
        let reader = try #require(PlanarFrameFinisher.readerPlan(source: c.format))
        let window = BwdifWindow(timeBase: AVRational(num: 1, den: 25), fieldRate: c.fieldRate)
        var outputs: [BwdifWindow.Output] = []
        for f in frames {
            let (planes, slab) = try #require(allocator.copy(f))
            let held = try #require(av_frame_clone(f))
            let storage = BwdifWindow.Storage(frame: held, planes: planes, release: { allocator.release(slab) })
            outputs += window.push(BwdifWindow.Picture(storage: storage, pts: f.pointee.pts))
        }
        outputs += window.finish()
        return try outputs.map { output in
            switch output {
            case .picture(let picture, let pts):
                return Picture(pts: pts, samples: samples(of: picture.frame, c))
            case .field(let prev, let cur, let next, let parity, let fieldParity, let intra, let pts):
                let field = PlanarFrameFinisher.Field(prev: prev.storage.planes, cur: cur.storage.planes, next: next.storage.planes,
                                                      parity: parity, fieldParity: fieldParity, intra: intra, reader: reader)
                let result = try #require(finisher.deinterlace(field, width: c.width, height: c.height))
                return Picture(pts: pts, samples: scratchSamples(result.planes, result.bytes, reader: reader, c))
            }
        }
    }

    private static func scratchSamples(_ planes: PlanarFrameFinisher.Planes, _ bytes: UnsafeRawBufferPointer,
                                       reader: PlanarFrameFinisher.Plan, _ c: Case) -> [[Int]] {
        (0..<components(c.format)).map { comp in
            let (w, h) = size(c.format, comp, c)
            let wide = reader.components[comp][4] > 8
            var out: [Int] = []
            for y in 0..<h {
                let row = Int(planes.offsets[comp]) + y * Int(planes.linesizes[comp])
                for x in 0..<w {
                    out.append(wide ? Int(bytes.load(fromByteOffset: row + 2 * x, as: UInt16.self)) : Int(bytes[row + x]))
                }
            }
            return out
        }
    }
}
