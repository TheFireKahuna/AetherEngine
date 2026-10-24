import Testing
import Foundation
@testable import AetherEngine

/// The APAC encoder carries samples over full scale through unchanged (#731), so the bridge limits
/// the rendered bed itself. These pin what that must and must not do to the programme.
@Suite("Rendered bed peak limiter")
struct PeakLimiterTests {

    /// Through the limiter and out the other side: what it hands on, then what it still holds, so
    /// frame `i` of the result is frame `i` of the input.
    private func run(_ limiter: inout PeakLimiter, _ channels: [[Float]], lfe: Int? = nil) -> [[Float]] {
        let frames = channels[0].count
        let planes = channels.map { c -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames + PeakLimiter.attackFrames)
            p.initialize(from: c, count: frames)
            return p
        }
        defer { planes.forEach { $0.deallocate() } }
        var out = Array(repeating: [Float](), count: channels.count)
        let handed = limiter.process(planes, frameCount: frames, lfe: lfe)
        for c in out.indices { out[c] += UnsafeBufferPointer(start: planes[c], count: handed) }
        let drained = limiter.drain(into: planes, lfe: lfe)
        for c in out.indices { out[c] += UnsafeBufferPointer(start: planes[c], count: drained) }
        return out
    }

    /// Fed in `chunk`-frame pieces without draining, as the bridge feeds it: what comes out, in order.
    private func stream(_ limiter: inout PeakLimiter, _ signal: [Float], from start: Int, chunk: Int = 2048) -> [Float] {
        let plane = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        defer { plane.deallocate() }
        var out: [Float] = []
        var at = start
        while at < signal.count {
            let n = min(chunk, signal.count - at)
            plane.update(from: Array(signal[at..<(at + n)]), count: n)
            let handed = limiter.process([plane], frameCount: n)
            out += UnsafeBufferPointer(start: plane, count: handed)
            at += n
        }
        return out
    }

    private func tone(_ amplitude: Float, frames: Int, hz: Float = 1000) -> [Float] {
        (0..<frames).map { amplitude * sin(Float($0) * 2 * .pi * hz / 48_000) }
    }

    @Test("a bed under the threshold passes bit for bit")
    func transparentBelowThreshold() {
        var limiter = PeakLimiter(sampleRate: 48_000, channels: 2)
        let input = [tone(0.9, frames: 4800), tone(0.5, frames: 4800, hz: 300)]
        #expect(run(&limiter, input) == input)
        #expect(limiter.takeLimitedFrames().frames == 0)
    }

    @Test("no sample leaves above the threshold, however loud the input")
    func neverAboveThreshold() {
        var limiter = PeakLimiter(sampleRate: 48_000, channels: 2)
        let out = run(&limiter, [tone(4, frames: 9600), tone(1.5, frames: 9600, hz: 70)])
        let peak = out.flatMap { $0 }.map(abs).max()!
        #expect(peak <= PeakLimiter.threshold + 1e-6)
        let taken = limiter.takeLimitedFrames()
        #expect(taken.frames > 0)
        #expect(taken.deepestDB < -12, "a 4.0 peak needs about -12.2 dB")
        #expect(limiter.takeLimitedFrames().frames == 0, "the count starts over once taken")
    }

    @Test("one gain for every channel, so an object between two speakers stays where it is")
    func linkedAcrossChannels() {
        var limiter = PeakLimiter(sampleRate: 48_000, channels: 2)
        let left = tone(2, frames: 4800)
        let right = left.map { $0 * 0.5 }
        let out = run(&limiter, [left, right])
        for i in stride(from: 0, to: 4800, by: 37) where abs(out[0][i]) > 1e-4 {
            #expect(abs(out[1][i] / out[0][i] - 0.5) < 1e-4, "frame \(i)")
        }
    }

    @Test("after a loud burst the gain recovers instead of staying down")
    func releases() {
        var limiter = PeakLimiter(sampleRate: 48_000, channels: 1)
        _ = run(&limiter, [tone(3, frames: 2400)])
        // Two seconds of quiet programme: eight release time constants later it passes untouched.
        let quiet = tone(0.5, frames: 96_000)
        let out = run(&limiter, [quiet])
        #expect(abs(out[0][95_000...].map(abs).max()! - 0.5) < 1e-3)
        #expect(abs(out[0][0..<1200].map(abs).max()!) < 0.5, "right after the burst it is still holding down")
    }

    @Test("a reset forgets the burst")
    func resetForgets() {
        var limiter = PeakLimiter(sampleRate: 48_000, channels: 1)
        _ = run(&limiter, [tone(3, frames: 2400)])
        limiter.reset()
        let quiet = tone(0.5, frames: 4800)
        #expect(run(&limiter, [quiet]) == [quiet])
    }

    @Test("an LFE peaking at full scale ducks nothing")
    func lfeFullScaleDucksNothing() {
        var limiter = PeakLimiter(sampleRate: 48_000, channels: 2)
        let input = [tone(0.5, frames: 4800), tone(1, frames: 4800, hz: 40)]
        #expect(run(&limiter, input, lfe: 1) == input)
        #expect(limiter.takeLimitedFrames().frames == 0)
    }

    @Test("the other channels' limiting takes the LFE down with them, in proportion")
    func lfeFollowsSharedGain() {
        var limiter = PeakLimiter(sampleRate: 48_000, channels: 2)
        let main = tone(2, frames: 4800)
        let lfe = main.map { $0 * 0.25 }
        let out = run(&limiter, [main, lfe], lfe: 1)
        for i in stride(from: 0, to: 4800, by: 37) where abs(out[0][i]) > 1e-4 {
            #expect(abs(out[1][i] / out[0][i] - 0.25) < 1e-4, "frame \(i)")
        }
    }

    @Test("an LFE over full scale is held at full scale on its own")
    func lfeGuard() {
        var limiter = PeakLimiter(sampleRate: 48_000, channels: 2)
        let main = tone(0.5, frames: 9600)
        let out = run(&limiter, [main, tone(2, frames: 9600, hz: 40)], lfe: 1)
        #expect(out[0] == main, "the other channels are untouched")
        #expect(out[1].map(abs).max()! <= PeakLimiter.lfeThreshold + 1e-6)
    }
    // MARK: - Span

    @Test("every frame comes out where it went in, `attackFrames` later, whatever the chunking")
    func latencyIsTheLookAhead() {
        var limiter = PeakLimiter(sampleRate: 48_000, channels: 1)
        #expect(PeakLimiter.span(sampleRate: 48_000).latency == PeakLimiter.attackFrames)
        let signal = (0..<10_000).map { Float($0 % 977) / 1000 }
        let out = stream(&limiter, signal, from: 0, chunk: 333)
        #expect(out.count == signal.count - PeakLimiter.attackFrames)
        #expect(limiter.backlog == PeakLimiter.attackFrames)
        #expect(out == Array(signal[0..<out.count]), "quiet enough to pass untouched, in place")
    }

    @Test("a run started anywhere agrees with continuous playback bit for bit once it has run `memory`",
          arguments: [3_000, 20_011, 47_500])
    func memoryIsFinite(start: Int) {
        // Overloads of every depth, shallow ones that release at the rate and deep ones (+20 dB)
        // that release over the limit, close enough together that each starts inside the last.
        var signal = [Float](repeating: 0, count: 96_000)
        for (i, at) in stride(from: 1_000, to: 90_000, by: 4_100).enumerated() {
            let peak: Float = [1.3, 10, 2.5, 6, 1.05][i % 5]
            for k in 0..<600 { signal[at + k] = peak * sin(Float(k) * 0.07) }
        }
        var continuous = PeakLimiter(sampleRate: 48_000, channels: 1)
        let whole = stream(&continuous, signal, from: 0)
        var restarted = PeakLimiter(sampleRate: 48_000, channels: 1)
        let part = stream(&restarted, signal, from: start, chunk: 1_500)
        let memory = PeakLimiter.span(sampleRate: 48_000).memory
        let from = memory
        let count = min(part.count, whole.count - start) - from
        #expect(count > 10_000)
        #expect(Array(part[from..<(from + count)]) == Array(whole[(start + from)..<(start + from + count)]))
    }

    @Test("the reduction is already in place when the peak arrives, eased in rather than stepped")
    func attackEasesIn() {
        var limiter = PeakLimiter(sampleRate: 48_000, channels: 1)
        var signal = [Float](repeating: 0.5, count: 4_800)
        signal[2_400] = 2
        let out = run(&limiter, [signal])[0]
        #expect(abs(out[2_400]) <= PeakLimiter.threshold + 1e-6)
        let gains = (2_400 - PeakLimiter.attackFrames - 1...2_400).map { out[$0] / signal[$0] }
        #expect(gains.first == 1)
        for (a, b) in zip(gains, gains.dropFirst()) { #expect(b <= a) }
        #expect(gains[gains.count - 2] < 1, "the frame before the peak is already reduced")
    }

    @Test("a reduction deeper than the rate can release in time still ends within the limit")
    func deepReleaseEnds() {
        var limiter = PeakLimiter(sampleRate: 48_000, channels: 1)
        var signal = [Float](repeating: 0.5, count: 48_000)
        signal[1_000] = 40   // 32 dB over: 0.9 s at the rate
        let out = run(&limiter, [signal])[0]
        let end = 1_000 + PeakLimiter.releaseLimitFrames(sampleRate: 48_000)
        #expect(out[end - 2_400] < 0.5, "still released partway")
        #expect(Array(out[end...]) == Array(signal[end...]))
    }

    @Test("a shallow reduction releases at the rate, as the exponential envelope did")
    func shallowReleaseKeepsTheRate() {
        var limiter = PeakLimiter(sampleRate: 48_000, channels: 1)
        var signal = [Float](repeating: 0.5, count: 48_000)
        signal[1_000] = 0.98 * 2   // 6.02 dB over: 0.173 s at 34.7 dB/s
        let out = run(&limiter, [signal])[0]
        let back = 1_000 + Int(0.25 * 48_000 * log(2.0))
        #expect(out[back - 100] < 0.5)
        #expect(Array(out[(back + 2)...]) == Array(signal[(back + 2)...]))
    }
}
