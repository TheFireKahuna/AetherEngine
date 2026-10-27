import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
import Dovi
@testable import AetherEngine

/// The software overlay's placeholder (`OverlayPlaceholder`) and the per-picture metadata it carries
/// (`OverlayPictureMetadata`), checked against libdovi and libavcodec: what AVPlayer is served decodes as HEVC and
/// hands the decoder the source picture's own Dolby Vision RPU and HDR10+ metadata.
@Suite("Overlay placeholder", .serialized)
struct OverlayPlaceholderTests {

    // MARK: - Fixtures

    /// The FEL fixture's RPU as Profile 8.1, which is what an AV1 profile 10.1 stream carries: (unspec62 NAL, the
    /// T.35 message of an AV1 metadata OBU from its country code on), both written by libdovi from the one parsed RPU.
    static let dolbyVisionForms: (nal: [UInt8], message: [UInt8])? = {
        DoviComposedFrameRpuTests.felNAL.withUnsafeBufferPointer { buf -> ([UInt8], [UInt8])? in
            guard let rpu = DoviRpuGuard.parse(buf.baseAddress!, buf.count) else { return nil }
            defer { dovi_rpu_free(rpu) }
            guard dovi_convert_rpu_with_mode(rpu, 2) == 0,
                  let nal = dovi_write_unspec62_nalu(rpu) else { return nil }
            defer { dovi_data_free(nal) }
            guard let obu = dovi_write_av1_rpu_metadata_obu_t35_complete(rpu) else { return nil }
            defer { dovi_data_free(obu) }
            return ([UInt8](UnsafeBufferPointer(start: nal.pointee.data, count: nal.pointee.len)),
                    [UInt8](UnsafeBufferPointer(start: obu.pointee.data, count: obu.pointee.len)))
        }
    }()

    /// An ST 2094-40 message from its country code on, written by libavutil.
    static let hdr10PlusMessage: [UInt8]? = {
        guard let metadata = av_dynamic_hdr_plus_alloc(nil) else { return nil }
        defer { av_free(metadata) }
        metadata.pointee.itu_t_t35_country_code = 0xB5
        metadata.pointee.application_version = 1
        metadata.pointee.num_windows = 1
        metadata.pointee.targeted_system_display_maximum_luminance = AVRational(num: 400, den: 1)
        withUnsafeMutablePointer(to: &metadata.pointee.params.0) { $0.pointee.maxscl = (AVRational(num: 1, den: 10), AVRational(num: 1, den: 10), AVRational(num: 1, den: 10)) }
        var data: UnsafeMutablePointer<UInt8>?
        var size = 0
        guard av_dynamic_hdr_plus_to_t35(metadata, &data, &size) >= 0, let data else { return nil }
        defer { av_free(data) }
        // libavutil writes the message after its 48-bit header: country, provider, provider oriented code, application.
        return [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04] + [UInt8](UnsafeBufferPointer(start: data, count: size))
    }()

    /// A metadata OBU (type 5, with a size field) holding `metadataType` and `payload`, with its trailing bits.
    static func metadataOBU(type metadataType: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let body = [metadataType] + payload + [0x80]
        var size = body.count
        var leb: [UInt8] = []
        repeat {
            var byte = UInt8(size & 0x7F)
            size >>= 7
            if size > 0 { byte |= 0x80 }
            leb.append(byte)
        } while size > 0
        return [0x2A] + leb + body
    }

    /// A temporal delimiter, then `obus`: the shape of a demuxed AV1 packet.
    static func av1Packet(_ obus: [[UInt8]]) -> [UInt8] { [0x12, 0x00] + obus.flatMap { $0 } }

    static func read(_ bytes: [UInt8], _ codec: AVCodecID = AV_CODEC_ID_AV1) -> OverlayPictureMetadata {
        bytes.withUnsafeBufferPointer { OverlayPictureMetadata.read($0, codecID: codec, framing: .lengthPrefixed(size: 4)) }
    }

    // MARK: - Metadata

    @Test("an AV1 Dolby Vision T.35 OBU becomes the unspec62 NAL libdovi writes for the same RPU")
    func av1DolbyVision() throws {
        let forms = try #require(Self.dolbyVisionForms)
        let metadata = Self.read(Self.av1Packet([Self.metadataOBU(type: 4, forms.message)]))
        #expect(metadata.rpu == forms.nal)
        #expect(metadata.prefixSEI.isEmpty)
    }

    @Test("a Dolby Vision RPU whose CRC is wrong is not carried")
    func corruptRPU() throws {
        var message = try #require(Self.dolbyVisionForms).message
        message[message.count / 2] ^= 0x10
        #expect(Self.read(Self.av1Packet([Self.metadataOBU(type: 4, message)])).rpu == nil)
    }

