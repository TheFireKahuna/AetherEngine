import Testing
import Foundation
import AetherLibavcodec
@testable import AetherEngine

/// Unit tests for the `LoadOptions.confirmAtmos` session pass (#214 follow-up): which tracks earn a
/// bounded decode, and how a confirmation survives the republishes that rebuild `audioTracks` mid-session.
/// The decode itself is covered by `AtmosDetectionOptionsTests` / `AtmosDetectionProbeIntegrationTests`.
@Suite("Atmos confirmation: candidate selection and ledger application")
struct AtmosConfirmationTests {

    private func track(
        id: Int, codec: String = "eac3", isAtmos: Bool = false, isExternal: Bool = false
    ) -> TrackInfo {
        TrackInfo(
            id: id, name: "Track \(id)", codec: codec, language: "eng", channels: 6,
            bitrate: 768_000, isDefault: id == 0, isAtmos: isAtmos, isExternal: isExternal
        )
    }

    // MARK: - atmosConfirmationCandidates

    @Test("only E-AC-3 tracks are candidates")
    func onlyEAC3IsACandidate() {
        let tracks = [
            track(id: 1, codec: "eac3"), track(id: 2, codec: "ac3"), track(id: 3, codec: "aac"),
            track(id: 4, codec: "truehd"), track(id: 5, codec: "dts"),
        ]
        #expect(AetherEngine.atmosConfirmationCandidates(in: tracks) == [1])
    }

    @Test("a codec label from a container that upper-cases still matches")
    func codecMatchIsCaseInsensitive() {
        #expect(AetherEngine.atmosConfirmationCandidates(in: [track(id: 2, codec: "EAC3")]) == [2])
    }

    @Test("a track the base probe already marked Atmos is not re-scanned")
    func alreadyConfirmedIsSkipped() {
        let tracks = [track(id: 1, isAtmos: true), track(id: 2)]
        #expect(AetherEngine.atmosConfirmationCandidates(in: tracks) == [2])
    }

    @Test("host-registered external tracks are never candidates")
    func externalTracksAreSkipped() {
        // 100_000 == AetherEngine.externalSubtitleTrackIDBase, inlined because that constant is MainActor-isolated.
        let tracks = [track(id: 100_000, isExternal: true), track(id: 1)]
        #expect(AetherEngine.atmosConfirmationCandidates(in: tracks) == [1])
    }

    @Test("a source with no E-AC-3 at all yields no candidates, so no pass is armed")
    func noEAC3MeansNoWork() {
        #expect(AetherEngine.atmosConfirmationCandidates(in: [track(id: 1, codec: "aac")]).isEmpty)
        #expect(AetherEngine.atmosConfirmationCandidates(in: []).isEmpty)
    }

    @Test("every E-AC-3 track is scanned, not just the first, so the track menu stays consistent")
    func allEAC3TracksAreScanned() {
        let tracks = [track(id: 1), track(id: 2, codec: "ac3"), track(id: 3), track(id: 4)]
        #expect(AetherEngine.atmosConfirmationCandidates(in: tracks) == [1, 3, 4])
    }

    @Test("an id that is not a real AVStream index is dropped rather than trapping")
    func synthenticIdsAreDropped() {
        let tracks = [track(id: -1), track(id: Int(Int32.max) + 1), track(id: 2)]
        #expect(AetherEngine.atmosConfirmationCandidates(in: tracks) == [2])
    }

    // MARK: - applyingConfirmedAtmos (the ledger)

    @Test("the ledger flips exactly the confirmed streams on a republished list")
    func ledgerFlipsConfirmedStreams() {
        let republished = [track(id: 1), track(id: 2), track(id: 3)]
        let out = AetherEngine.applyingConfirmedAtmos(to: republished, confirmed: [1, 3])
        #expect(out.map(\.isAtmos) == [true, false, true])
    }

    @Test("an empty ledger leaves a republished list untouched")
    func emptyLedgerIsANoOp() {
        let republished = [track(id: 1), track(id: 2)]
        let out = AetherEngine.applyingConfirmedAtmos(to: republished, confirmed: [])
        #expect(out.allSatisfy { !$0.isAtmos })
    }

    @Test("a ledger entry for a stream the new list does not carry is ignored")
    func ledgerEntryForAbsentStreamIsIgnored() {
        let republished = [track(id: 4), track(id: 5)]
        let out = AetherEngine.applyingConfirmedAtmos(to: republished, confirmed: [1])
        #expect(out.allSatisfy { !$0.isAtmos })
    }

    @Test("the ledger never clears a flag the base probe set")
    func ledgerIsAdditiveOnly() {
        let republished = [track(id: 1, isAtmos: true), track(id: 2)]
        let out = AetherEngine.applyingConfirmedAtmos(to: republished, confirmed: [2])
        #expect(out.map(\.isAtmos) == [true, true])
    }

