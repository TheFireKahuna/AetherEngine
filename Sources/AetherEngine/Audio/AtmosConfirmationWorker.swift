import Foundation
import AetherLibavcodec

// #214 follow-up: opt-in confirmation of E-AC-3 JOC on the session's own audio tracks, so
// `TrackInfo.isAtmos` is an answer rather than the pre-decode guess a host cannot act on. Nothing in
// libavformat sets AV_PROFILE_EAC3_DDP_ATMOS, so the flag only ever appeared when find_stream_info
// happened to decode an audio frame by itself. This runs the same bounded scan as
// `AetherEngine.probeDetectingAtmos` (`AtmosJOCDecoder`) on the packets the session's own reader reads
// (`Demuxer.observe`), and republishes `audioTracks` as tracks confirm.
extension AetherEngine {

    /// Stream indices worth a pass: E-AC-3 (the sole carrier of JOC), not already confirmed, and backed by
    /// a real AVStream. External tracks are host-registered subtitles with synthetic ids and never audio.
    nonisolated static func atmosConfirmationCandidates(in tracks: [TrackInfo]) -> [Int32] {
        tracks.compactMap { track in
            guard track.codec.lowercased() == "eac3", !track.isAtmos, !track.isExternal,
                  let index = Int32(exactly: track.id), index >= 0 else { return nil }
            return index
        }
    }

    /// Re-apply the ledger to whatever `audioTracks` currently holds.
    ///
    /// Every republish has to run through here. The native demuxed-audio path swaps the whole list in
    /// `syncPublishedAudioStateFromNativeSession()`, and a disc title switch re-applies the probe-derived
    /// lists, so a confirmation set once at load would silently vanish on the next audio switch.
    func applyConfirmedAtmos() {
        guard !confirmedAtmosStreamIndices.isEmpty, loadedURL == confirmedAtmosSource else { return }
        audioTracks = Self.applyingConfirmedAtmos(to: audioTracks, confirmed: confirmedAtmosStreamIndices)
    }

    /// Pure half of `applyConfirmedAtmos`, so the ledger-to-track-list mapping is testable without a
    /// session. Additive: a track the base probe already marked stays marked, nothing is ever cleared.
    nonisolated static func applyingConfirmedAtmos(to tracks: [TrackInfo], confirmed: Set<Int32>) -> [TrackInfo] {
        guard !confirmed.isEmpty else { return tracks }
        return tracks.map { track in
            guard let index = Int32(exactly: track.id), confirmed.contains(index), !track.isAtmos else {
                return track
            }
            var flipped = track
            flipped.isAtmos = true
            return flipped
        }
    }

    /// Arm the pass for the loaded session. Called at the end of `load()` on every backend, so it runs
    /// after playback is up and never sits in front of the first frame.
    ///
    /// The candidates' packets come from the session's own reader as it plays: a stream nobody plays is
    /// read beside the one that is, for as long as its scan lasts (about two seconds of audio), and goes no
    /// further. Nothing opens the source a second time, so no origin is asked anything it is not asked
    /// already: a serial or held-connection origin and a live source are confirmed like any other.
    func startAtmosConfirmation() {
        cancelAtmosConfirmation()
        guard loadedOptions.confirmAtmos, let url = loadedURL else { return }
        // A session-preserving reload of the same item keeps what the previous pass already learned and
        // only chases what is still open; a new item starts from scratch.
        if confirmedAtmosSource != url {
            confirmedAtmosSource = url
            confirmedAtmosStreamIndices = []
        }
        applyConfirmedTrackFlags()
        let candidates = Self.atmosConfirmationCandidates(in: audioTracks)
        guard !candidates.isEmpty,
              let demuxer = nativeVideoSession?.demuxer else { return }
        let pass = AtmosConfirmationPass(candidates: candidates, demuxer: demuxer) { [weak self] index in
            Task { @MainActor [weak self] in
                guard let self, self.loadedURL == self.confirmedAtmosSource else { return }
                self.confirmedAtmosStreamIndices.insert(index)
                self.applyConfirmedTrackFlags()
            }
        }
        guard let pass else { return }
        atmosConfirmation = (pass, demuxer)
        demuxer.observe(Set(pass.streams)) { packet in pass.feed(packet) }
    }

