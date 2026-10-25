import Foundation
import AetherLibavcodec
import AetherLibavutil

/// The video track AVPlayer plays on a software overlay session, in place of a stream it cannot decode itself: one
/// black HEVC Main10 IDR, encoded once at load at the source's size with the colour the overlay presents in its VUI,
/// served as every sample, each with its source picture's own timestamps and metadata (``OverlayPictureMetadata``).
/// AVPlayer's rendering is suppressed; what it gives the session is its clock, its transport, the display mode
/// the placeholder's format and metadata ask for, and the audio beside it (docs/software-route-gpu.md Part 1).
///
/// Every sample is an independent IDR, so whatever order the source decodes and presents its pictures in, the
/// placeholder's samples are valid in it, and its key flags are the source's, which the segment cutter reads.
final class OverlayPlaceholder: @unchecked Sendable {
    let width: Int
    let height: Int
    /// The placeholder's HEVCDecoderConfigurationRecord: what the init declares.
    let hvcC: [UInt8]
    /// The IDR's NAL units, each behind a 4-byte length.
    private let picture: [UInt8]
    /// The colour the overlay presents the source's pictures in, which the placeholder's VUI tags.
    let tags: ColorAttachments.Tags
    /// The same, as the init's `colr` states it.
    let colour: ColorDescription
    private let sourceCodecID: AVCodecID
    private let sourceFraming: A53SEIParser.NALFraming

    /// `source` is the stream the overlay decodes; `framing` how its packets are framed (HEVC only). nil when no
    /// HEVC Main10 encoder can be made.
    init?(source: UnsafePointer<AVCodecParameters>, framing: A53SEIParser.NALFraming) {
        let width = (Int(source.pointee.width) + 1) & ~1
        let height = (Int(source.pointee.height) + 1) & ~1
        let tags = ColorAttachments.presented(ColorDescription(codecpar: source),
                                              frameSize: (source.pointee.width, source.pointee.height))
        guard width > 0, height > 0,
              let encoder = HEVCIntraEncoder(width: width, height: height, colour: tags, quality: 0) else { return nil }
        self.width = width
        self.height = height
        self.tags = tags
        hvcC = [UInt8](encoder.hvcC)
        picture = [UInt8](encoder.blackSample)
        colour = ColorAttachments.description(primaries: tags.primaries, transfer: tags.transfer, matrix: tags.matrix,
                                              fullRange: false)
        sourceCodecID = source.pointee.codec_id
        sourceFraming = framing
        EngineLog.emit("[OverlayPlaceholder] \(width)x\(height) HEVC Main10 IDR, \(picture.count) B a sample, "
                       + "hardware=\(encoder.isHardware)", category: .session)
    }

