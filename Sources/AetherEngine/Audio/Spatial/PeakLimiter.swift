import Foundation

/// Keeps the rendered bed under full scale before it reaches the APAC encoder (#731).
///
/// The encoder does not clip: measured on macOS 27, a 1 kHz tone at amplitude 2.0 or 4.0 decodes
/// back at 2.000 / 4.001, so anything over 1.0 travels on and clips wherever the chain first meets
/// fixed point. A rendered Atmos bed can get there: OAMD gains reach +15 dB, and up to sixteen
/// elements sum into one speaker.
///
/// One gain for all channels, so the limiter never moves an object. Attack is instant, which is
/// what keeps every sample under the threshold without a lookahead delay; a lookahead would shift
/// the audio against the video. Release is exponential, so the gain recovers without pumping. On a
/// bed that stays under the threshold the limiter does nothing at all.
///
/// The LFE is not listened to. It is the source's own channel at its own gain, and lossless LFE
/// routinely peaks at 0 dBFS (the Dolby demo disc's LFE check does), which at the shared threshold
/// would duck every channel for a peak that was never over full scale. The shared gain still
/// applies to the LFE when the other channels trip it, so the LFE keeps its balance with them.
/// Only an element gain above 0 dB can take the LFE over full scale; a guard of its own holds it
/// there, at 0 dBFS (the codec's overshoot is a high-frequency effect, and the LFE has none).
struct PeakLimiter {

    /// −0.18 dBFS, a margin for the codec's own overshoot (+0.4 dB measured on an 8 kHz tone).
    static let threshold: Float = 0.98
    /// Where the LFE's own guard starts: full scale.
    static let lfeThreshold: Float = 1
    static let releaseSeconds: Double = 0.25

    private let releaseCoefficient: Float
    /// The peak the current gain is holding down, decaying towards the threshold.
    private var envelope: Float = 0
    /// The same for the LFE guard.
    private var lfeEnvelope: Float = 0
    /// Frames the limiter has reduced since the last `takeLimitedFrames`.
    private var limitedFrames = 0
    /// Deepest reduction since the last `takeLimitedFrames`, as a linear gain.
    private var deepestGain: Float = 1

    init(sampleRate: Int) {
        releaseCoefficient = Float(exp(-1 / (Self.releaseSeconds * Double(sampleRate))))
    }

    /// Limit `frameCount` frames of every plane in place. `lfe` is the LFE's plane, which the
    /// shared gain follows but does not listen to.
    mutating func process(_ planes: [UnsafeMutablePointer<Float>], frameCount: Int, lfe: Int? = nil) {
        guard !planes.isEmpty, frameCount > 0 else { return }
        let lfePlane = lfe.flatMap { planes.indices.contains($0) ? planes[$0] : nil }
        for i in 0..<frameCount {
            var peak: Float = 0
            for (c, plane) in planes.enumerated() where c != lfe { peak = max(peak, abs(plane[i])) }
            envelope = max(peak, envelope * releaseCoefficient)
            if envelope > Self.threshold {
                let gain = Self.threshold / envelope
                for plane in planes { plane[i] *= gain }
                limitedFrames += 1
                deepestGain = min(deepestGain, gain)
            }
            if let lfePlane {
                lfeEnvelope = max(abs(lfePlane[i]), lfeEnvelope * releaseCoefficient)
                if lfeEnvelope > Self.lfeThreshold {
                    let gain = Self.lfeThreshold / lfeEnvelope
                    lfePlane[i] *= gain
                    limitedFrames += 1
                    deepestGain = min(deepestGain, gain)
                }
            }
        }
    }

    /// Forget the envelopes (a seek or restart: the next audio has nothing to do with the last).
    mutating func reset() {
        envelope = 0
        lfeEnvelope = 0
    }

    /// Frames reduced and the deepest reduction in dB since the last call, then starts counting again.
    mutating func takeLimitedFrames() -> (frames: Int, deepestDB: Float) {
        defer { limitedFrames = 0; deepestGain = 1 }
        return (limitedFrames, 20 * log10(deepestGain))
    }
}