    /// Teardown: the observed streams go back to what the session's reader asked for, and a pass that had
    /// not finished says how far it got.
    func cancelAtmosConfirmation() {
        guard let (pass, demuxer) = atmosConfirmation else { return }
        atmosConfirmation = nil
        // Once the observation has ended, the reading thread no longer feeds the pass.
        demuxer.endObservation()
        if let line = pass.unfinishedSummary(stopReason: "the session moved on") {
            EngineLog.emit(line, category: .engine)
        }
    }

    /// The pass's one log line, once every candidate has an answer. A track whose scan never finished (the
    /// session ended first) is named as not scanned rather than as not Atmos.
    nonisolated static func atmosConfirmationSummary(
        scanned: Int, of total: Int, confirmed: [Int32], stopReason: String?
    ) -> String {
        let joc = confirmed.isEmpty ? "none" : confirmed.map(String.init).joined(separator: ", ")
        guard let stopReason else {
            return "[AtmosConfirmation] scanned \(total) E-AC-3 track(s), confirmed JOC on \(joc)"
        }
        return "[AtmosConfirmation] stopped (\(stopReason)) after \(scanned) of \(total) E-AC-3 track(s), "
            + "confirmed JOC on \(joc)"
    }
}

/// One confirmation pass: a JOC scan per candidate stream, fed the packets the session's reader reads.
/// Runs on the reading thread under the demuxer's lock (`Demuxer.observe`), so it only decodes.
final class AtmosConfirmationPass: @unchecked Sendable {
    private var decoders: [Int32: AtmosJOCDecoder]
    let streams: [Int32]
    private let total: Int
    private var confirmed: [Int32] = []
    private let onConfirmed: @Sendable (Int32) -> Void

    /// nil when no candidate's decoder opens.
    init?(candidates: [Int32], demuxer: Demuxer, options: AtmosDetectionOptions = AtmosDetectionOptions(),
          onConfirmed: @escaping @Sendable (Int32) -> Void) {
        var decoders: [Int32: AtmosJOCDecoder] = [:]
        for index in candidates {
            guard let decoder = demuxer.withStream(at: index, { stream -> AtmosJOCDecoder? in
                guard let codecpar = stream.pointee.codecpar, codecpar.pointee.codec_id == AV_CODEC_ID_EAC3 else {
                    return nil
                }
                return AtmosJOCDecoder(codecpar: codecpar, maxPackets: options.maxPackets, maxBytes: options.maxBytes)
            }) ?? nil else { continue }
            decoders[index] = decoder
        }
        guard !decoders.isEmpty else { return nil }
        self.decoders = decoders
        streams = decoders.keys.sorted()
        total = candidates.count
        self.onConfirmed = onConfirmed
    }

    /// The stop line for a pass some of whose candidates have no answer yet; nil once every one has.
    /// Called after the observation ended, so nothing feeds the pass any more.
    func unfinishedSummary(stopReason: String) -> String? {
        guard !decoders.isEmpty else { return nil }
        return AetherEngine.atmosConfirmationSummary(scanned: total - decoders.count, of: total,
                                                     confirmed: confirmed.sorted(), stopReason: stopReason)
    }

    /// One packet of a candidate; true once that candidate has its answer.
    func feed(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        let index = packet.pointee.stream_index
        guard let decoder = decoders[index] else { return true }
        guard let outcome = decoder.feed(packet) else { return false }
        decoders[index] = nil
        if outcome.confirmedAtmos {
            confirmed.append(index)
            onConfirmed(index)
        }
        if decoders.isEmpty {
            EngineLog.emit(AetherEngine.atmosConfirmationSummary(
                scanned: total, of: total, confirmed: confirmed.sorted(), stopReason: nil), category: .engine)
        }
        return true
    }
}
