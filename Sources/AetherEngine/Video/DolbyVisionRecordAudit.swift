import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Dovi

/// AE#532: what a Dolby Vision source's own RPU says about the profile its container claims.
///
/// A container record is a claim, and for one class of remux it is a false one: a Profile 5 record over
/// a bitstream whose VUI declares BT.2020 YCbCr with a PQ or HLG transfer. IPT-PQ-c2 has no VUI code
/// point, so a genuine Profile 5 leaves `matrix_coeffs` and `transfer_characteristics` unspecified, and
/// a record that fills them in contradicts itself. Served as the record asks, the decoder reads YCbCr as
/// IPT and the picture comes out green / violet (#4, #176).
///
/// The RPU settles which half is lying, without a heuristic: a Profile 5 RPU cannot carry a residual or
/// an NLQ, so an RPU that carries one was authored for a different profile. libdovi answers it in one
/// field, and the engine already parses RPUs on this path for the Profile 7 conversion.
public enum DolbyVisionRecordAudit {

    private static let nalTypeRPU: UInt8 = 62   // unspec62: Dolby Vision RPU

    /// The profile libdovi reads out of the first RPU in this packet, or nil when the packet carries no
    /// parseable one. Unparseable says nothing rather than guessing: the record stands.
    static func rpuProfile(
        _ packet: UnsafePointer<AVPacket>,
        framing: VideoNALFraming = .lengthPrefixed(size: 4)
    ) -> Int? {
        guard let data = packet.pointee.data, packet.pointee.size > 4 else { return nil }
        let size = Int(packet.pointee.size)

        var result: Int?
        A53SEIParser.forEachNAL(data, size, framing) { nal, len in
            guard result == nil, (nal[0] >> 1) & 0x3F == nalTypeRPU else { return }
            // Behind the CRC and panic-path checks: libdovi aborts the process on some malformed RPUs.
            guard let rpu = DoviRpuGuard.parse(nal, len) else { return }
            defer { dovi_rpu_free(rpu) }
            guard let hdr = dovi_rpu_get_header(rpu) else { return }
            defer { dovi_rpu_free_header(hdr) }
            result = Int(hdr.pointee.guessed_profile)
        }
        return result
    }

    /// Whether this source's container record contradicts its own bitstream, i.e. whether reading the
    /// RPU can tell us anything the record does not. Only a Profile 5 record over a VUI that declares a
    /// BT.2020 YCbCr base with a PQ or HLG transfer qualifies, which is what keeps the audit free for
    /// every other source: a genuine Profile 5 leaves the VUI unspecified and is never read.
    ///
    /// HEVC only. AV1 Profile 10.0 has the same contradiction available in principle, but its RPU rides
    /// in an ITU-T T.35 metadata OBU rather than an `unspec62` NAL, which this walk cannot reach.
    static func recordIsContradicted(
        codecID: AVCodecID,
        dvProfile: Int?,
        colorTransfer: AVColorTransferCharacteristic,
        colorMatrix: AVColorSpace
    ) -> Bool {
        guard codecID == AV_CODEC_ID_HEVC, dvProfile == 5 else { return false }
        return VideoRoutingPolicy.vuiDeclaresYCbCrHDRBase(
            colorTransfer: colorTransfer, colorMatrix: colorMatrix)
    }

    /// The profile the route should believe, or nil to leave the record standing.
    ///
    /// Only a contradiction is a correction: an RPU that agrees with the record, an RPU that could not be
    /// read, and a profile this engine has no route for all leave the record alone. 7 and 8 are the two
    /// answers worth acting on, and both already have a route, so the correction costs no new packaging:
    /// a 7 takes the Profile 7 branch (RPU conversion on a Dolby Vision display, the HDR10 base without
    /// one) and an 8 takes the Profile 8.1 branch, whose compatibility rewrite turns the record's
    /// compatibility 0 into the 1 it should have carried.
    static func correctedProfile(record: Int?, rpu: Int?) -> Int? {
        guard record == 5, let rpu, rpu != record else { return nil }
        return (rpu == 7 || rpu == 8) ? rpu : nil
    }

    // MARK: - A record the container never wrote

