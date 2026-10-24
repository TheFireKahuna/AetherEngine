import Foundation

/// Keeps the rendered bed under full scale before it reaches the APAC encoder (#731).
///
/// The encoder does not clip: measured on macOS 27, a 1 kHz tone at amplitude 2.0 or 4.0 decodes
/// back at 2.000 / 4.001, so anything over 1.0 travels on and clips wherever the chain first meets
/// fixed point. A rendered Atmos bed can get there: OAMD gains reach +15 dB, and up to sixteen
/// elements sum into one speaker.
///
/// One gain for all channels, so the limiter never moves an object. The gain is worked out in dB of
/// reduction from what every frame needs (`log2(peak / threshold)`), and each frame's need reaches
/// a short way ahead of it and a bounded way behind:
/// - Attack: the reduction eases in over the `attackFrames` before the frame that needs it, linear
///   in dB, so a peak is met by a gain already at its value instead of a step on it (a gain step is
///   broadband distortion). That look-ahead is the limiter's latency: output frame `p` is input frame
///   `p`, handed on `attackFrames` later, and the bridge's timeline counts it like the splitter's.
/// - Release: a reduction comes back at `releaseSeconds`' exponential rate (34.7 dB/s), the way a
///   peak envelope decaying by that time constant does, but never takes longer than
///   `releaseLimitSeconds`: one too deep to come back in that time at that rate (over 12.2 dB) comes
///   back linearly in dB over exactly that time instead.
///
/// So the gain at any frame is a function of the input from `releaseLimitSeconds` before it to
/// `attackFrames` after it, and of nothing else (`span`): a run started anywhere comes out as
/// continuous playback does once it has run that long, which is what a restart's pre-roll relies on.
/// An exponential release that is not cut off carries every past overload forward by an amount that
/// grows with its depth, and float input has no ceiling.
///
/// On a bed that stays under the threshold the limiter does nothing at all: every frame passes bit
/// for bit, only later.
///
/// The LFE is not listened to. It is the source's own channel at its own gain, and lossless LFE
/// routinely peaks at 0 dBFS (the Dolby demo disc's LFE check does), which at the shared threshold
/// would duck every channel for a peak that was never over full scale. The shared gain still
/// applies to the LFE when the other channels trip it, so the LFE keeps its balance with them.
/// Only an element gain above 0 dB can take the LFE over full scale; a guard of its own holds it
/// there, at 0 dBFS (the codec's overshoot is a high-frequency effect, and the LFE has none). The
/// LFE then takes whichever of the two gains is lower, which is what applying the guard to the
/// already reduced LFE gives.
struct PeakLimiter {

    /// −0.18 dBFS, a margin for the codec's own overshoot (+0.4 dB measured on an 8 kHz tone).
    static let threshold: Float = 0.98
    /// Where the LFE's own guard starts: full scale.
    static let lfeThreshold: Float = 1
    /// 2 ms of look-ahead, over which a reduction eases in.
    static let attackFrames = 96
    /// The time constant of the release rate.
    static let releaseSeconds: Double = 0.25
    /// The longest a reduction takes to come back, whatever its depth.
    static let releaseLimitSeconds: Double = 0.35

    /// Output at `p` takes input from `releaseLimitSeconds` before `p` to `attackFrames` after it.
    static func span(sampleRate: Int) -> AudioStageSpan {
        AudioStageSpan(latency: attackFrames, memory: releaseLimitFrames(sampleRate: sampleRate))
    }

    static func releaseLimitFrames(sampleRate: Int) -> Int {
        Int((releaseLimitSeconds * Double(sampleRate)).rounded(.up))
    }

    /// Frames the limiter is holding: they come out with the next input, or from `drain`.
    var backlog: Int { held }

    private let channels: Int
    private let releaseLimit: Int
    /// Release per frame, in log2 units: `releaseSeconds`' exponential decay of a peak envelope.
    private let releaseStep: Float
    /// A reduction deeper than this (log2 units) cannot come back at `releaseStep` within
    /// `releaseLimit`, so it comes back over `releaseLimit` instead.
    private let deepFrom: Float

