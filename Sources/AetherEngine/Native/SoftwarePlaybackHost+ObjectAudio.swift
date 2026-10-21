import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Object audio on the software host: TrueHD Atmos rendered to APAC as on the HLS route, for the sessions
/// that cannot take that route, chiefly the Dolby Vision FEL dual-layer one. Without it the track decodes
/// to its 7.1 presentation, heights and objects gone.
extension SoftwarePlaybackHost {

    struct ObjectAudioChoice {
        let decoder: any SoftwareAudioDecoding
        /// For the engine's pipeline description, as the HLS route words it.
        let pipelineDescription: String
    }

    /// The APAC decoder for this track, or nil to decode it to LPCM as ever: object rendering off, not
    /// TrueHD Atmos, not built in, live, or a bridge that failed to build, each logged. DTS:X keeps LPCM
    /// here: its verdict reads the head of the track the way the HLS route does, which this host does not.
    static func objectAudioDecoder(
        rendering: ObjectAudioRendering,
        dialogueGain: Float,
        stream: UnsafeMutablePointer<AVStream>,
        demuxer: Demuxer,
        streamIndex: Int32,
        isLive: Bool
    ) -> ObjectAudioChoice? {
        guard rendering != .off, let par = stream.pointee.codecpar else { return nil }
        guard par.pointee.codec_id == AV_CODEC_ID_TRUEHD else {
            if HLSVideoEngine.objectAudioSource(codecID: par.pointee.codec_id, profile: par.pointee.profile) == .dtsHDMasterAudio {
                EngineLog.emit("[SWHost] DTS:X rendering is not on the software path; the track plays as LPCM",
                               category: .swPlayback)
            }
            return nil
        }
        if par.pointee.profile == AV_PROFILE_UNKNOWN, !isLive {
            resolveUnlabelledTrueHDAtmos(par: par, demuxer: demuxer, streamIndex: streamIndex)
        }
        guard let layout = HLSVideoEngine.spatialRenderingLayout(
            rendering: rendering, codecID: par.pointee.codec_id,
            profile: par.pointee.profile, sampleRate: par.pointee.sample_rate)
        else {
            EngineLog.emit(
                "[SWHost] object rendering requested but TrueHD is not Atmos at 48, 96 or 192 kHz, or not built in "
                + "(profile=\(par.pointee.profile) rate=\(par.pointee.sample_rate)); the track plays as LPCM",
                category: .swPlayback)
            return nil
        }
        guard !isLive else {
            EngineLog.emit("[SWHost] TrueHD Atmos rendering is VOD only; the track plays as LPCM", category: .swPlayback)
            return nil
        }
        #if TrueHDObjectAudio
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
            EngineLog.emit("[SWHost] TrueHD Atmos rendering needs OS 26; the track plays as LPCM", category: .swPlayback)
            return nil
        }
        do {
            let objects = APACObjectOutputSwitch.isOn
            let decoder = objects
                ? try TrueHDObjectAudioDecoder(splitsBed: false, objectOutput: true, dialogueGain: dialogueGain)
                : try TrueHDObjectAudioDecoder(splitsBed: !TrueHDReferenceRender.isOn, dialogueGain: dialogueGain)
            let bridge = try SpatialAudioBridge(
                srcTimeBase: stream.pointee.time_base, layout: layout, decoder: decoder, objectOutput: objects)
            let apac = try APACSampleBufferDecoder(bridge: bridge)
            let rendering = objects
                ? "elements sent as APAC objects (\(APACObjectOutputSwitch.variable), personal build)"
                : TrueHDReferenceRender.isOn
                    ? "objects rendered into \(layout.rawValue) (reference render, \(TrueHDReferenceRender.variable))"
                    : "channel presentation split into \(layout.rawValue) by the objects' energy"
            EngineLog.emit(
                "[SWHost] TrueHD Atmos: \(rendering), played as APAC through the sample buffer renderer (lossy)",
                category: .swPlayback)
            return ObjectAudioChoice(
                decoder: apac,
                pipelineDescription: "TrueHD Atmos → APAC \(objects ? "objects" : layout.rawValue)")
        } catch {
            EngineLog.emit(
                "[SWHost] ERROR: TrueHD Atmos rendering unavailable (\(error)); the track plays as LPCM",
                category: .swPlayback)
            return nil
        }
        #else
        return nil
        #endif
    }

    /// A TrueHD track the probe never decoded a frame of keeps `AV_PROFILE_UNKNOWN`; its own major sync
    /// says whether it is Atmos. Peeks without consuming, with the HLS route's budgets.
    private static func resolveUnlabelledTrueHDAtmos(
        par: UnsafeMutablePointer<AVCodecParameters>, demuxer: Demuxer, streamIndex: Int32
    ) {
        var verdict: Bool?
        var heldBytes = 0
        try? demuxer.peekPackets(maxPackets: HLSVideoEngine.trueHDVerdictPacketBudget) { packet in
            heldBytes += Int(max(packet.pointee.size, 0))
            if heldBytes > HLSVideoEngine.trueHDVerdictByteBudget { return true }
            guard packet.pointee.stream_index == streamIndex,
                  let data = packet.pointee.data, packet.pointee.size > 0 else { return false }
            verdict = TrueHDMajorSync.isAtmos(UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)))
            return verdict != nil
        }
        if verdict == true { par.pointee.profile = AV_PROFILE_TRUEHD_ATMOS }
        EngineLog.emit(
            "[SWHost] TrueHD profile was not probed; major sync says \(verdict.map { $0 ? "Atmos" : "no Atmos" } ?? "nothing within the budget")",
            category: .swPlayback)
    }
}