    @Test("everything except isAtmos survives the ledger pass")
    func ledgerPreservesEveryOtherField() {
        let before = track(id: 7, codec: "eac3")
        let after = AetherEngine.applyingConfirmedAtmos(to: [before], confirmed: [7])[0]
        #expect(after.isAtmos)
        #expect(after.id == before.id)
        #expect(after.name == before.name)
        #expect(after.codec == before.codec)
        #expect(after.language == before.language)
        #expect(after.channels == before.channels)
        #expect(after.bitrate == before.bitrate)
        #expect(after.isDefault == before.isDefault)
        #expect(after.isExternal == before.isExternal)
    }

    // MARK: - LoadOptions surface

    @Test("confirmAtmos is off by default, so no existing session changes shape")
    func confirmAtmosDefaultsOff() {
        #expect(LoadOptions().confirmAtmos == false)
        #expect(LoadOptions(confirmAtmos: true).confirmAtmos == true)
    }

    // MARK: - The session pass, fed by the session's own reads

    /// Writes the shared plain-EAC3 fixture to a temp file.
    private func withEAC3FixtureURL(_ body: (URL) throws -> Void) throws {
        let bytes = try #require(
            Data(base64Encoded: AtmosDetectionProbeIntegrationTests.eac3PlainBase64,
                 options: .ignoreUnknownCharacters))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atmos-confirmation-\(UUID().uuidString).mp4")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private final class Confirmed: @unchecked Sendable {
        let lock = NSLock()
        var streams: [Int32] = []
    }

    /// The reader discards the candidate, as a session reading another track does: the candidate is read for
    /// the pass alone, and the reader gets none of it.
    @Test("a stream the reader discards is read for the pass alone, and the pass answers from it")
    func discardedCandidateIsReadForThePass() throws {
        try withEAC3FixtureURL { url in
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(url: url)
            demuxer.discardAllStreamsExcept([])
            let confirmed = Confirmed()
            // A scan of four packets, so it answers inside the short fixture.
            let pass = try #require(AtmosConfirmationPass(
                candidates: [0], demuxer: demuxer, options: AtmosDetectionOptions(maxPackets: 4)) { index in
                confirmed.lock.withLock { confirmed.streams.append(index) }
            })
            demuxer.observe(Set(pass.streams)) { pass.feed($0) }
            var delivered = 0
            while let packet = try demuxer.readPacket() {
                var owned: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&owned)
                delivered += 1
            }
            // A plain E-AC-3 track decodes and is not JOC; the pass has its answer.
            #expect(confirmed.lock.withLock { confirmed.streams }.isEmpty)
            #expect(pass.unfinishedSummary(stopReason: "test") == nil)
            // Once answered, the stream went back to the reader's discard, and nothing reached the reader.
            #expect(delivered == 0)
        }
    }

    @Test("a stream the reader keeps is delivered as well as observed")
    func keptCandidateIsStillDelivered() throws {
        try withEAC3FixtureURL { url in
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(url: url)
            demuxer.discardAllStreamsExcept([0])
            let pass = try #require(AtmosConfirmationPass(candidates: [0], demuxer: demuxer) { _ in })
            var observed = 0
            demuxer.observe(Set(pass.streams)) { observed += 1; return pass.feed($0) }
            var delivered = 0
            while let packet = try demuxer.readPacket() {
                var owned: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&owned)
                delivered += 1
            }
            #expect(observed > 0)
            #expect(delivered >= observed)
        }
    }

    @Test("a pass the session moves on from says how far it got")
    func endedEarlySummary() throws {
        try withEAC3FixtureURL { url in
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(url: url)
            let pass = try #require(AtmosConfirmationPass(candidates: [0], demuxer: demuxer) { _ in })
            demuxer.observe(Set(pass.streams)) { pass.feed($0) }
            demuxer.endObservation()
            #expect(pass.unfinishedSummary(stopReason: "the session moved on")
                    == "[AtmosConfirmation] stopped (the session moved on) after 0 of 1 E-AC-3 track(s), confirmed JOC on none")
        }
    }
}

@Suite("Atmos confirmation: summary line")
struct AtmosConfirmationSummaryTests {

    @Test("a completed pass keeps the summary format reports already grep for")
    func completedSummary() {
        #expect(AetherEngine.atmosConfirmationSummary(scanned: 3, of: 3, confirmed: [2, 5], stopReason: nil)
            == "[AtmosConfirmation] scanned 3 E-AC-3 track(s), confirmed JOC on 2, 5")
    }

    @Test("a stopped pass still logs how far it got and what it found")
    func stoppedSummary() {
        let line = AetherEngine.atmosConfirmationSummary(
            scanned: 2, of: 17, confirmed: [], stopReason: "cancelled")
        #expect(line == "[AtmosConfirmation] stopped (cancelled) after 2 of 17 E-AC-3 track(s), confirmed JOC on none")
    }
}