    /// The init's codec parameters: the source's, with the placeholder's codec, record, size and colour, and of the
    /// source's side data only what describes the picture the panel shows: mastering display, content light level and
    /// the Dolby Vision record, as an HEVC record (`hevcDolbyVisionRecord`).
    func codecParameters(source: UnsafePointer<AVCodecParameters>) throws -> HLSVideoEngine.OwnedCodecParameters {
        guard let owned = HLSVideoEngine.OwnedCodecParameters(copying: source) else {
            throw HLSVideoEngine.HLSVideoEngineError.openFailed(reason: "codecpar copy failed")
        }
        let par = owned.ptr
        par.pointee.codec_id = AV_CODEC_ID_HEVC
        par.pointee.codec_tag = 0
        par.pointee.profile = 2   // Main 10
        par.pointee.level = Int32(hvcC.count > 12 ? hvcC[12] : 0)
        par.pointee.format = AV_PIX_FMT_YUV420P10LE.rawValue
        par.pointee.bits_per_raw_sample = 10
        par.pointee.width = Int32(width)
        par.pointee.height = Int32(height)
        par.pointee.field_order = AV_FIELD_PROGRESSIVE
        par.pointee.video_delay = 0
        par.pointee.color_primaries = colour.primaries
        par.pointee.color_trc = colour.transfer
        par.pointee.color_space = colour.matrix
        par.pointee.color_range = colour.range
        av_freep(&par.pointee.extradata)
        let pad = Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let extradata = av_mallocz(hvcC.count + pad)?.assumingMemoryBound(to: UInt8.self) else {
            throw HLSVideoEngine.HLSVideoEngineError.openFailed(reason: "placeholder extradata allocation failed")
        }
        hvcC.withUnsafeBufferPointer { _ = memcpy(extradata, $0.baseAddress, hvcC.count) }
        par.pointee.extradata = extradata
        par.pointee.extradata_size = Int32(hvcC.count)

        let kept: Set<UInt32> = [AV_PKT_DATA_MASTERING_DISPLAY_METADATA.rawValue,
                                 AV_PKT_DATA_CONTENT_LIGHT_LEVEL.rawValue, AV_PKT_DATA_DOVI_CONF.rawValue]
        var dropped: [AVPacketSideDataType] = []
        for i in 0..<Int(par.pointee.nb_coded_side_data) {
            let type = par.pointee.coded_side_data[i].type
            if !kept.contains(type.rawValue) { dropped.append(type) }
        }
        for type in dropped { av_packet_side_data_remove(par.pointee.coded_side_data, &par.pointee.nb_coded_side_data, type) }
        for i in 0..<Int(par.pointee.nb_coded_side_data) where par.pointee.coded_side_data[i].type == AV_PKT_DATA_DOVI_CONF {
            let item = par.pointee.coded_side_data[i]
            guard let data = item.data, item.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size else { continue }
            let record = data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0 }
            if let hevc = try Self.hevcDolbyVisionRecord(record.pointee, sourceCodecID: sourceCodecID) {
                record.pointee = hevc
            } else {
                av_packet_side_data_remove(par.pointee.coded_side_data, &par.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF)
            }
            break
        }
        return owned
    }

    /// The HEVC Dolby Vision record a placeholder declares for its source's record: an AV1 profile 10 is profile 8
    /// with the same base-layer compatibility (10.1 is 8.1, 10.4 is 8.4), an HEVC profile 8 is itself. nil where the
    /// source's Dolby Vision is not served (10.2 / 8.2, an SDR base, as the native route serves it). Throws for a
    /// stream without a base layer (10.0, 5): its picture is reshaped by the system compositor, which an overlay's
    /// pixels never pass through.
    static func hevcDolbyVisionRecord(_ source: AVDOVIDecoderConfigurationRecord,
                                      sourceCodecID: AVCodecID) throws -> AVDOVIDecoderConfigurationRecord? {
        let profile = Int(source.dv_profile)
        let compat = Int(source.dv_bl_signal_compatibility_id)
        let hasBaseLayer = (sourceCodecID == AV_CODEC_ID_AV1 && profile == 10 && compat != 0)
            || (sourceCodecID == AV_CODEC_ID_HEVC && profile == 8)
        guard hasBaseLayer else {
            throw HLSVideoEngine.HLSVideoEngineError.unsupportedDVProfile(profile: profile, compatID: compat)
        }
        guard compat == 1 || compat == 4 else { return nil }
        var hevc = source
        hevc.dv_profile = 8
        hevc.rpu_present_flag = 1
        hevc.el_present_flag = 0
        hevc.bl_present_flag = 1
        return hevc
    }

    /// Rewrites `packet` in place into the placeholder sample for its picture: the source's metadata around the IDR,
    /// the packet's timestamps, duration and flags kept, its side data dropped (it describes the source's stream, not
    /// this one). False on an allocation failure, the packet then unchanged.
    func substitute(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        let metadata = packet.pointee.data.map {
            OverlayPictureMetadata.read(UnsafeBufferPointer(start: $0, count: Int(packet.pointee.size)),
                                        codecID: sourceCodecID, framing: sourceFraming)
        } ?? .none
        let nals = metadata.prefixSEI + (metadata.rpu.map { [$0] } ?? [])
        let size = picture.count + nals.reduce(0) { $0 + 4 + $1.count }
        let pad = Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let buffer = av_buffer_alloc(size + pad), let out = buffer.pointee.data else { return false }
        var w = 0
        func put(_ nal: [UInt8]) {
            let n = nal.count
            out[w] = UInt8(n >> 24 & 0xFF); out[w + 1] = UInt8(n >> 16 & 0xFF)
            out[w + 2] = UInt8(n >> 8 & 0xFF); out[w + 3] = UInt8(n & 0xFF)
            nal.withUnsafeBufferPointer { _ = memcpy(out + w + 4, $0.baseAddress, n) }
            w += 4 + n
        }
        metadata.prefixSEI.forEach(put)
        picture.withUnsafeBufferPointer { _ = memcpy(out + w, $0.baseAddress, picture.count) }
        w += picture.count
        if let rpu = metadata.rpu { put(rpu) }
        memset(out + size, 0, pad)
        av_packet_free_side_data(packet)
        av_buffer_unref(&packet.pointee.buf)
        packet.pointee.buf = buffer
        packet.pointee.data = out
        packet.pointee.size = Int32(size)
        return true
    }
}
