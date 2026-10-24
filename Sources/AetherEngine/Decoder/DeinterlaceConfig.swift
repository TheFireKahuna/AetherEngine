import Foundation

/// Deinterlacer cadence for the software-decode path, resolved from `LoadOptions` at load time and handed to
/// `SoftwareVideoDecoder` before `open`.
struct DeinterlaceConfig: Sendable, Equatable {
    var fieldRate: DeinterlaceFieldRate = .field
    /// Film in interlaced carriage, found by the load probe (docs/software-route-gpu.md 6.4): the pictures go through
    /// ``InverseTelecine`` instead of the deinterlacer. Nil for video.
    var film: FilmCarriage? = nil
}

/// How film sits in interlaced carriage (docs/software-route-gpu.md 6.2 - 6.4).
enum FilmCarriage: String, Sendable, Equatable {
    /// 3:2 hard telecine: field matching, then decimation to 4/5 of the carriage rate.
    case pulldown32
    /// Progressive-segmented film (2:2): field matching alone, at the carriage rate.
    case segmented22
}