    /// Whether a stream with NO Dolby Vision record is worth reading for one. The mirror image of
    /// `recordIsContradicted`: some Matroska releases are Profile 5 (IPT-PQ-c2, no base layer) with the
    /// `BlockAdditionMapping` dropped, and with nothing else declaring HDR either, so the source loads as
    /// plain SDR and the IPT picture is decoded as YCbCr (violet / green).
    ///
    /// The pairing is narrow on purpose, so the audit stays free for everything else: HEVC, no record,
    /// 10-bit 4:2:0, and a VUI that says nothing at all (transfer, matrix and primaries all unspecified).
    /// A file that names any colour description is a file whose author described it, and the RPU is not
    /// consulted. Ordinary SDR and HDR10 remuxes all carry a description and never reach a packet read.
    static func recordlessProfile5IsCandidate(
        codecID: AVCodecID,
        hasRecord: Bool,
        pixelFormat: Int32,
        colorTransfer: AVColorTransferCharacteristic,
        colorMatrix: AVColorSpace,
        colorPrimaries: AVColorPrimaries
    ) -> Bool {
        guard codecID == AV_CODEC_ID_HEVC, !hasRecord,
              pixelFormat == AV_PIX_FMT_YUV420P10LE.rawValue else { return false }
        return colorTransfer == AVCOL_TRC_UNSPECIFIED
            && colorMatrix == AVCOL_SPC_UNSPECIFIED
            && colorPrimaries == AVCOL_PRI_UNSPECIFIED
    }

    /// Whether the RPU proves a recordless candidate is Profile 5. Anything else, including an RPU that
    /// could not be read, is no evidence and leaves the source as it was.
    static func rpuProvesProfile5(_ rpu: Int?) -> Bool { rpu == 5 }

    /// Append the record a Profile 5 container would have carried to `codecpar`, through the same
    /// `coded_side_data` list a demuxed record lives in, so every reader of it (`dvConfig`, the route
    /// policy, the segment muxer's `dvcC`) sees a genuine Profile 5 record. Profile 5, level 6 (the level
    /// the route defaults to when a record carries none), RPU present, no enhancement layer, base layer
    /// present, signal compatibility 0. Returns false if the allocation failed.
    @discardableResult
    static func synthesizeProfile5Record(_ codecpar: UnsafeMutablePointer<AVCodecParameters>) -> Bool {
        let size = MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
        guard let item = av_packet_side_data_new(
            &codecpar.pointee.coded_side_data, &codecpar.pointee.nb_coded_side_data,
            AV_PKT_DATA_DOVI_CONF, size, 0),
              let raw = item.pointee.data else { return false }
        memset(raw, 0, size)
        raw.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { rec in
            rec.pointee.dv_version_major = 1
            rec.pointee.dv_version_minor = 0
            rec.pointee.dv_profile = 5
            rec.pointee.dv_level = 6
            rec.pointee.rpu_present_flag = 1
            rec.pointee.el_present_flag = 0
            rec.pointee.bl_present_flag = 1
            rec.pointee.dv_bl_signal_compatibility_id = 0
        }
        return true
    }

    /// Run the recordless audit on a freshly probed video stream: when it is a candidate, read the first
    /// RPU from `demuxer`'s own first packets and add the Profile 5 record if it says so. Called by the
    /// demuxer at the end of its own open, so the load, the HLS producer's own open and every rebuild see
    /// the same stream and none of them needs the verdict carried to it. A failed read is no evidence.
    @discardableResult
    static func addRecordIfProfile5(
        codecpar: UnsafeMutablePointer<AVCodecParameters>, peeking demuxer: Demuxer, streamIndex: Int32
    ) -> Bool {
        let hasRecord = (0..<Int(codecpar.pointee.nb_coded_side_data)).contains {
            codecpar.pointee.coded_side_data?[$0].type == AV_PKT_DATA_DOVI_CONF
        }
        guard recordlessProfile5IsCandidate(
            codecID: codecpar.pointee.codec_id, hasRecord: hasRecord,
            pixelFormat: codecpar.pointee.format,
            colorTransfer: codecpar.pointee.color_trc, colorMatrix: codecpar.pointee.color_space,
            colorPrimaries: codecpar.pointee.color_primaries) else { return false }
        let rpu = rpuProfile(peeking: demuxer, streamIndex: streamIndex, packetBudget: recordlessPacketBudget)
        guard rpuProvesProfile5(rpu), synthesizeProfile5Record(codecpar) else {
            EngineLog.emit(
                "[AetherEngine] AE#recordless: untagged 10-bit HEVC with no DV record, RPU "
                + (rpu.map { "reads profile \($0)" } ?? "could not be read") + "; left as it was",
                category: .engine)
            return false
        }
        EngineLog.emit(
            "[AetherEngine] AE#recordless: DV profile 5 from the first RPU, container has no record",
            category: .engine)
        return true
    }

    /// How many video packets to look at before giving up. Every frame of a Dolby Vision source carries an
    /// RPU, so the answer is in the first one; the slack is for a container whose head is audio.
    private static let auditPacketBudget = 16

    /// The same for the recordless gate, where the slack is paid by the wrong sources. #532 reads packets
    /// only for a record its own VUI already contradicts, which is a source that is broken either way;
    /// the recordless gate is met by every untagged 10-bit HEVC, and an SDR encode with no colour
    /// description is a common shape that looks through the whole budget to learn nothing. A Profile 5
    /// answers in the first video packet, so four is slack and not budget.
    private static let recordlessPacketBudget = 4