    /// Input not yet handed on, per channel: the held frames, then the frames being processed.
    private var work: [[Float]]
    private var held = 0
    /// Per frame of `work`, the reduction it needs (log2 units, 0 when it needs none), for the
    /// shared gain and for the LFE guard.
    private var need: [Float] = []
    private var lfeNeed: [Float] = []
    private var shared: Release
    private var lfeGuard: Release
    /// Frames handed on since the last `reset`: the clock the release ages reductions by.
    private var frame: Int64 = 0
    /// Frames the limiter has reduced since the last `takeLimitedFrames`.
    private var limitedFrames = 0
    /// Deepest reduction since the last `takeLimitedFrames`, as a linear gain.
    private var deepestGain: Float = 1

    init(sampleRate: Int, channels: Int) {
        self.channels = channels
        releaseLimit = Self.releaseLimitFrames(sampleRate: sampleRate)
        releaseStep = Float(1 / (Self.releaseSeconds * Double(sampleRate) * M_LN2))
        deepFrom = releaseStep * Float(releaseLimit)
        work = Array(repeating: [], count: channels)
        shared = Release(limit: releaseLimit)
        lfeGuard = Release(limit: releaseLimit)
    }

    /// Limit `frameCount` frames of every plane and hand on as many as the look-ahead allows,
    /// written over the front of the planes: the frames held from the last call first, then these.
    /// Returns how many: `frameCount` once the look-ahead is full, `attackFrames` fewer on the first
    /// call after a `reset`. `lfe` is the LFE's plane, which the shared gain follows but does not
    /// listen to.
    mutating func process(_ planes: [UnsafeMutablePointer<Float>], frameCount: Int, lfe: Int? = nil) -> Int {
        precondition(planes.count == channels)
        guard frameCount > 0 else { return 0 }
        append(planes, frameCount: frameCount, lfe: lfe)
        let out = max(0, held + frameCount - Self.attackFrames)
        handOn(out, available: held + frameCount, into: planes, lfe: lfe)
        return out
    }

    /// Hand on every frame still held, written over the front of the planes (which must have room
    /// for `backlog`), as the end of the input: nothing after them is looked ahead to.
    mutating func drain(into planes: [UnsafeMutablePointer<Float>], lfe: Int? = nil) -> Int {
        let out = held
        handOn(out, available: held, into: planes, lfe: lfe)
        return out
    }

    /// Forget everything (a seek or restart: the next audio has nothing to do with the last), the
    /// held frames included.
    mutating func reset() {
        held = 0
        frame = 0
        shared = Release(limit: releaseLimit)
        lfeGuard = Release(limit: releaseLimit)
    }

    /// Frames reduced and the deepest reduction in dB since the last call, then starts counting again.
    mutating func takeLimitedFrames() -> (frames: Int, deepestDB: Float) {
        defer { limitedFrames = 0; deepestGain = 1 }
        return (limitedFrames, 20 * log10(deepestGain))
    }

    // MARK: -

    /// Reductions still coming back, in log2 units, each worked out from its own depth and age
    /// rather than stepped down frame by frame, so a reduction ends exactly `limit` frames after
    /// it began in every run. The shallow ones all come back at the same rate, so a later one at
    /// least as deep makes an earlier one irrelevant for good and the earliest left is the deepest;
    /// the deep ones each come back over `limit` from their own depth, and a later one at least as
    /// deep likewise ends an earlier one.
    private struct Release {
        let limit: Int
        var shallow: [(frame: Int64, depth: Float)] = []
        var deep: [(frame: Int64, depth: Float)] = []

        init(limit: Int) { self.limit = limit }

