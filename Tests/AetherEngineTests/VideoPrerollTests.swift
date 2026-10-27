import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import os
import Testing
@testable import AetherEngine

/// The software path's start: the clock waits at rate 0 until frames are in the layer, then starts a
/// lead from now (`AudioOutput.videoPrerollSatisfied`, `prerollStartLead(outputLatency:)`,
/// `SampleBufferRenderer.prerollSatisfied(clock:live:)`). On an Apple TV 4K a clock started the moment
/// the first packet arrived dropped 3 to 7 frames at every start and seek; with both, none on FEL
/// (#774). Every other VOD route since #800.
@Suite("Video preroll before the clock starts")
struct VideoPrerollTests {

    // MARK: - Clock

    /// A gate the test opens by hand. Nothing polls it: like the renderer's handover, opening it
    /// has to tell the output (`AudioOutput.videoPrerollAdvanced()`). `evaluations` counts how often
    /// the output asked.
    private final class Gate: Sendable {
        private let open = OSAllocatedUnfairLock(initialState: false)
        private let asked = OSAllocatedUnfairLock(initialState: 0)
        func set(_ value: Bool, telling output: AudioOutput? = nil) {
            open.withLock { $0 = value }
            output?.videoPrerollAdvanced()
        }
        var isOpen: Bool { asked.withLock { $0 += 1 }; return open.withLock { $0 } }
        var evaluations: Int { asked.withLock { $0 } }
    }

    @Test("Without a gate seekClock starts the clock at once", .timeLimit(.minutes(1)))
    func startsAtOnceWithoutAGate() {
        let output = AudioOutput()
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        #expect(output.synchronizer.rate == 1)
    }

    @Test("A closed gate holds the clock at rate 0 and the start follows when it opens",
          .timeLimit(.minutes(1)))
    func holdsUntilTheGateOpens() async throws {
        let output = AudioOutput()
        let gate = Gate()
        output.videoPrerollSatisfied = { _ in gate.isOpen }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        #expect(output.synchronizer.rate == 0)
        #expect(abs(output.synchronizer.currentTime().seconds - 5) < 0.001)
        let opened = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        gate.set(true, telling: output)
        try await waitFor { output.synchronizer.rate == 1 }
        // The start was scheduled `lastPrerollStartLead` after the gate opened, so however late this
        // runs, the clock has not run longer than the time since then minus the lead.
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let lead = try #require(output.lastPrerollStartLead)
        let ran = max(0, now - opened - lead)
        #expect(output.synchronizer.currentTime().seconds <= 5 + ran + 0.02)
    }

    @Test("A rate set while the preroll waits is the rate it starts at", .timeLimit(.minutes(1)))
    func setRateDuringPrerollIsTheStartRate() async throws {
        let output = AudioOutput()
        let gate = Gate()
        output.videoPrerollSatisfied = { _ in gate.isOpen }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        output.setRate(1.5)
        #expect(output.synchronizer.rate == 0, "the rate does not start the clock early")
        gate.set(true, telling: output)
        try await waitFor { output.synchronizer.rate == 1.5 }
    }

    @Test("A pause cancels the pending start", .timeLimit(.minutes(1)))
    func pauseCancelsThePreroll() async throws {
        let output = AudioOutput()
        let gate = Gate()
        output.videoPrerollSatisfied = { _ in gate.isOpen }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        output.pause()
        gate.set(true, telling: output)
        let started = try await waitFor(upTo: .milliseconds(300)) { output.synchronizer.rate != 0 }
        #expect(!started)
    }

