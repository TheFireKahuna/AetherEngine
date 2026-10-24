// Only with the TrueHDObjectAudio trait (off by default).
#if TrueHDObjectAudio
import Accelerate
import Foundation

/// Brings object audio decoded at 96 or 192 kHz down to the 48 kHz everything after the decoder runs
/// at (`ObjectAudioRendering.sampleRate`): the renderer, the speaker bus and APAC, which encodes 48 kHz
/// only (measured on macOS 27: no converter to 96 or 192 kHz APAC). Metadata moves with the audio.
///
/// A linear-phase low-pass FIR, kept every `factor`-th sample (`vDSP_desamp`): flat to 20 kHz, and
/// everything from 28 kHz up, which would fold back below 20 kHz, attenuated by over 100 dB (Kaiser
/// window, beta 11). Its delay, half its length, is taken up front: the filter starts with that much
/// silence behind the first input frame, so output frame n is input frame n × factor and metadata
/// keeps its times exactly. The look-ahead this costs is carried from block to block: a block's last
/// `delay` output frames come out with the next one, and so do the updates that fall in them.
final class ObjectAudioDecimator {

    let factor: Int
    /// Output frames of look-ahead (the filter's half length at the output rate).
    static let delay = 24
    /// Output frame `n` is a function of the input `delay` either side of it. The look-ahead is taken
    /// inside (`delay`), so the timeline sees no latency.
    static let span = AudioStageSpan(latency: 0, memory: delay)
    private let taps: [Float]

    /// Per channel: input not yet consumed, the filter's history included.
    private var carry: [[Float]] = []
    private var scratch: [Float] = []
    private var outputs: [UnsafeMutablePointer<Float>] = []
    private var capacity = 0
    /// Input frame (since the decoder's reset) the next carried sample belongs to, at input rate, and
    /// the next output frame, at 48 kHz.
    private var nextOutput: Int64 = 0
    private var started = false
    private var waiting: [ObjectAudioMetadataUpdate] = []
    private var waitingAt: [Int64] = []

    /// `factor` is 2 (96 kHz) or 4 (192 kHz).
    init(factor: Int) {
        precondition(factor == 2 || factor == 4)
        self.factor = factor
        taps = Self.design(factor: factor)
    }

    deinit { outputs.forEach { $0.deallocate() } }

    /// The ratio from `sampleRate` to 48 kHz, nil when it is not 2 or 4.
    static func factor(from sampleRate: Int) -> Int? {
        let ratio = sampleRate / ObjectAudioRendering.sampleRate
        return ratio * ObjectAudioRendering.sampleRate == sampleRate && (ratio == 2 || ratio == 4) ? ratio : nil
    }

    /// Start again: the input jumps (a reset, damage), so what is carried belongs to nothing after it.
    func reset() {
        started = false
        carry = []
        waiting = []
        waitingAt = []
    }

    /// `channels` planes of `frames` input frames starting at input frame `inputStart`, with the
    /// updates inside them (frame offsets at the input rate). Returns the planes at 48 kHz (owned here,
    /// valid until the next call), the output frame they start at and the updates that fall in them.
    func process(planes: [UnsafePointer<Float>], frames: Int, inputStart: Int64,
                 updates: [ObjectAudioMetadataUpdate]) -> (planes: [UnsafePointer<Float>], start: Int64, frames: Int,
                                                          updates: [ObjectAudioMetadataUpdate]) {
        let half = Self.delay * factor
        if !started || carry.count != planes.count {
            // The first input frame sits at the filter's centre: half a filter of silence before it.
            carry = planes.map { _ in [Float](repeating: 0, count: half) }
            nextOutput = inputStart / Int64(factor)
            waiting = []
            waitingAt = []
            started = true
        }
        for update in updates {
            let at = (inputStart + Int64(update.frameOffset)) / Int64(factor)
            var u = update
            u.rampFrames = (update.rampFrames + factor / 2) / factor
            let i = waitingAt.firstIndex { $0 > at } ?? waitingAt.count
            waiting.insert(u, at: i)
            waitingAt.insert(at, at: i)
        }

        let length = taps.count
        let available = (carry.first?.count ?? 0) + frames
        let count = available >= length ? (available - length) / factor + 1 : 0
        if count > capacity {
            outputs.forEach { $0.deallocate() }
            outputs = []
            capacity = count
        }
        while outputs.count < planes.count {
            outputs.append(.allocate(capacity: max(capacity, 1)))
        }
        for (c, plane) in planes.enumerated() {
            carry[c].append(contentsOf: UnsafeBufferPointer(start: plane, count: frames))
            if count > 0 {
                carry[c].withUnsafeBufferPointer { input in
                    taps.withUnsafeBufferPointer { filter in
                        vDSP_desamp(input.baseAddress!, vDSP_Stride(factor), filter.baseAddress!, outputs[c],
                                    vDSP_Length(count), vDSP_Length(length))
                    }
                }
                carry[c].removeFirst(count * factor)
            }
        }

        let start = nextOutput
        nextOutput += Int64(count)
        var due: [ObjectAudioMetadataUpdate] = []
        while let at = waitingAt.first, at < nextOutput {
            var u = waiting.removeFirst()
            waitingAt.removeFirst()
            u.frameOffset = Int(max(0, at - start))
            due.append(u)
        }
        return (outputs.prefix(planes.count).map { UnsafePointer($0) }, start, count, due)
    }

    /// Windowed sinc, cut off at 24 kHz, `2 × delay × factor + 1` taps (odd, so the delay is a whole
    /// number of output frames), unit gain at DC.
    private static func design(factor: Int) -> [Float] {
        let length = 2 * delay * factor + 1
        let centre = Double(length - 1) / 2
        let cutoff = 24_000.0 / Double(ObjectAudioRendering.sampleRate * factor)   // cycles per input sample
        let beta = 11.0
        func i0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            while term > 1e-12 * sum {
                term *= (x / (2 * k)) * (x / (2 * k))
                sum += term
                k += 1
            }
            return sum
        }
        var taps = (0..<length).map { n -> Double in
            let t = Double(n) - centre
            let sinc = t == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * t) / (.pi * t)
            let r = t / centre
            return sinc * i0(beta * (1 - r * r).squareRoot()) / i0(beta)
        }
        let sum = taps.reduce(0, +)
        taps = taps.map { $0 / sum }
        return taps.map(Float.init)
    }
}
#endif