        /// Take frame `t`'s own need and return the reduction released onto `t`.
        mutating func advance(to t: Int64, need: Float, step: Float, deepFrom: Float) -> Float {
            func shallowDepth(_ e: (frame: Int64, depth: Float)) -> Float {
                max(e.depth - step * Float(t - e.frame), 0)
            }
            func deepDepth(_ e: (frame: Int64, depth: Float)) -> Float {
                e.depth * (1 - Float(t - e.frame) / Float(limit))
            }
            if need > deepFrom {
                while let last = deep.last, deepDepth(last) <= need { deep.removeLast() }
                deep.append((t, need))
            } else if need > 0 {
                while let last = shallow.last, shallowDepth(last) <= need { shallow.removeLast() }
                shallow.append((t, need))
            }
            while let first = shallow.first, t - first.frame >= Int64(limit) || shallowDepth(first) == 0 {
                shallow.removeFirst()
            }
            while let first = deep.first, t - first.frame >= Int64(limit) { deep.removeFirst() }
            var depth = shallow.first.map(shallowDepth) ?? 0
            for event in deep { depth = max(depth, deepDepth(event)) }
            return depth
        }
    }

    private mutating func append(_ planes: [UnsafeMutablePointer<Float>], frameCount: Int, lfe: Int?) {
        let total = held + frameCount
        for c in 0..<channels {
            if work[c].count < total { work[c].append(contentsOf: repeatElement(0, count: total - work[c].count)) }
            work[c].withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: held).update(from: planes[c], count: frameCount) }
        }
        if need.count < total {
            need.append(contentsOf: repeatElement(0, count: total - need.count))
            lfeNeed.append(contentsOf: repeatElement(0, count: total - lfeNeed.count))
        }
        let threshold = Self.threshold, lfeThreshold = Self.lfeThreshold
        for i in held..<total {
            var peak: Float = 0
            for c in 0..<channels where c != lfe { peak = max(peak, abs(work[c][i])) }
            need[i] = peak > threshold ? log2(peak / threshold) : 0
            if let lfe {
                let level = abs(work[lfe][i])
                lfeNeed[i] = level > lfeThreshold ? log2(level / lfeThreshold) : 0
            }
        }
    }

    /// The first `count` frames of `work` out through their gains into the front of `planes`, the
    /// look-ahead reading frames up to `available`; whatever is left becomes the held frames.
    private mutating func handOn(_ count: Int, available: Int, into planes: [UnsafeMutablePointer<Float>], lfe: Int?) {
        let attack = Self.attackFrames
        for i in 0..<count {
            let t = frame + Int64(i)
            var depth = shared.advance(to: t, need: need[i], step: releaseStep, deepFrom: deepFrom)
            var lfeDepth = lfe == nil ? 0 : lfeGuard.advance(to: t, need: lfeNeed[i], step: releaseStep, deepFrom: deepFrom)
            let reach = min(attack, available - 1 - i)
            if reach > 0 {
                for k in 1...reach {
                    let weight = 1 - Float(k) / Float(attack + 1)
                    depth = max(depth, need[i + k] * weight)
                    if lfe != nil { lfeDepth = max(lfeDepth, lfeNeed[i + k] * weight) }
                }
            }
            let gain: Float = depth > 0 ? exp2(-depth) : 1
            let lfeGain: Float = lfeDepth > depth ? exp2(-lfeDepth) : gain
            for c in 0..<channels {
                let g = c == lfe ? lfeGain : gain
                planes[c][i] = g == 1 ? work[c][i] : work[c][i] * g
            }
            if gain < 1 || lfeGain < 1 {
                limitedFrames += 1
                deepestGain = min(deepestGain, gain, lfeGain)
            }
        }
        frame += Int64(count)
        let rest = available - count
        if rest > 0, count > 0 {
            for c in 0..<channels {
                work[c].withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: $0.baseAddress! + count, count: rest) }
            }
            need.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: $0.baseAddress! + count, count: rest) }
            lfeNeed.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: $0.baseAddress! + count, count: rest) }
        }
        held = rest
    }
}