    /// The profile the first RPU of `demuxer`'s video stream reads, or nil when no packet within the
    /// budget carries a parseable one, which means the same thing to every caller: the record stands.
    ///
    /// The packets are peeked where the demuxer stands (`Demuxer.peekPackets`): held, so whoever reads the
    /// demuxer next (the software path, the producer) gets them first, and the source is neither opened nor
    /// read a second time for the answer. The demuxer has usually read them already, while it probed.
    static func rpuProfile(
        peeking demuxer: Demuxer, streamIndex: Int32, packetBudget: Int = auditPacketBudget,
        byteBudget: Int64 = Int64(walkByteBudget)
    ) -> Int? {
        firstRPU(peeking: demuxer, streamIndex: streamIndex, packetBudget: packetBudget, byteBudget: byteBudget) {
            rpuProfile($0, framing: $1)
        }
    }

    /// The enhancement-layer type ("FEL" or "MEL") of a Profile 7 source's first RPU, peeked the same way.
    static func probeEnhancementLayerType(
        peeking demuxer: Demuxer, streamIndex: Int32, packetBudget: Int = auditPacketBudget,
        byteBudget: Int64 = Int64(walkByteBudget)
    ) -> String? {
        firstRPU(peeking: demuxer, streamIndex: streamIndex, packetBudget: packetBudget, byteBudget: byteBudget) {
            DoviRpuConverter.enhancementLayerType($0, framing: $1)
        }
    }

    /// The first answer `read` gives for a packet of `streamIndex`, looking at no more than `packetBudget`
    /// of its packets, `foreignPacketFuseMultiplier` times that of every stream, and `byteBudget` of input.
    private static func firstRPU<T>(
        peeking demuxer: Demuxer, streamIndex: Int32, packetBudget: Int, byteBudget: Int64,
        read: (UnsafeMutablePointer<AVPacket>, VideoNALFraming) -> T?
    ) -> T? {
        guard let stream = demuxer.stream(at: streamIndex) else { return nil }
        let codecpar = stream.pointee.codecpar
        let framing = A53SEIParser.nalFraming(
            codec: .hevc, extradata: codecpar?.pointee.extradata,
            size: Int(codecpar?.pointee.extradata_size ?? 0))
        // Audit BIT-103: Matroska resyncs byte by byte through junk inside one av_read_frame, where
        // neither the packet fuse nor the packet byte count below can see the bytes go by.
        demuxer.beginInputByteBudget(byteBudget)
        defer { demuxer.endInputByteBudget() }
        let (fuse, overflow) = packetBudget.multipliedReportingOverflow(by: foreignPacketFuseMultiplier)
        var looked = 0
        var bytes = 0
        var answer: T?
        try? demuxer.peekPackets(maxPackets: overflow ? Int.max : fuse) { packet in
            bytes += Int(max(packet.pointee.size, 0))
            if packet.pointee.stream_index == streamIndex {
                looked += 1
                if let found = read(packet, framing) { answer = found; return true }
            }
            return looked >= packetBudget || Int64(bytes) >= byteBudget
        }
        return answer
    }

    /// Audit BIT-2: the look counted only video packets, so a source that stops delivering video after
    /// its head made every open read the rest of the file. Every packet counts against these instead.
    /// No AVDISCARD_ALL on the other streams: the demuxer would then skip them inside one read, where
    /// neither ceiling can see the bytes go by.
    static let foreignPacketFuseMultiplier = 16
    static let walkByteBudget = 64 * 1024 * 1024

    /// The verdict for a source in one call, gate included: opens it, reads the record and the VUI, and
    /// peeks at packets only when the record is contradicted. nil means the record stands.
    ///
    /// For a caller that has no probe of its own, which is the CLI harness. A session gates on the record
    /// its own probe already read and peeks at its own demuxer.
    public static func rpuCorrection(url: URL, extraHeaders: [String: String] = [:]) -> Int? {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        // The full profile: the gate reads the DOVI record and the colour description, and both arrive
        // only with `find_stream_info`.
        do {
            try demuxer.open(url: url, extraHeaders: extraHeaders, profile: .playback)
        } catch {
            return nil
        }
        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx),
              let codecpar = stream.pointee.codecpar else { return nil }
        let record = AetherEngine.dvConfig(stream: stream)
        guard recordIsContradicted(
            codecID: codecpar.pointee.codec_id, dvProfile: record?.profile,
            colorTransfer: codecpar.pointee.color_trc, colorMatrix: codecpar.pointee.color_space) else { return nil }
        return correctedProfile(record: record?.profile,
                                rpu: rpuProfile(peeking: demuxer, streamIndex: videoIdx))
    }
}
