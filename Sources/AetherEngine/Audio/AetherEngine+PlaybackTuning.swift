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

    /// Whether the software path drives its renderers through the tvOS / macOS 27 synchronizer receivers (default
    /// true): `sampleBufferReceiver(adding:)` to join the clock, then the receiver's enqueue, flush and events, for
    /// the audio renderer, the video renderer and the held still frame. Off, it uses the renderer calls the 27 SDKs
    /// deprecate for Swift, as every system before 27 does. The receivers wrap the same renderers, so this changes
    /// the API, not the media path. A switch for A/B on a device; read when a session's audio output is built, so it
    /// applies from the next session. No effect before 27.
    @_spi(Diagnostics)
    public nonisolated static var usesSampleBufferReceivers: Bool {
        get { AudioOutput.usesSampleBufferReceivers }
        set { AudioOutput.usesSampleBufferReceivers = newValue }
    }
}