    @Test("A play after a seek landed while paused starts through the preroll", .timeLimit(.minutes(1)))
    func playAfterAPausedSeekPrerolls() async throws {
        let output = AudioOutput()
        let gate = Gate()
        output.videoPrerollSatisfied = { _ in gate.isOpen }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 0)
        #expect(!output.prerollPending, "a paused seek does not ask the gate")
        output.setRate(1)
        #expect(output.synchronizer.rate == 0, "nothing is queued yet")
        #expect(output.prerollPending, "the host must not read this clock as stalled")
        gate.set(true, telling: output)
        try await waitFor { output.synchronizer.rate == 1 }
        #expect(!output.prerollPending)
    }

    @Test("A gate that never opens starts the clock after the timeout", .timeLimit(.minutes(1)))
    func timesOut() async throws {
        let output = AudioOutput()
        output.videoPrerollSatisfied = { _ in false }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        #expect(output.synchronizer.rate == 0)
        try await waitFor { output.synchronizer.rate == 1 }
    }

    @Test("A waiting preroll asks the gate on each handover, not on a timer", .timeLimit(.minutes(1)))
    func waitingPrerollDoesNotPoll() async throws {
        let output = AudioOutput()
        // Out of reach of the waits below even under the one-thread pool lane, where they have
        // outlasted the real 2 s timeout and its tick started the clock as designed.
        output.prerollTimeoutOverride = 60
        let gate = Gate()
        output.videoPrerollSatisfied = { _ in gate.isOpen }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        // The seek's own question, and the one asked once the preroll was armed.
        try await waitFor { gate.evaluations >= 2 }
        // A gate that opens with nobody saying so stays unseen: the 2 ms poll this replaced asked it
        // about 300 times a second (measured on macOS), and would have started the clock here.
        gate.set(true)
        let started = try await waitFor(upTo: .milliseconds(300)) { output.synchronizer.rate != 0 }
        #expect(!started)
        // Nothing asked it since.
        #expect(gate.evaluations <= 2, "\(gate.evaluations) evaluations")
        #expect(output.prerollPending)
        gate.set(true, telling: output)
        try await waitFor { output.synchronizer.rate == 1 }
        #expect(output.lastPrerollTimedOut == false, "the handover started it, not the timeout")
        #expect(output.prerollStartCount == 1)
    }

    @Test("A gate that never opens is asked once more at the timeout, not on the way to it",
          .timeLimit(.minutes(1)))
    func timeoutIsOneShot() async throws {
        let output = AudioOutput()
        let gate = Gate()
        output.videoPrerollSatisfied = { _ in gate.isOpen }
        let armed = ContinuousClock.now
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        try await waitFor { output.synchronizer.rate == 1 }
        #expect(ContinuousClock.now - armed >= .seconds(AudioOutput.prerollTimeout) - .milliseconds(50))
        #expect(output.lastPrerollTimedOut == true)
        #expect(gate.evaluations <= 3, "seek, arm and timeout: \(gate.evaluations)")
        #expect(output.prerollStartCount == 1)
    }

    @Test("A seek that lands while a handover is being judged keeps the clock where it put it",
          .timeLimit(.minutes(1)))
    func seekDuringAnEvaluationWins() async throws {
        let output = AudioOutput()
        let gate = Gate()
        let reseek = OSAllocatedUnfairLock(initialState: false)
        output.videoPrerollSatisfied = { _ in
            // The paused seek arrives between the gate's answer and the start it would trigger.
            if reseek.withLock({ $0 }), gate.isOpen {
                reseek.withLock { $0 = false }
                output.seekClock(to: CMTime(seconds: 9, preferredTimescale: 90000), rate: 0)
                return true
            }
            return gate.isOpen
        }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        reseek.withLock { $0 = true }
        gate.set(true, telling: output)
        try await waitFor { !reseek.withLock { $0 } }
        // Stale handovers for the old seek change nothing either.
        for _ in 0..<5 { output.videoPrerollAdvanced() }
        let started = try await waitFor(upTo: .milliseconds(300)) { output.synchronizer.rate != 0 }
        #expect(!started)
        #expect(abs(output.synchronizer.currentTime().seconds - 9) < 0.001)
        #expect(!output.prerollPending)
        #expect(output.prerollStartCount == 0)
    }

    @Test("Handovers racing each other and the timeout start the clock once", .timeLimit(.minutes(1)))
    func handoversAndTimeoutStartOnce() async throws {
        let output = AudioOutput()
        let gate = Gate()
        output.videoPrerollSatisfied = { _ in gate.isOpen }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        // Open the gate right at the timeout and fire handovers from several threads around it.
        let fire = DispatchGroup()
        for lane in 0..<4 {
            DispatchQueue.global(qos: .userInitiated).async(group: fire) {
                let start = CACurrentMediaTime()
                while CACurrentMediaTime() - start < AudioOutput.prerollTimeout + 0.1 {
                    if lane == 0, CACurrentMediaTime() - start > AudioOutput.prerollTimeout - 0.01 {
                        gate.set(true)
                    }
                    output.videoPrerollAdvanced()
                    usleep(200)
                }
            }
        }
        try await waitFor { output.synchronizer.rate == 1 }
        try await waitFor { fire.wait(timeout: .now()) == .success }
        #expect(output.prerollStartCount == 1)
        #expect(!output.prerollPending)
    }

    @Test("The start lead follows the route's latency, capped at the validated 250 ms")
    func startLeadFollowsTheRoute() {
        let margin = 0.112
        // The measured HDMI route gets exactly the lead that was validated on it.
        #expect(abs(AudioOutput.prerollStartLead(outputLatency: 0.138, margin: margin) - 0.25) < 1e-9)
        // A faster route starts sooner.
        #expect(abs(AudioOutput.prerollStartLead(outputLatency: 0.020, margin: margin) - 0.132) < 1e-9)
        // A buffered AirPlay route's seconds of latency are not waited for.
        #expect(AudioOutput.prerollStartLead(outputLatency: 2.0, margin: margin) == AudioOutput.prerollStartLeadCeiling)
        // No session (macOS) or a nonsense reading: the ceiling, as before this was adaptive.
        #expect(AudioOutput.prerollStartLead(outputLatency: nil, margin: margin) == AudioOutput.prerollStartLeadCeiling)
        #expect(AudioOutput.prerollStartLead(outputLatency: .nan, margin: margin) == AudioOutput.prerollStartLeadCeiling)
        #expect(AudioOutput.prerollStartLead(outputLatency: -1, margin: margin) == AudioOutput.prerollStartLeadCeiling)
        // A negative margin counts as none.
        #expect(abs(AudioOutput.prerollStartLead(outputLatency: 0.05, margin: -1) - 0.05) < 1e-9)
    }

    // MARK: - Decoder progress (#800)

    @Test("A hold waits on while the decoder produces frames, up to the cap")
    func progressExtendsTheTimeout() {
        #expect(AudioOutput.prerollKeepsWaiting(waited: 1.9, sinceProgress: 1.9))
        #expect(!AudioOutput.prerollKeepsWaiting(waited: 2.0, sinceProgress: 2.0), "no progress: the plain timeout")
        #expect(AudioOutput.prerollKeepsWaiting(waited: 3.5, sinceProgress: 0.1), "4K AV1 still decoding up to the target")
        #expect(!AudioOutput.prerollKeepsWaiting(waited: 3.5, sinceProgress: 2.0), "the decoder stopped")
        #expect(!AudioOutput.prerollKeepsWaiting(waited: AudioOutput.prerollProgressCap, sinceProgress: 0))
    }

    /// A frame counter the test advances by hand.
    private final class Progress: Sendable {
        private let count = OSAllocatedUnfairLock<UInt64>(initialState: 0)
        func tick() { count.withLock { $0 &+= 1 } }
        var value: UInt64 { count.withLock { $0 } }
    }

    /// Every hold transition `AudioOutput` reports.
    private final class Transitions: Sendable {
        private let list = OSAllocatedUnfairLock<[AudioOutput.PrerollTransition]>(initialState: [])
        func append(_ transition: AudioOutput.PrerollTransition) { list.withLock { $0.append(transition) } }
        var events: [ClockHoldEvent] { list.withLock { $0.map(\.event) } }
        var generations: [Int] { list.withLock { $0.map(\.generation) } }
    }

    @Test("A decoder still producing frames holds the clock past the plain timeout", .timeLimit(.minutes(1)))
    func decoderProgressHoldsPastTheTimeout() async throws {
        let output = AudioOutput()
        let progress = Progress()
        // Both run in the hold's own poll, off the cooperative pool: a loop of `Task.sleep` ticks
        // starved past `prerollTimeout` on CI's one-thread pool and read as a decoder that stopped.
        let opensAt = CACurrentMediaTime() + AudioOutput.prerollTimeout + 0.5
        output.videoPrerollSatisfied = { _ in CACurrentMediaTime() >= opensAt }
        output.videoPrerollProgress = { progress.tick(); return progress.value }
        let transitions = Transitions()
        output.onPrerollTransition = { transitions.append($0) }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        // The release is reported right after the start, so waiting on the rate can read between them.
        try await waitFor { transitions.events.count == 2 }
        #expect(output.synchronizer.rate == 1)
        guard case .released(.ready(let waited))? = transitions.events.last else {
            Issue.record("expected a ready release, got \(transitions.events)")
            return
        }
        #expect(waited > AudioOutput.prerollTimeout)
        #expect(transitions.events.first == .began)
    }

    @Test("A hold reports its start and a timed-out release", .timeLimit(.minutes(1)))
    func reportsATimedOutHold() async throws {
        let output = AudioOutput()
        let transitions = Transitions()
        output.videoPrerollSatisfied = { _ in false }
        output.onPrerollTransition = { transitions.append($0) }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        #expect(transitions.events == [.began])
        try await waitFor { transitions.events.count == 2 }
        #expect(output.synchronizer.rate == 1)
        guard transitions.events.count == 2, case .released(.timedOut)? = transitions.events.last else {
            Issue.record("expected began then timedOut, got \(transitions.events)")
            return
        }
    }

    @Test("A newer seek and a pause release a waiting hold as cancelled", .timeLimit(.minutes(1)))
    func cancelledHoldsAreReported() {
        let output = AudioOutput()
        let transitions = Transitions()
        output.videoPrerollSatisfied = { _ in false }
        output.onPrerollTransition = { transitions.append($0) }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        output.seekClock(to: CMTime(seconds: 9, preferredTimescale: 90000), rate: 1)
        output.pause()
        output.pause()
        #expect(transitions.events == [.began, .released(.cancelled), .began, .released(.cancelled)])
        let gens = transitions.generations
        #expect(gens.count == 4 && gens[0] == gens[1] && gens[2] == gens[3] && gens[2] > gens[0])
    }

    @Test("A start whose frames are already queued does not report a hold", .timeLimit(.minutes(1)))
    func readyStartIsNoHold() {
        let output = AudioOutput()
        let transitions = Transitions()
        output.videoPrerollSatisfied = { _ in true }
        output.onPrerollTransition = { transitions.append($0) }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        output.stop()
        #expect(transitions.events.isEmpty)
    }
}
