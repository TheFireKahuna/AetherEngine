import Foundation

/// Snap a raw frame rate from the demuxer (libavformat
/// `avg_frame_rate` / `r_frame_rate`) to the nearest standard rate
/// supported by tvOS' Match Frame Rate. Real-world sources rarely
/// probe at exact rates (a 23.976 fps film commonly probes at
/// 23.97-23.98 depending on container rounding), so a tolerance
/// is necessary.
///
/// Returns `nil` for zero or out-of-range rates; the display criteria
/// then ask for `DisplayCriteriaController.unknownFrameRateFallback`
/// (23.976, the film rate this snaps to).
enum FrameRateSnap {
    /// Standard rates Apple TV's HDMI handshake will switch to.
    /// Source: AVDisplayManager documentation + empirical testing on
    /// LG / Sony / Philips panels. Anything outside this set is either
    /// VFR / weird capture rates or a probe failure.
    static let standard: [Double] = [23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60]

    /// How close to 24.000 a probe must be to count as a stated 24/1
    /// rather than film NTSC. 24000/1001 is 0.024 away; a rational 24/1
    /// is exact, and a Matroska DefaultDuration of 41666667 ns is 2e-7 off.
    static let exactTwentyFourTolerance: Double = 0.001

    /// Snap `raw` to the nearest member of `standard` within ±0.5 fps,
    /// or `nil` if it falls outside that tolerance from every standard
    /// rate. Special case: 23.976 wins the [23.5, 24.05] window over
    /// 24.0 because film-cadence sources commonly probe to 23.976 and
    /// 23.976 ↔ 24 matters for 3:2 pulldown / judder visibility. Only a
    /// rate within `exactTwentyFourTolerance` of 24 (a stream stating
    /// 24/1) gets 24.0. 29.97/30 and 59.94/60 need no such rule: nearest
    /// match already keeps 30000/1001 and 30/1 (60000/1001, 60/1) apart.
    static func snap(_ raw: Double) -> Double? {
        guard raw > 0, raw.isFinite else { return nil }

        // Film-cadence shortcut. Anything short of an exact 24 is sent
        // as 23.976, the conservative choice for a noisy probe (panels
        // that support 24 also support 23.976; the reverse isn't
        // guaranteed). A stated 24/1 played at 23.976 Hz would repeat
        // a frame every ~41.7 s.
        if raw >= 23.5 && raw <= 24.05 {
            return abs(raw - 24) < exactTwentyFourTolerance ? 24 : 23.976
        }

        var best: (rate: Double, delta: Double)?
        for candidate in standard where candidate != 23.976 {
            let delta = abs(candidate - raw)
            if delta <= 0.5 {
                if let current = best {
                    if delta < current.delta { best = (candidate, delta) }
                } else {
                    best = (candidate, delta)
                }
            }
        }
        return best?.rate
    }
}
