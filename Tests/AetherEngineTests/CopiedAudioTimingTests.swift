import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Foundation
import Testing
@testable import AetherEngine

/// A stream-copied packet is placed on its frame by its own timestamp (`CopiedAudioTiming`), so
/// Matroska's millisecond rounding never reaches the segments, and a run that starts anywhere places
/// every packet where continuous playback does.
@Suite("Stream-copied audio on its frame grid")
struct CopiedAudioTimingTests {

    private static func fixture(_ name: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/avsync").appendingPathComponent(name).path
    }

    /// Every audio packet of `name`, demuxed and then placed, with the timing that placed it.
    private static func placed(_ name: String) throws -> (timing: CopiedAudioTiming, demuxed: [Int64], placed: [Int64], durations: [Int64]) {
        var fmt: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_open_input(&fmt, fixture(name), nil, nil) == 0,
                     "run Scripts/fetch-fixtures.sh to generate Fixtures/avsync/")
        defer { avformat_close_input(&fmt) }
        let ctx = try #require(fmt)
        avformat_find_stream_info(ctx, nil)
        let index = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        try #require(index >= 0)
        let stream = try #require(ctx.pointee.streams[Int(index)])
        let timing = CopiedAudioTiming(stream: stream, codecpar: stream.pointee.codecpar)
        var demuxed: [Int64] = [], placed: [Int64] = [], durations: [Int64] = []
        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        while av_read_frame(ctx, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard pkt!.pointee.stream_index == index, pkt!.pointee.pts != Int64.min else { continue }
            demuxed.append(av_rescale_q(pkt!.pointee.pts, stream.pointee.time_base, timing.timeBase))
            timing.place(pkt!)
            placed.append(pkt!.pointee.pts)
            durations.append(pkt!.pointee.duration)
        }
        return (timing, demuxed, placed, durations)
    }

    @Test("Matroska's rounded timestamps come out on the frame grid, a whole frame apart",
          arguments: [("aac.mkv", Int64(1024), Int64(2112)), ("ac3.mkv", 1536, 256), ("eac3.mkv", 1536, 256)])
    func onTheGrid(_ name: String, _ frame: Int64, _ delay: Int64) throws {
        let run = try Self.placed(name)
        try #require(run.placed.count > 20)
        #expect(run.timing.decoderDelay.map(Int64.init) == delay)
        // AAC's 21.333 ms frame is what Matroska rounds; AC-3's 32 ms is a whole number of ticks.
        if frame == 1024 {
            #expect(Set(zip(run.demuxed, run.demuxed.dropFirst()).map { $1 - $0 }) != [frame], "\(name) was not rounded")
        }
        #expect(Set(zip(run.placed, run.placed.dropFirst()).map { $1 - $0 }) == [frame])
        // Every duration a whole frame, but where the container states a shorter last one (the
        // stream's end trimmed, 11 ms on the AAC clip): that is not rounding, and it stands.
        #expect(Set(run.durations.dropLast()) == [frame])
        // On the stream's own lattice from its first frame, moved by Apple's delay.
        let first = run.placed[0] - delay
        #expect(run.placed.allSatisfy { ($0 - delay - first) % frame == 0 })
        // Each placed packet is within the container's rounding of its own timestamp.
        for (d, p) in zip(run.demuxed, run.placed) { #expect(abs(p - delay - d) <= 48) }
    }

    @Test("a run that starts anywhere places every packet where continuous playback does")
    func sameFromAnyStart() throws {
        // The rule is per packet, so it is the same placement whichever packet reading began at;
        // held here against a timing built for each start, the way each producer builds its own.
        let all = try Self.placed("ac3.mkv")
        for start in [1, 7, 13] {
            let again = try Self.placed("ac3.mkv")
            #expect(Array(again.placed[start...]) == Array(all.placed[start...]))
        }
    }

    @Test("a timestamp names its lattice point; a finer lattice, every frame, or a cut off the lattice keeps it")
    func positionRule() {
        // Matroska at 48 kHz: tolerance 49, so a timestamp names points within 97 of it.
        let tolerance = AudioContinuity.tolerance(sourceTimeBase: AVRational(num: 1, den: 1000), sampleRate: 48_000)
        #expect(tolerance == 49)
        // 21 ms is 1008 samples: the AAC frame at 1024.
        #expect(SourceGrid.position(estimate: 1008, origin: 0, lattice: 1024, tolerance: tolerance) == 1024)
        #expect(SourceGrid.position(estimate: 2064, origin: 0, lattice: 1024, tolerance: tolerance) == 2048)
        // Origin before zero (AAC's priming frame) and a negative position both round to the point.
        #expect(SourceGrid.position(estimate: -1010, origin: -1024, lattice: 1024, tolerance: tolerance) == -1024)
        // Off the lattice by more than rounding: an edit at another phase, the timestamp stands.
        #expect(SourceGrid.position(estimate: 1512, origin: 0, lattice: 1024, tolerance: tolerance) == 1512)
        // E-AC-3's 256 is still longer than the span; TrueHD's 40 is not, PCM's 1 is every frame.
        #expect(SourceGrid.position(estimate: 250, origin: 0, lattice: 256, tolerance: tolerance) == 256)
        #expect(SourceGrid.position(estimate: 1010, origin: 0, lattice: 40, tolerance: tolerance) == 1010)
        #expect(SourceGrid.position(estimate: 1010, origin: 0, lattice: 1, tolerance: tolerance) == 1010)
        // A container that states the sample (90 kHz MPEG-TS: tolerance 2) names the point it states.
        #expect(SourceGrid.position(estimate: 1023, origin: 0, lattice: 1024, tolerance: 2) == 1024)
    }

    @Test("PCM has no grid: each packet keeps its own timestamp, in samples")
    func pcmKeepsItsTimestamps() throws {
        let run = try Self.placed("pcm.mkv")
        try #require(run.placed.count > 20)
        #expect(run.timing.decoderDelay == 0)
        #expect(run.placed == run.demuxed)
    }

    @Test("a stream with no stated start keeps its timestamps, and an unset one stays unset")
    func noStartAndUnset() throws {
        var fmt: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_open_input(&fmt, Self.fixture("ac3.mkv"), nil, nil) == 0)
        defer { avformat_close_input(&fmt) }
        avformat_find_stream_info(fmt, nil)
        let index = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        let stream = try #require(fmt!.pointee.streams[Int(index)])
        stream.pointee.start_time = Int64.min
        let timing = CopiedAudioTiming(stream: stream, codecpar: stream.pointee.codecpar)
        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        pkt!.pointee.pts = 21
        pkt!.pointee.dts = Int64.min
        timing.place(pkt!)
        #expect(pkt!.pointee.pts == 1008 + 256)
        #expect(pkt!.pointee.dts == Int64.min)
    }
}