    @Test("AV1 HDR10+ becomes a T.35 prefix SEI the HDR10+ scan accepts, the message unchanged")
    func av1HDR10Plus() throws {
        let message = try #require(Self.hdr10PlusMessage)
        let metadata = Self.read(Self.av1Packet([Self.metadataOBU(type: 4, message)]))
        let sei = try #require(metadata.prefixSEI.first)
        #expect(metadata.prefixSEI.count == 1 && metadata.rpu == nil)
        #expect(sei.prefix(2) == [0x4E, 0x01])
        let packet = DoviComposedFrameRpuTests.avcc([sei])
        defer { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }
        #expect(HDR10PlusMetadataScan.packetCarriesHDR10Plus(packet, codecID: AV_CODEC_ID_HEVC, framing: .lengthPrefixed(size: 4)))
    }

    @Test("other metadata, other T.35 providers and other OBUs carry nothing")
    func otherOBUs() {
        let cll = Self.metadataOBU(type: 1, [0x03, 0xE8, 0x01, 0x90])
        let otherProvider = Self.metadataOBU(type: 4, [0xB5, 0x00, 0x31, 0x47, 0x41, 0x39, 0x34])
        let frameHeader: [UInt8] = [0x32, 0x02, 0x10, 0x00]
        #expect(Self.read(Self.av1Packet([cll, otherProvider, frameHeader])) == .none)
    }

    @Test("HEVC keeps its own prefix SEI and RPU; codecs without either carry nothing")
    func hevcAndOthers() throws {
        let forms = try #require(Self.dolbyVisionForms)
        let sei = OverlayPictureMetadata.t35SEI(try #require(Self.hdr10PlusMessage))
        let slice = DoviComposedFrameRpuTests.slice
        var bytes: [UInt8] = []
        for nal in [sei, slice, forms.nal] { bytes += [0, 0, 0, UInt8(nal.count)] + nal }
        #expect(Self.read(bytes, AV_CODEC_ID_HEVC) == OverlayPictureMetadata(prefixSEI: [sei], rpu: forms.nal))
        #expect(Self.read(bytes, AV_CODEC_ID_MPEG2VIDEO) == .none)
    }

    @Test("emulation prevention escapes every 00 00 0x that needs it, and nothing else")
    func escaping() {
        #expect(OverlayPictureMetadata.escaped([0, 0, 0, 0, 0, 1, 0, 0, 4, 0, 0]) == [0, 0, 3, 0, 0, 3, 0, 1, 0, 0, 4, 0, 0])
    }

    // MARK: - Placeholder

    /// AV1 parameters for a 640x360 HDR10 picture with a Dolby Vision record of `profile` / `compat`, mastering
    /// metadata, and a stereo 3D record a placeholder does not state.
    static func av1Parameters(profile: UInt8 = 10, compat: UInt8 = 1) throws -> UnsafeMutablePointer<AVCodecParameters> {
        let par = try #require(avcodec_parameters_alloc())
        par.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        par.pointee.codec_id = AV_CODEC_ID_AV1
        par.pointee.width = 640
        par.pointee.height = 360
        par.pointee.color_primaries = AVCOL_PRI_BT2020
        par.pointee.color_trc = AVCOL_TRC_SMPTE2084
        par.pointee.color_space = AVCOL_SPC_BT2020_NCL
        par.pointee.color_range = AVCOL_RANGE_MPEG
        par.pointee.sample_aspect_ratio = AVRational(num: 1, den: 1)
        func add(_ type: AVPacketSideDataType, _ size: Int) throws -> UnsafeMutablePointer<UInt8> {
            let sd = try #require(av_packet_side_data_new(&par.pointee.coded_side_data, &par.pointee.nb_coded_side_data, type, size, 0))
            memset(sd.pointee.data, 0, size)
            return sd.pointee.data
        }
        let dovi = try add(AV_PKT_DATA_DOVI_CONF, MemoryLayout<AVDOVIDecoderConfigurationRecord>.size)
        dovi.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) {
            $0.pointee.dv_version_major = 1
            $0.pointee.dv_profile = profile
            $0.pointee.dv_level = 5
            $0.pointee.rpu_present_flag = 1
            $0.pointee.bl_present_flag = 1
            $0.pointee.dv_bl_signal_compatibility_id = compat
        }
        let mastering = try add(AV_PKT_DATA_MASTERING_DISPLAY_METADATA, MemoryLayout<AVMasteringDisplayMetadata>.size)
        mastering.withMemoryRebound(to: AVMasteringDisplayMetadata.self, capacity: 1) {
            $0.pointee.max_luminance = AVRational(num: 1000, den: 1)
            $0.pointee.has_luminance = 1
        }
        _ = try add(AV_PKT_DATA_STEREO3D, MemoryLayout<AVStereo3D>.size)
        return par
    }

