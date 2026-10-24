import Foundation
import Testing
@testable import AetherEngine

/// Audit FEA-104 / FEA-107 / SUB-106: the live subtitle rendition loop fetched, parsed and merged on
/// the main actor, through a session with a 7-day resource timeout, no status check and no cap, and
/// `WebVTTSegmentParser.merged` compared every cue against everything published (40k cues took 3.9 s)
/// while `inf` and `nan` timestamps were accepted and a `+inf` end was never pruned.
struct LiveSubtitleRenditionHardeningTests {

    private func cue(_ id: Int, _ text: String, _ start: Double, _ end: Double) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text(text))
    }

    /// The fold `merged` was before the per-text index, kept as the oracle.
    private func legacyMerged(into existing: [SubtitleCue], adding: [SubtitleCue]) -> [SubtitleCue] {
        var result = existing
        for cue in adding {
            guard case .text(let text) = cue.body else { continue }
            let match = result.firstIndex { candidate in
                guard case .text(let candidateText) = candidate.body, candidateText == text else { return false }
                return cue.startTime <= candidate.endTime + 0.25
                    && cue.endTime >= candidate.startTime - 0.25
            }
            if let match {
                let old = result[match]
                result[match] = SubtitleCue(id: old.id,
                                            startTime: min(old.startTime, cue.startTime),
                                            endTime: max(old.endTime, cue.endTime),
                                            body: old.body,
                                            placement: old.placement)
            } else {
                result.append(cue)
            }
        }
        return result
    }

    private struct Snapshot: Equatable {
        let id: Int
        let start: Double
        let end: Double
        let text: String?

        init(_ cue: SubtitleCue) {
            id = cue.id
            start = cue.startTime
            end = cue.endTime
            text = cue.text
        }
    }

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - merged

    @Test("the indexed merge gives what the scan gave, on colliding texts and touching ranges")
    func mergeMatchesTheOldScan() {
        var rng = SplitMix64(state: 0x5EED_0106)
        let texts = ["a", "b", "c", "a b", "", "\u{00E9}"]
        for round in 0..<300 {
            func make(_ count: Int, firstID: Int) -> [SubtitleCue] {
                (0..<count).map { offset in
                    let start = Double(Int.random(in: 0...60, using: &rng)) / 2
                    let length = [0.0, 0.25, 0.5, 1, 2.5].randomElement(using: &rng)!
                    return cue(firstID + offset, texts.randomElement(using: &rng)!, start, start + length)
                }
            }
            let existing = make(Int.random(in: 0...12, using: &rng), firstID: 0)
            let adding = make(Int.random(in: 0...12, using: &rng), firstID: 100)
            var nextID = 1000
            let got = WebVTTSegmentParser.merged(into: existing, adding: adding, nextID: &nextID)
            #expect(got.map(Snapshot.init) == legacyMerged(into: existing, adding: adding).map(Snapshot.init), "round \(round)")
        }
    }

    @Test("merging 40k distinct cues is linear")
    func mergeIsLinear() {
        let adding = (0..<40_000).map { cue($0, "line \($0)", Double($0), Double($0) + 0.5) }
        var nextID = 0
        let started = ContinuousClock.now
        let merged = WebVTTSegmentParser.merged(into: [], adding: adding, nextID: &nextID)
        let elapsed = ContinuousClock.now - started
        #expect(merged.count == 40_000)
        #expect(elapsed < .seconds(1), "took \(elapsed)")
    }

    @Test("re-feeding a merged segment changes nothing")
    func refeedingIsIdempotent() {
        let adding = (0..<500).map { cue($0, "line \($0 % 50)", Double($0), Double($0) + 0.5) }
        var nextID = 0
        let once = WebVTTSegmentParser.merged(into: [], adding: adding, nextID: &nextID)
        let twice = WebVTTSegmentParser.merged(into: once, adding: adding, nextID: &nextID)
        #expect(twice.map(Snapshot.init) == once.map(Snapshot.init))
    }

    // MARK: - parse

    private func segment(_ cues: String) -> String {
        "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0\n\n\(cues)"
    }

    @Test("a cue with a non-finite or negative timestamp is dropped and the others stay")
    func nonFiniteTimestampsAreDropped() throws {
        let text = segment("""
        00:00:01.000 --> 00:00:02.000
        good

        00:00:inf --> 00:00:03.000
        start infinity

        00:00:01.000 --> 00:00:inf
        end infinity

        00:00:nan --> 00:00:03.000
        start nan

        00:00:01.000 --> 00:00:nan
        end nan

        00:00:01.000 --> 00:00:1e999
        end overflow

        -00:00:05.000 --> 00:00:03.000
        negative

        00:00:04.000 --> 00:00:05.000
        also good
        """)
        let parsed = try #require(WebVTTSegmentParser.parse(text))
        #expect(parsed.cues.map(\.text) == ["good", "also good"])
        #expect(parsed.cues.allSatisfy { $0.start.isFinite && $0.end.isFinite })
    }

    @Test("ordinary timestamps still parse, with a comma as the decimal mark too")
    func ordinaryTimestampsStillParse() throws {
        let parsed = try #require(WebVTTSegmentParser.parse(segment("""
        164:04:24.000 --> 164:04:25.440
        long clock

        01:02,500 --> 01:03.000
        short form
        """)))
        #expect(parsed.cues.count == 2)
        // Typed apart: Swift 6.2 cannot type-check the literal sum inside the macro in time.
        let longClock: Double = 164 * 3600 + 4 * 60 + 24
        let longClockError: Double = abs(parsed.cues[0].start - longClock)
        let shortFormError: Double = abs(parsed.cues[1].start - 62.5)
        #expect(longClockError < 0.001)
        #expect(shortFormError < 0.001)
    }

    @Test("a segment holds at most 4096 cues")
    func cuesPerSegmentAreCapped() throws {
        var body = ""
        for index in 0..<10_000 { body += "00:00:\(String(format: "%02d", index % 60)).000 --> 00:59:00.000\ncue \(index)\n\n" }
        let parsed = try #require(WebVTTSegmentParser.parse(segment(body)))
        #expect(parsed.cues.count == WebVTTSegmentParser.maxCuesPerSegment)
        #expect(parsed.cues.first?.text == "cue 0")
    }

    // MARK: - the fetch, off the main actor

    private func media(_ origin: CannedHTTPOrigin, _ path: String) -> URL {
        URL(string: origin.baseURL + path)!
    }

    @Test("a rendition playlist is fetched and parsed from a detached task")
    func playlistFetchRunsOffTheMainActor() async throws {
        let origin = try #require(CannedHTTPOrigin())
        defer { origin.stop() }
        origin.route("/subs.m3u8", .body("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-PROGRAM-DATE-TIME:2026-09-30T10:00:00.000Z
        #EXTINF:6.0,
        seg0.vtt
        """, contentType: "application/vnd.apple.mpegurl"))
        let url = media(origin, "/subs.m3u8")
        let playlist = try await Task.detached {
            try await AetherEngine.fetchLiveSubtitleRenditionPlaylist(url, headers: [:])
        }.value
        #expect(playlist?.segments.map(\.uri) == ["seg0.vtt"])
        #expect(playlist?.segments.first?.programDateTime != nil)
    }

    @Test("a master where a media playlist belongs is reported as none, an error status throws")
    func playlistFetchRefusals() async throws {
        let origin = try #require(CannedHTTPOrigin())
        defer { origin.stop() }
        origin.route("/master.m3u8", .body("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000
        v.m3u8
        """, contentType: "application/vnd.apple.mpegurl"))
        origin.route("/gone.m3u8", .status(404))
        let master = media(origin, "/master.m3u8")
        let gone = media(origin, "/gone.m3u8")
        let asMaster = try await Task.detached {
            try await AetherEngine.fetchLiveSubtitleRenditionPlaylist(master, headers: [:])
        }.value
        #expect(asMaster == nil)
        await #expect(throws: HLSIngestError.playlistUnreachable(status: 404)) {
            _ = try await Task.detached {
                try await AetherEngine.fetchLiveSubtitleRenditionPlaylist(gone, headers: [:])
            }.value
        }
    }

    @Test("a WebVTT segment is parsed off the main actor, an oversized or failing one is dropped")
    func segmentFetch() async throws {
        let origin = try #require(CannedHTTPOrigin())
        defer { origin.stop() }
        origin.route("/ok.vtt", .body(segment("00:00:01.000 --> 00:00:02.000\nhello"), contentType: "text/vtt"))
        let filler = String(repeating: "x", count: 1_200_000)
        origin.route("/huge.vtt", .body(segment("00:00:01.000 --> 00:00:02.000\n\(filler)"), contentType: "text/vtt"))
        origin.route("/gone.vtt", .status(500))
        let ok = media(origin, "/ok.vtt")
        let huge = media(origin, "/huge.vtt")
        let gone = media(origin, "/gone.vtt")
        let parsed = await Task.detached {
            await AetherEngine.fetchLiveSubtitleRenditionSegment(ok, headers: [:])
        }.value
        #expect(parsed?.cues.map(\.text) == ["hello"])
        let oversized = await Task.detached {
            await AetherEngine.fetchLiveSubtitleRenditionSegment(huge, headers: [:])
        }.value
        #expect(oversized == nil)
        let failing = await Task.detached {
            await AetherEngine.fetchLiveSubtitleRenditionSegment(gone, headers: [:])
        }.value
        #expect(failing == nil)
    }

    @Test("the rendition fetches carry a finite resource timeout")
    func fetchTimeoutsAreFinite() {
        #expect(AetherEngine.liveSubtitleRenditionResourceSeconds <= 60)
        #expect(AetherEngine.liveSubtitleRenditionIdleSeconds <= 30)
    }

    @Test("the published cue list is capped")
    func publishedCuesAreCapped() {
        let cues = (0..<5_000).map { cue($0, "c\($0)", Double($0), Double($0) + 1) }
        let kept = AetherEngine.capLiveSubtitleCues(cues)
        #expect(kept.count == AetherEngine.maxLiveSubtitleCues)
        #expect(kept.last?.id == 4_999)
    }
}
