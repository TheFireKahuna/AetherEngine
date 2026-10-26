import CoreVideo
import Foundation
import Metal
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AV1 film grain on the GPU (docs/software-route-gpu.md Part 5): libdav1d decodes into the slabs the finisher reads and
/// hands grain over as parameters, which the finisher applies inside its one pass. Against the normative process,
/// libdav1d's own grained picture (bit exact on the Argon conformance streams) through the same writer.
struct FilmGrainTests {

    /// Three temporal units of SVT-AV1 at 128x72, 10-bit 4:2:0, with film grain.
    static let fixture = Data(base64Encoded: """
        EgAKCwIAAAVZv8cavnAwMp8IFACj+CUc33ADgbOCgxUSiHJ6Iq/yo4ARjZGUCTYIw4TRA3+DMAIQ2hFBm2CsOE/4Z789QEc+vLzBQj+4v0DBPz4+QT29
        PkRBvsBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQABAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEAyhAYEAgMCAQDdbV6xWWIHJcjE6jiMVzhk8rtiotaAh7+r
        /JUTPNsYTmYyXwJefWqb7c+Nttf0dtJ8URThqAoKt21sKgsnTWtg0zWCofUbBSBtVrBg3kHgEsje7TwyZZfwZHhoBeSBGEJMkBWb/+oQfUj2PT0dTUSF
        KC9/+cNDx3oUXMD42HaFLHgo6m0/uETFVR6PtjWTbrK1eqrk4cmtaOp2BWjke7a6bBKbjFrzTTt4NuDjcOW8DkeyT2TthrB897MjE7+AjPLR8o8aYwAa
        dZN/PBF0FF8nbaj9aXQUoj/8CJTxMgDKEZBxnnfMSHXkfYuRiN5YzBB3qPnz7ltPR2KYJ4mg327N8mG7hcuD+rzZmN9eHCLDNRie27vX1v9YorK7r/CS
        sNIgoroXLchCqKHMH3bRrMLMi4AJlKOlntya52pEWCWMuyr0JQaPJIgRSvQ5zmY8v2jj4dC8u8OhqnpIFQ/C7FKL4Sdz9LRYJB/JS/Ql4AeXhFhqCD38
        WWgZqTIP6FmiIqfw6uw1RPYg26sFKcGkYU+2mtKWIbzVs4ckqbR9IoDPtQifPPUyhYm3sW5vjjc7sqyaB/MO01ViHfayWWytU4PHD2CRZl6lRCHthIdK
        JGgiLKLni3XssdCYgmsCtYtJPn+OQ0wYl1rwAcmi7+uwn6CwpxmZGKWOBiDbL4CoGMRI5mOMEDPJeErGSwPav2a9FLoNj8gtTMT06GLW3THpANtrwJ7u
        QcyF+CdhRzBge8kcBjbJWeoeDLAC9446wLkWBmuWE7+H/gsqvehjriwiA4trC6GgtLLotqbe8GOcwL7B89H2nqxZjbQK581OS8b6L4Sb0YrwoXZruEG4
        4X30gtUxGd3RYyoMg3VrDjdnC0Q7cxheTGoXMMPNf5AYshGDDesK+bBy6WXx83+4XxGi5U5xifdx7bo8d/Dwuz8HmPyiikJ476SIZZq2ofYCaHoDX+/Y
        Oul5blwA4+reYNDobIXNaXUnHnwDRFR8WCdInrnndqos2Yk7BI7lRq8der7y4Ip8jvZ3OUiCp1R3OrRM/+Sqoc4yj9NK28Nsa2bZjhe9hN5EjykvvIp9
        gPcz9L+2/IDll2nhInoUQGfoRxWocDXrp9WeKEiEhNKTerp+NMBsOt26MLWUfTWT4wEWdxet3k/Mhux1OzCxx1CYh/lrCucyDKgt3fe2K5SrJOtwYI6l
        k8e/zsJVeVxesvY9bFlfWqg5AyNDuDu4RblgliASADLyASgCAEAAAB0wwMsmWQz7wDAE3SagBsUGC8SvJJ/lJgASGxM2EUMOygb/BmABQbEzYOQwvKBP
        8E9+d4CQfHh9fIV/fIKDfXt6d4x7goCKhIeAgICAgICAgICAgICAgICAgICAgICAgIAAgICAgICAgICAgICAgICAgICAgICAgICAAAgMCAQGBAIZaMVD
        kEBT9WlgXO+ByNCxfLq1vpU1XZDkeOtnsORwJH4unqjFx+z7WfEea+1IzFXlqA084FLGPksYw7ktJOHwuGba1QAz7lIZimWECOj9I2Wa991i3NSM7qmS
        3cJOcZrQHJgKhmcjDtFYMtQBMAIAAABJOmQAAAGPgAMASoUuAGQ2ZGxS8kkOTyhJ/kgwAReQj/B1ACEbIDYOlAT/BPeX92kXp/foGBh3CCgYB9f3aKeo
        CAjYSAgICAgICAgICAgICAgICAgICAgICAgICAAICAgICAgICAgICAgICAgICAgICAgICAgAAIDAgEBgQCAZbekUHmgj6TJX/NL3xFjRUwWsIbmGD6pu
        6iIPBku/F5+QEANeFOuX9SvZMUbGgjd6y0JKuv93gooVGymN0xfM4m542nPSAn3ef5L/ZZj/EO8SABoBmA==
        """, options: .ignoreUnknownCharacters)!