    static func sideData(_ par: UnsafePointer<AVCodecParameters>, _ type: AVPacketSideDataType) -> UnsafePointer<AVPacketSideData>? {
        av_packet_side_data_get(par.pointee.coded_side_data, par.pointee.nb_coded_side_data, type)
    }

    @Test("the init describes HEVC Main10 at the source's size and colour, its Dolby Vision as Profile 8")
    func initParameters() throws {
        var source: UnsafeMutablePointer<AVCodecParameters>? = try Self.av1Parameters()
        defer { avcodec_parameters_free(&source) }
        let placeholder = try #require(OverlayPlaceholder(source: source!, framing: .lengthPrefixed(size: 4)))
        let owned = try placeholder.codecParameters(source: source!)
        let par = owned.ptr.pointee
        #expect(par.codec_id == AV_CODEC_ID_HEVC && par.width == 640 && par.height == 360)
        #expect(par.color_trc == AVCOL_TRC_SMPTE2084 && par.color_primaries == AVCOL_PRI_BT2020 && par.color_space == AVCOL_SPC_BT2020_NCL)
        #expect(HLSVideoEngine.hevcCodecsString(fromConfigRecord: placeholder.hvcC)?.hasPrefix("hvc1.2.") == true)
        let dovi = try #require(Self.sideData(owned.ptr, AV_PKT_DATA_DOVI_CONF))
        let record = dovi.pointee.data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
        #expect(record.dv_profile == 8 && record.dv_bl_signal_compatibility_id == 1 && record.dv_level == 5 && record.el_present_flag == 0)
        #expect(Self.sideData(owned.ptr, AV_PKT_DATA_MASTERING_DISPLAY_METADATA) != nil)
        #expect(Self.sideData(owned.ptr, AV_PKT_DATA_STEREO3D) == nil)
    }

    @Test("AV1 10.4 is 8.4, 10.2 states no Dolby Vision, 10.0 is refused")
    func dolbyVisionRecords() throws {
        func record(_ profile: UInt8, _ compat: UInt8) throws -> AVDOVIDecoderConfigurationRecord? {
            var r = AVDOVIDecoderConfigurationRecord()
            r.dv_profile = profile
            r.dv_bl_signal_compatibility_id = compat
            return try OverlayPlaceholder.hevcDolbyVisionRecord(r, sourceCodecID: AV_CODEC_ID_AV1)
        }
        #expect(try record(10, 4)?.dv_profile == 8)
        #expect(try record(10, 4)?.dv_bl_signal_compatibility_id == 4)
        #expect(try record(10, 2) == nil)
        #expect(throws: (any Error).self) { try record(10, 0) }
    }

    @Test("a substituted sample decodes as HEVC and hands the decoder its picture's RPU and HDR10+, timing kept")
    func substitutedSampleDecodes() throws {
        let forms = try #require(Self.dolbyVisionForms)
        let message = try #require(Self.hdr10PlusMessage)
        var source: UnsafeMutablePointer<AVCodecParameters>? = try Self.av1Parameters()
        defer { avcodec_parameters_free(&source) }
        let placeholder = try #require(OverlayPlaceholder(source: source!, framing: .lengthPrefixed(size: 4)))
        let owned = try placeholder.codecParameters(source: source!)

        let bytes = Self.av1Packet([Self.metadataOBU(type: 4, message), Self.metadataOBU(type: 4, forms.message),
                                    [0x32, 0x02, 0x10, 0x00]])
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let p = try #require(packet)
        #expect(av_new_packet(p, Int32(bytes.count)) == 0)
        bytes.withUnsafeBufferPointer { _ = memcpy(p.pointee.data, $0.baseAddress, bytes.count) }
        p.pointee.pts = 3003
        p.pointee.dts = 1001
        p.pointee.duration = 1001
        p.pointee.flags = 0
        #expect(placeholder.substitute(p))
        #expect(p.pointee.pts == 3003 && p.pointee.dts == 1001 && p.pointee.duration == 1001 && p.pointee.flags == 0)

        let codec = try #require(avcodec_find_decoder(AV_CODEC_ID_HEVC))
        var ctx: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&ctx) }
        #expect(avcodec_parameters_to_context(ctx, owned.ptr) >= 0)
        #expect(avcodec_open2(ctx, codec, nil) == 0)
        #expect(avcodec_send_packet(ctx, p) == 0)
        #expect(avcodec_send_packet(ctx, nil) == 0)
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        #expect(avcodec_receive_frame(ctx, frame) == 0)
        let f = try #require(frame)
        #expect(f.pointee.width == 640 && f.pointee.height == 360)
        #expect(av_frame_get_side_data(f, AV_FRAME_DATA_DOVI_RPU_BUFFER) != nil, "the decoder found the RPU")
        #expect(av_frame_get_side_data(f, AV_FRAME_DATA_DYNAMIC_HDR_PLUS) != nil, "the decoder found the HDR10+ SEI")
    }
}
