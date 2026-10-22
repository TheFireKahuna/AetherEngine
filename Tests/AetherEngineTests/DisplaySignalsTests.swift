import Foundation
import AVFoundation
import Testing
@testable import AetherEngine

@Suite("Display signals probe")
struct DisplaySignalsTests {

    @Test("a line splits back into its pairs: values with spaces, = or quotes are quoted")
    func lineQuoting() {
        let line = DisplaySignals.line("#3 snapshot", [("trigger", "load"), ("route", "HDMI LG TV"), ("expr", "a=b"),
                                                       ("q", "say \"hi\""), ("empty", "")])
        #expect(line == "[DisplaySignals] #3 snapshot trigger=load route=\"HDMI LG TV\" expr=\"a=b\" q=\"say 'hi'\" empty=\"\"")
    }

    @Test("a description is flattened to one line and cut")
    func brief() {
        #expect(DisplaySignals.brief("a\n  b   c") == "a b c")
        #expect(DisplaySignals.brief(String(repeating: "x", count: 10), limit: 4) == "xxxx…")
        #expect(DisplaySignals.brief(nil) == "nil")
    }

    @Test("cadence is the median interval, so a dropped tick does not move it")
    func cadence() throws {
        var stamps = (0..<30).map { Double($0) / 23.976 }
        stamps.remove(at: 12)
        let cadence = try #require(DisplaySignals.cadence(timestamps: stamps))
        #expect(abs(cadence.hz - 23.976) < 0.001)
        #expect(cadence.jitterMs < 0.01)
        #expect(DisplaySignals.cadence(timestamps: [0, 1]) == nil)
    }

    @Test("the master offers the ladder in order, each variant differing only in codec and range")
    func master() {
        let text = DisplaySignals.masterPlaylist(DisplaySignals.Ladder.all[1])
        let infs = text.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-STREAM-INF") }
        #expect(infs.count == 2)
        #expect(infs[0].contains("CODECS=\"dvh1.05.06\"") && infs[0].contains("VIDEO-RANGE=PQ"))
        #expect(infs[1].contains("CODECS=\"hvc1.1.6.L153.B0\"") && infs[1].contains("VIDEO-RANGE=SDR"))
        #expect(text.hasSuffix("dv5.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=20000000,AVERAGE-BANDWIDTH=15000000,CODECS=\"hvc1.1.6.L153.B0\",RESOLUTION=3840x2160,FRAME-RATE=23.976,VIDEO-RANGE=SDR\nsdr.m3u8\n"))
    }

    @Test("request paths classify")
    func requested() {
        #expect(DisplaySignals.requested(path: "/abc/master.m3u8") == .master)
        #expect(DisplaySignals.requested(path: "/abc/hlg.m3u8") == .mediaPlaylist(.hlg))
        #expect(DisplaySignals.requested(path: "/abc/dv5-init.mp4") == .media("dv5-init.mp4"))
        #expect(DisplaySignals.requested(path: "/abc/x.key") == .unknown("x.key"))
    }

    @Test("verdicts: picked, passed over, or nothing to read")
    func verdicts() {
        let dv = DisplaySignals.Ladder.all[1], alone = DisplaySignals.Ladder.all[4], control = DisplaySignals.Ladder.all[0]
        #expect(DisplaySignals.verdict(dv, firstPick: .dolbyVision5, failed: false) == .picked)
        #expect(DisplaySignals.verdict(dv, firstPick: .sdr, failed: false) == .passedOver)
        #expect(DisplaySignals.verdict(alone, firstPick: nil, failed: true) == .passedOver)
        #expect(DisplaySignals.verdict(alone, firstPick: nil, failed: false) == .unknown)
        #expect(DisplaySignals.verdict(control, firstPick: .sdr, failed: false) == .unknown)
        #expect(DisplaySignals.startRule(controlPick: .sdr) == "order")
        #expect(DisplaySignals.startRule(controlPick: .hdr10) == "ranking")
        #expect(DisplaySignals.startRule(controlPick: nil) == nil)
    }

    /// A session starting cancels the oracle; the run must end then, not spin out its timeout on the main actor.
    @Test("a cancelled run returns at once")
    @MainActor
    func cancelledRunEnds() async {
        let clock = ContinuousClock()
        let started = clock.now
        let run = Task { @MainActor in
            await VariantOracle.run(DisplaySignals.Ladder.all[1], attachment: "none", timeout: .seconds(30))
        }
        run.cancel()
        let result = await run.value
        #expect(clock.now - started < .seconds(2))
        #expect(!result.timedOut)
    }

    /// The plumbing on this machine's AVFoundation: the custom-scheme master is taken and a variant is started on.
    /// Which one is this display's business, so only that a pick happens is asserted; the result is printed.
    @Test("the oracle gets a variant pick out of AVFoundation through the resource loader")
    @MainActor
    func liveRun() async {
        var lines: [String] = []
        for ladder in DisplaySignals.Ladder.all {
            let result = await VariantOracle.run(ladder, attachment: "none")
            lines.append("\(ladder.name): requests=\(result.requests) pick=\(result.firstPick?.rawValue ?? "-") "
                         + "status=\(result.status) error=\(result.errorDomain ?? "-")/\(result.errorCode ?? 0) "
                         + "ms=\(result.elapsedMs) timedOut=\(result.timedOut)")
            #expect(result.requests.first == "master.m3u8", "\(ladder.name)")
        }
        print(lines.joined(separator: "\n"))
        #expect(lines.count == DisplaySignals.Ladder.all.count)
    }
}
