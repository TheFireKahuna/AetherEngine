import Foundation

extension AetherEngine {
    /// What a prerolled start adds to the audio route's output latency before it starts the clock, in
    /// seconds (default 0.112; the lead is capped at 250 ms). For tuning start and seek latency on a
    /// device against the video renderer's dropped-frame count: a smaller margin starts sooner, and too
    /// small a one drops the first frames. Takes effect from the next start and applies to every session
    /// in the process. Negative values are read as 0.
    @_spi(Diagnostics)
    public nonisolated static var prerollStartMargin: Double {
        get { AudioOutput.prerollStartMargin }
        set { AudioOutput.prerollStartMargin = newValue }
    }
}
