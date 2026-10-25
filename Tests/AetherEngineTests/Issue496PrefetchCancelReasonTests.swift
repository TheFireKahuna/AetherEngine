import Foundation
import Testing
@testable import AetherEngine

/// #496 (RadicalMuffinMan): a field capture showed the forward prefetcher exiting seven seconds
/// into a session with `reason=cancelled cancelled=true` and never coming back, with playback
/// running on for another eight minutes. The exit line says a `cancel()` happened and nothing
/// else, and it lands whenever the parked loop next looks, so the cause had to be reconstructed
/// from what else happened to log nearby: a whole-file subtitle reader that opened 67 microseconds
/// later. Two rounds went into that reconstruction. These pin the routing that makes it a read, now that
/// the reading is the session's subtitle source and the overlay is one of its consumers.
struct Issue496PrefetchCancelReasonTests {

    /// An engine whose subtitle source is reading for the overlay, once its routes are settled. The source's
    /// walk is held before its open (a producer restart in flight), so nothing is read and nothing races the
    /// assertions.
    @MainActor
    private func engineWithLivePrefetcher() async throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://s/movie.mov")!
        engine.softwareSubtitlePacketStore = SubtitlePacketStore()
        engine.testHookRestartInFlightOverride = true
        engine.startSubtitleSource()
        engine.subtitleDrainTargets[.primary] = 2
        engine.demandOverlaySubtitles()
        let deadline = Date().addingTimeInterval(10)
        while engine.subtitleSource?.isReading != true, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(engine.subtitleSource?.isReading == true)
        return engine
    }

    /// The stop is judged after the turn of the main actor that withdrew the last demand.
    @MainActor
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    @MainActor
    @Test("a sidecar taking over the primary names itself, not the mechanism it shares with teardown")
    func sidecarSelectionNamesItself() async throws {
        let engine = try await engineWithLivePrefetcher()
        defer { engine.subtitleSource?.close() }
        #expect(engine.subtitleSource?.isReading == true)
        engine.clearSubtitleDrainTarget(channel: .primary, reason: .sidecarSelected)
        try await settle()
        #expect(engine.lastSubtitleDrainStopReason == .sidecarSelected)
        #expect(engine.subtitleSource?.isReading == false)
    }

    @MainActor
    @Test("session teardown is distinguishable from a track switch, which is the whole ambiguity")
    func sessionStopIsADifferentReason() async throws {
        let engine = try await engineWithLivePrefetcher()
        defer { engine.subtitleSource?.close() }
        engine.stopSubtitleDrainer(reason: .sessionStopped)
        try await settle()
        #expect(engine.lastSubtitleDrainStopReason == .sessionStopped)
    }

    @MainActor
    @Test("closing the session's source while it reads is a session stop")
    func closeIsASessionStop() async throws {
        let engine = try await engineWithLivePrefetcher()
        engine.subtitleSource?.close()
        #expect(engine.lastSubtitleDrainStopReason == .sessionStopped)
    }

    @MainActor
    @Test("clearing the secondary while the primary still drains cancels nothing and claims nothing")
    func secondaryClearLeavesTheRunningPrefetcherAlone() async throws {
        let engine = try await engineWithLivePrefetcher()
        defer { engine.subtitleSource?.close() }
        engine.subtitleDrainTargets[.secondary] = 3
        engine.clearSubtitleDrainTarget(channel: .secondary, reason: .secondarySidecarSelected)
        try await settle()
        #expect(engine.lastSubtitleDrainStopReason == nil)
        #expect(engine.subtitleSource?.isReading == true)
    }

    @MainActor
    @Test("another consumer still asking keeps the reading, and the overlay's stop claims nothing")
    func anotherConsumerKeepsTheReading() async throws {
        let engine = try await engineWithLivePrefetcher()
        defer { engine.subtitleSource?.close() }
        engine.subtitleSource?.demand(.rendition, streams: [2], lead: { _ in 300 })
        engine.clearSubtitleDrainTarget(channel: .primary, reason: .sidecarSelected)
        try await settle()
        #expect(engine.lastSubtitleDrainStopReason == nil)
        #expect(engine.subtitleSource?.isReading == true)
    }

    @MainActor
    @Test("a cancel with no prefetcher running claims no reason, so the field never reads a stale one")
    func noRunningTaskRecordsNothing() async throws {
        let engine = try AetherEngine()
        engine.subtitleDrainTargets[.primary] = 2
        engine.clearSubtitleDrainTarget(channel: .primary, reason: .sidecarSelected)
        try await settle()
        #expect(engine.lastSubtitleDrainStopReason == nil)
    }

    @MainActor
    @Test("every teardown route carries a reason of its own: the log cannot collapse two causes into one")
    func reasonsAreDistinct() {
        let all: [SubtitleDrainStopReason] = [
            .sidecarSelected, .secondarySidecarSelected, .externalStoreBackfill,
            .closedCaptionsSelected, .injectedRenditionSelected, .liveRenditionSelected,
            .subtitlesCleared, .sessionStopped,
        ]
        #expect(Set(all.map(\.rawValue)).count == all.count)
    }
}
