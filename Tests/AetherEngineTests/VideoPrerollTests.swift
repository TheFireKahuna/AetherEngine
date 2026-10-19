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

    private static func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        return pb!
    }

    private static func time(_ index: Int) -> CMTime { CMTime(value: Int64(index) * 1000, timescale: 24000) }

    // MARK: - Renderer gate

    @Test("Off the FEL path the gate opens once frames reach videoPrerollSeconds past the clock")
    @MainActor
    func singleLayerGate() {
        let renderer = SampleBufferRenderer()
        renderer.setReorderDepth(SampleBufferRenderer.presentationOrderReorderDepth)
        let pixels = Self.makePixelBuffer()
        #expect(renderer.prerollSatisfied(clock: 0, live: false) == false, "nothing handed over yet")
        // One frame stays held for its duration, so 0 to 3 hands over 0 to 2.
        for i in 0...3 { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        #expect(renderer.prerollSatisfied(clock: 0, live: false) == false)
        renderer.enqueue(pixelBuffer: pixels, pts: Self.time(4))
        #expect(renderer.prerollSatisfied(clock: 0, live: false) == true)
        #expect(renderer.prerollSatisfied(clock: Self.time(2).seconds, live: false) == false)
    }

    @Test("Off the FEL path a live stream does not preroll")
    @MainActor
    func singleLayerLiveHasNoGate() {
        let renderer = SampleBufferRenderer()
        #expect(renderer.prerollSatisfied(clock: 0, live: true) == nil)
        renderer.setFELLookahead(enabled: true, frameRate: 24)
        #expect(renderer.prerollSatisfied(clock: 0, live: true) == false, "the FEL route still does")
    }

    @Test("A resume between keyframes counts from the target, not from the GOP decoded up to it")
    @MainActor
    func singleLayerGateAfterAResume() {
        let renderer = SampleBufferRenderer()
        renderer.setReorderDepth(SampleBufferRenderer.presentationOrderReorderDepth)
        let pixels = Self.makePixelBuffer()
        // #800: the keyframe sits 3 s before the target; everything up to it is decoded and skipped.
        let target = Self.time(2078).seconds
        renderer.setSkipThreshold(Self.time(2078))
        for i in 2000..<2078 { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        #expect(renderer.prerollSatisfied(clock: target, live: false) == false)
        for i in 2078...2082 { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        #expect(renderer.prerollSatisfied(clock: target, live: false) == true)
    }

    @Test("The gate opens once the contiguous frames reach the preroll past the clock")
    @MainActor
    func gateCountsContiguousFrames() {
        let renderer = SampleBufferRenderer()
        renderer.setFELLookahead(enabled: true, frameRate: 24)
        renderer.setArrivalOrderHandover(frameRate: 24)
        let pixels = Self.makePixelBuffer()
        #expect(renderer.prerollSatisfied(clock: 0, live: false) == false, "nothing handed over yet")
        // A frame past a gap does not count: 0, 1, 2 and then 6 leave the frontier at frame 2.
        for i in [0, 1, 2, 6] { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        #expect(renderer.prerollSatisfied(clock: 0, live: false) == false)
        // 0 to 3 is four frames, 0.1667 s: just short of the preroll.
        renderer.enqueue(pixelBuffer: pixels, pts: Self.time(3))
        #expect(renderer.prerollSatisfied(clock: 0, live: false) == false)
        renderer.enqueue(pixelBuffer: pixels, pts: Self.time(4))
        #expect(renderer.prerollSatisfied(clock: 0, live: false) == true)
        // The same frames are not enough for a clock further on.
        #expect(renderer.prerollSatisfied(clock: Self.time(4).seconds, live: false) == false)
    }

    @Test("After a seek the gate counts from the seek target, not from the frames before it")
    @MainActor
    func gateRestartsAtTheSeekTarget() {
        let renderer = SampleBufferRenderer()
        renderer.setFELLookahead(enabled: true, frameRate: 24)
        renderer.setArrivalOrderHandover(frameRate: 24)
        let pixels = Self.makePixelBuffer()
        for i in 0..<20 { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        renderer.flush(removingDisplayedImage: false)
        renderer.setSkipThreshold(Self.time(100))
        let target = Self.time(100).seconds
        #expect(renderer.prerollSatisfied(clock: target, live: false) == false)
        for i in 100..<105 { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        #expect(renderer.prerollSatisfied(clock: target, live: false) == true)
    }

    @Test("After a seek to a target between two frames the gate still opens without a running clock",
          arguments: [0.1, 0.4, 0.6, 0.9])
    @MainActor
    func gateOpensAfterAnOffGridSeek(phase: Double) {
        let renderer = SampleBufferRenderer()
        renderer.setFELLookahead(enabled: true, frameRate: 24)
        renderer.setArrivalOrderHandover(frameRate: 24)
        let pixels = Self.makePixelBuffer()
        let target = (100 + phase) / 24
        renderer.setSkipThreshold(CMTime(seconds: target, preferredTimescale: 90000))
        // Decode order from the GOP's anchor below the target, as the decoder delivers it after a seek.
        for i in PresentationFloorTests.decodeOrder(gop: 8, frames: 24, startingAt: 96) {
            renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i))
        }
        #expect(renderer.prerollSatisfied(clock: target, live: false) == true)
        #expect(renderer.framesBelowFloor == 0)
    }

    @Test("Every frame handed over tells the preroll, on both handover paths and at the drain",
          arguments: [false, true])
    @MainActor
    func handoverTellsThePreroll(arrivalOrder: Bool) {
        let renderer = SampleBufferRenderer()
        if arrivalOrder {
            renderer.setFELLookahead(enabled: true, frameRate: 24)
            renderer.setArrivalOrderHandover(frameRate: 24)
        } else {
            renderer.setReorderDepth(SampleBufferRenderer.presentationOrderReorderDepth)
        }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        renderer.setPrerollAdvancedObserver { calls.withLock { $0 += 1 } }
        let pixels = Self.makePixelBuffer()
        for i in 0..<5 { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        // The reorder path holds one frame back; the arrival path hands each over as it comes.
        #expect(calls.withLock { $0 } == (arrivalOrder ? 5 : 4))
        renderer.drainReorderBuffer()
        #expect(calls.withLock { $0 } == 5)
        renderer.setPrerollAdvancedObserver(nil)
        renderer.enqueue(pixelBuffer: pixels, pts: Self.time(5))
        renderer.drainReorderBuffer()
        #expect(calls.withLock { $0 } == 5, "a cleared observer is not called")
    }

    @Test("At 60 fps the preroll fits inside the look-ahead window")
    @MainActor
    func prerollFitsTheLookaheadAt60() {
        let renderer = SampleBufferRenderer()
        renderer.setFELLookahead(enabled: true, frameRate: 60)
        renderer.setArrivalOrderHandover(frameRate: 60)
        let pixels = Self.makePixelBuffer()
        // Everything the look-ahead admits with the clock held at 0.
        var admitted = 0
        while SampleBufferRenderer.mayEnqueueAnotherFrame(
            rendererReady: true, felFrameRate: 60, framePTS: Double(admitted) / 60,
            clockSeconds: 0, clockArmed: true) {
            renderer.enqueue(pixelBuffer: pixels, pts: CMTime(value: Int64(admitted), timescale: 60))
            admitted += 1
        }
        #expect(renderer.prerollSatisfied(clock: 0, live: false) == true, "\(admitted) frames admitted")
    }

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

    @Test("The handover that fills the renderer's preroll starts the clock", .timeLimit(.minutes(1)))
    @MainActor
    func rendererHandoverStartsTheClock() async throws {
        let output = AudioOutput()
        output.prerollTimeoutOverride = 60   // as in `waitingPrerollDoesNotPoll`
        let renderer = SampleBufferRenderer()
        renderer.setReorderDepth(SampleBufferRenderer.presentationOrderReorderDepth)
        // Wired as the software host wires them.
        output.videoPrerollSatisfied = { renderer.prerollSatisfied(clock: $0, live: false) }
        renderer.setPrerollAdvancedObserver { [weak output] in output?.videoPrerollAdvanced() }
        let pixels = Self.makePixelBuffer()
        output.seekClock(to: .zero, rate: 1)
        for i in 0...3 { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        let early = try await waitFor(upTo: .milliseconds(200)) { output.synchronizer.rate != 0 }
        #expect(!early, "frames up to 0.083 s are not the 0.125 s preroll")
        renderer.enqueue(pixelBuffer: pixels, pts: Self.time(4))
        try await waitFor { output.synchronizer.rate == 1 }
        #expect(output.lastPrerollTimedOut == false)
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
}
