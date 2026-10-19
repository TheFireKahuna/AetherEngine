import Testing
import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// HDR10 static metadata stated only in the bitstream reaches the init's `mdcv` / `clli`.
///
/// movenc writes both boxes from the output codecpar's stream side data alone, and nothing fills that
/// for an MPEG-TS source or a Matroska remuxed from one. The SEI NAL units below are real: the
/// first access unit of an x265 4.3 encode (`master-display=G(13250,34500)B(7500,3000)R(34000,16000)
/// WP(15635,16450)L(10000000,1):max-cll=1000,400`, MPEG-TS) and of an x264 encode of the same values.
/// The HEVC mastering display message carries an emulation-prevention byte in its min luminance.
@Suite("In-band HDR10 static metadata reaches the init")
struct InBandHDRStaticMetadataTests {

    static let hevcCLL: [UInt8] = [0x4e, 0x01, 0x90, 0x04, 0x03, 0xe8, 0x01, 0x90, 0x80]
    static let hevcMDCV: [UInt8] = [
        0x4e, 0x01, 0x89, 0x18, 0x33, 0xc2, 0x86, 0xc4, 0x1d, 0x4c, 0x0b, 0xb8, 0x84, 0xd0, 0x3e, 0x80,
        0x3d, 0x13, 0x40, 0x42, 0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x03, 0x00, 0x01, 0x80,
    ]
    static let h264MDCV: [UInt8] = [
        0x06, 0x89, 0x18, 0x33, 0xc2, 0x86, 0xc4, 0x1d, 0x4c, 0x0b, 0xb8, 0x84, 0xd0, 0x3e, 0x80,
        0x3d, 0x13, 0x40, 0x42, 0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x03, 0x00, 0x01, 0x80,
    ]
    static let h264CLL: [UInt8] = [0x06, 0x90, 0x04, 0x03, 0xe8, 0x01, 0x90, 0x80]
    /// A coded slice header stand-in so the access unit is not SEI alone.
    static let hevcSlice: [UInt8] = [0x26, 0x01, 0xaf, 0x10, 0x22]

    static let expectedMDCV: [UInt8] = [
        0x33, 0xc2, 0x86, 0xc4, 0x1d, 0x4c, 0x0b, 0xb8, 0x84, 0xd0, 0x3e, 0x80,
        0x3d, 0x13, 0x40, 0x42, 0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x01,
    ]

    static func annexB(_ nals: [[UInt8]]) -> [UInt8] { nals.flatMap { [0, 0, 0, 1] + $0 } }
    static func lengthPrefixed(_ nals: [[UInt8]]) -> [UInt8] {
        nals.flatMap { n in [UInt8(n.count >> 24 & 0xff), UInt8(n.count >> 16 & 0xff),
                             UInt8(n.count >> 8 & 0xff), UInt8(n.count & 0xff)] + n }
    }

    static func collect(_ bytes: [UInt8], codecID: AVCodecID, framing: VideoNALFraming) -> InBandHDRStaticMetadata {
        var m = InBandHDRStaticMetadata()
        bytes.withUnsafeBufferPointer { m.collect(from: $0.baseAddress!, size: $0.count, codecID: codecID, framing: framing) }
        return m
    }

    @Test("HEVC prefix SEI in Annex B, the MPEG-TS shape")
    func hevcAnnexB() {
        let m = Self.collect(Self.annexB([Self.hevcCLL, Self.hevcMDCV, Self.hevcSlice]),
                             codecID: AV_CODEC_ID_HEVC, framing: .annexB)
        #expect(m.masteringDisplay == Self.expectedMDCV)
        #expect(m.contentLightLevel == [0x03, 0xe8, 0x01, 0x90])
    }

    @Test("HEVC length-prefixed, the Matroska shape")
    func hevcLengthPrefixed() {
        let m = Self.collect(Self.lengthPrefixed([Self.hevcMDCV, Self.hevcCLL, Self.hevcSlice]),
                             codecID: AV_CODEC_ID_HEVC, framing: .lengthPrefixed(size: 4))
        #expect(m.masteringDisplay == Self.expectedMDCV)
        #expect(m.contentLightLevel == [0x03, 0xe8, 0x01, 0x90])
    }

    @Test("H.264 carries the same two messages")
    func h264() {
        let m = Self.collect(Self.annexB([Self.h264MDCV, Self.h264CLL, [0x65, 0x88, 0x84]]),
                             codecID: AV_CODEC_ID_H264, framing: .annexB)
        #expect(m.masteringDisplay == Self.expectedMDCV)
        #expect(m.contentLightLevel == [0x03, 0xe8, 0x01, 0x90])
    }

    @Test("an access unit without them yields nothing")
    func nothingWithoutSEI() {
        let m = Self.collect(Self.annexB([Self.hevcSlice]), codecID: AV_CODEC_ID_HEVC, framing: .annexB)
        #expect(m.isEmpty)
    }