    /// libdav1d over `packets`, set up by the display writer as playback sets it up, every picture written by it. With
    /// `libdav1dGrain` the grain export is taken back off, so libdav1d applies grain into a picture of its own.
    static func written(_ packets: [[UInt8]], libdav1dGrain: Bool, threads: Int32 = 0) throws -> [[UInt8]] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let writer = try DisplayBufferWriter(device: device, streamIs10Bit: true, twelveBit420: .p010Dithered,
                                             containerHDRStatic: .none, logTag: "FilmGrainTests")
        let codec = try #require(avcodec_find_decoder_by_name("libdav1d"))
        var context = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&context) }
        let ctx = try #require(context)
        writer.install(on: ctx, codec: codec)
        if libdav1dGrain { ctx.pointee.export_side_data &= ~Int32(AV_CODEC_EXPORT_DATA_FILM_GRAIN) }
        ctx.pointee.thread_count = threads
        try #require(avcodec_open2(ctx, codec, nil) >= 0)
        var packet = av_packet_alloc()
        var frame = av_frame_alloc()
        defer { av_packet_free(&packet); av_frame_free(&frame) }
        var out: [[UInt8]] = []
        func drain() throws {
            while avcodec_receive_frame(ctx, frame) >= 0 {
                if !libdav1dGrain {
                    #expect(writer.allocator.slab(of: frame!) != nil, "decoded in place, no copy")
                }
                out.append(try bytes(of: try #require(writer.finishAndWait(frame!))))
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
        return out
    }

    /// The display buffer's planes, visible rows only.
    static func bytes(of pb: CVPixelBuffer) throws -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let eightBit: Set<OSType> = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        let sampleBytes = eightBit.contains(CVPixelBufferGetPixelFormatType(pb)) ? 1 : 2
        var out: [UInt8] = []
        for p in 0..<CVPixelBufferGetPlaneCount(pb) {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(pb, p))
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, p)
            let visible = CVPixelBufferGetWidthOfPlane(pb, p) * (p == 0 ? 1 : 2) * sampleBytes
            for y in 0..<CVPixelBufferGetHeightOfPlane(pb, p) { out += UnsafeRawBufferPointer(start: base + y * rowBytes, count: visible) }
        }
        return out
    }

    @Test("the finisher's grain gives what libdav1d's grained picture gives", arguments: [Int32(1), 4])
    func grainEqualsLibdav1d(threads: Int32) throws {
        let packets = try #require(Self.chunks(Self.fixture, annexB: false))
        let ours = try Self.written(packets, libdav1dGrain: false, threads: threads)
        let reference = try Self.written(packets, libdav1dGrain: true, threads: threads)
        #expect(ours.count == 3)
        #expect(ours == reference)
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

    /// Every Argon stream with film grain (its checksum with grain differs from the one without): the writer's pictures
    /// with the GPU's grain against the writer's pictures of libdav1d's grained output.
    @Test("Argon: the GPU's grain gives libdav1d's grained pictures", .enabled(if: FilmGrainTests.argonEnabled),
          .timeLimit(.minutes(30)), arguments: argonDirectories)
    func argonConformance(directory: String) throws {
        let root = Self.argon.appending(path: directory)
        let streams = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "streams").path)
            .filter { $0.hasSuffix(".obu") }.sorted()
        var checked = 0, failures: [String] = []
        for name in streams {
            let stem = String(name.dropLast(4))
            func expected(_ kind: String) throws -> String {
                String(try String(contentsOf: root.appending(path: "\(kind)/\(stem).md5"), encoding: .utf8).prefix(32))
            }
            guard try expected("md5_no_film_grain") != expected("md5_ref") else { continue }
            let packets = try #require(Self.chunks(try Data(contentsOf: root.appending(path: "streams/\(name)")),
                                                   annexB: !directory.contains("not_annexb")), "\(name) framing")
            // One decoder thread a stream: the directories run side by side, about one thread a core in all.
            let ours = try Self.written(packets, libdav1dGrain: false, threads: 1)
            let reference = try Self.written(packets, libdav1dGrain: true, threads: 1)
            checked += 1
            if ours != reference {
                let first = zip(ours, reference).enumerated().first { $1.0 != $1.1 }?.offset ?? min(ours.count, reference.count)
                failures.append("\(name): picture \(first) of \(reference.count)")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) of \(checked): \(failures.prefix(20).joined(separator: "; "))")
        #expect(checked > 0)
    }
}
