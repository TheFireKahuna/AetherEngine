/// The stretch of the timeline one stage of an audio path takes its output from: output at timeline
/// position `p` is a function of the input in `p - memory ..< p + latency`, and of nothing else.
/// Frames, at the rate of the path's output.
///
/// The two numbers answer different questions. `latency` is how far ahead of `p` the stage has to
/// have read before it can hand `p` on: what it holds back, and what the timeline compensates, the
/// way an Audio Unit states it in `kAudioUnitProperty_Latency`. `memory` is how far behind `p` its
/// output still reaches: a run that starts at least that far back gives the output continuous
/// playback gives, whatever came before, so a seek reads that much earlier (the restart's pre-roll)
/// and the segment it produces is the one continuous playback produced.
///
/// For a decoder, `memory` counts from where a read begins: it covers the wait for the first point the
/// bitstream can be decoded from (a TrueHD major sync) as well as the history the decode is coded
/// against.
struct AudioStageSpan: Equatable, Sendable {
    var latency: Int
    var memory: Int

    /// A stage that touches each frame on its own.
    static let instant = AudioStageSpan(latency: 0, memory: 0)

    /// This stage followed by `next`. Its input reaches back and ahead by both.
    func then(_ next: AudioStageSpan) -> AudioStageSpan {
        AudioStageSpan(latency: latency + next.latency, memory: memory + next.memory)
    }

    /// Stages in series, first to last.
    static func series(_ stages: [AudioStageSpan]) -> AudioStageSpan {
        stages.reduce(.instant) { $0.then($1) }
    }
}