    @Test("attached side data carries libavcodec's values and order")
    func attachValues() throws {
        var p: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&p) }
        let par = try #require(p)
        let m = Self.collect(Self.annexB([Self.hevcCLL, Self.hevcMDCV]), codecID: AV_CODEC_ID_HEVC, framing: .annexB)
        #expect(m.attach(to: par) == ["mdcv", "clli"])

        let md = try #require(av_packet_side_data_get(
            par.pointee.coded_side_data, par.pointee.nb_coded_side_data, AV_PKT_DATA_MASTERING_DISPLAY_METADATA))
        md.pointee.data.withMemoryRebound(to: AVMasteringDisplayMetadata.self, capacity: 1) { m in
            #expect(m.pointee.display_primaries.0.0.num == 34000)   // R x
            #expect(m.pointee.display_primaries.1.1.num == 34500)   // G y
            #expect(m.pointee.display_primaries.2.0.num == 7500)    // B x
            #expect(m.pointee.display_primaries.0.0.den == 50000)
            #expect(m.pointee.white_point.1.num == 16450)
            #expect(m.pointee.max_luminance.num == 10_000_000)
            #expect(m.pointee.max_luminance.den == 10_000)
            #expect(m.pointee.min_luminance.num == 1)
            #expect(m.pointee.has_primaries == 1 && m.pointee.has_luminance == 1)
        }
        let cll = try #require(av_packet_side_data_get(
            par.pointee.coded_side_data, par.pointee.nb_coded_side_data, AV_PKT_DATA_CONTENT_LIGHT_LEVEL))
        cll.pointee.data.withMemoryRebound(to: AVContentLightMetadata.self, capacity: 1) {
            #expect($0.pointee.MaxCLL == 1000)
            #expect($0.pointee.MaxFALL == 400)
        }
    }

    @Test("a container statement wins")
    func containerWins() throws {
        var p: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&p) }
        let par = try #require(p)
        let existing = try #require(av_packet_side_data_new(
            &par.pointee.coded_side_data, &par.pointee.nb_coded_side_data,
            AV_PKT_DATA_CONTENT_LIGHT_LEVEL, MemoryLayout<AVContentLightMetadata>.size, 0))
        existing.pointee.data.withMemoryRebound(to: AVContentLightMetadata.self, capacity: 1) {
            $0.pointee.MaxCLL = 4000; $0.pointee.MaxFALL = 50
        }
        let m = Self.collect(Self.annexB([Self.hevcCLL, Self.hevcMDCV]), codecID: AV_CODEC_ID_HEVC, framing: .annexB)
        #expect(m.attach(to: par) == ["mdcv"])
        #expect(par.pointee.nb_coded_side_data == 2)
        let cll = try #require(av_packet_side_data_get(
            par.pointee.coded_side_data, par.pointee.nb_coded_side_data, AV_PKT_DATA_CONTENT_LIGHT_LEVEL))
        cll.pointee.data.withMemoryRebound(to: AVContentLightMetadata.self, capacity: 1) {
            #expect($0.pointee.MaxCLL == 4000)
        }
    }

    // MARK: - movenc

    /// The init movenc writes from a codecpar carrying the lifted side data holds both boxes, and
    /// one written without it holds neither: the side data is the whole mechanism.
    @Test("movenc writes mdcv and clli from the lifted side data")
    func muxerWritesBoxes() throws {
        #expect(try Self.initBoxes(lifting: true).contains("mdcv"))
        #expect(try Self.initBoxes(lifting: true).contains("clli"))
        #expect(try !Self.initBoxes(lifting: false).contains("mdcv"))
    }

    static func initBoxes(lifting: Bool) throws -> Set<String> {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(
            reader: DataIOReader(data: Data(
                base64Encoded: AtmosDetectionProbeIntegrationTests.videoOnlyBase64,
                options: .ignoreUnknownCharacters) ?? Data()),
            formatHint: "mp4")
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        var packet: UnsafeMutablePointer<AVPacket>?
        while let pkt = try demuxer.readPacket() {
            if pkt.pointee.stream_index == demuxer.videoStreamIndex { packet = pkt; break }
            var o: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&o)
        }
        defer { trackedPacketFree(&packet) }
        let pkt = try #require(packet)

        var p: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&p) }
        let par = try #require(p)
        #expect(avcodec_parameters_copy(par, stream.pointee.codecpar) >= 0)
        if lifting {
            let m = collect(annexB([hevcCLL, hevcMDCV]), codecID: AV_CODEC_ID_HEVC, framing: .annexB)
            m.attach(to: par)
        }

        let sessionDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inband-hdr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionDir) }
        var initBytes = Data()
        let muxer = try MP4SegmentMuxer(
            initialSegmentIndex: 0, sessionDir: sessionDir,
            video: .init(codecpar: UnsafePointer(par), timeBase: stream.pointee.time_base, codecTagOverride: nil),
            audio: nil, onInitCaptured: { initBytes = $0 })
        pkt.pointee.stream_index = muxer.videoOutputStreamIndex
        pkt.pointee.flags |= AV_PKT_FLAG_KEY
        _ = muxer.writePacket(pkt)
        _ = muxer.finalize()
        #expect(!initBytes.isEmpty)
        var found = Set<String>()
        for type in ["mdcv", "clli", "colr"] where initBytes.range(of: Data(type.utf8)) != nil {
            found.insert(type)
        }
        return found
    }
}
