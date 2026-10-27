import Testing
import Foundation
@testable import AetherEngine

/// `mediaChapters` must sit on the same clock `seek(to:)` and `currentTime` use. Container chapter
/// starts are absolute container times; the playback clock runs from the container start (the origin),
/// so a chapter's published start is its container start minus that origin.
@Suite("Container chapters on the seek axis")
struct ContainerChapterSeekAxisTests {

    private func raw(_ start: Double, _ end: Double, _ title: String? = nil)
        -> Demuxer.RawContainerChapter {
        Demuxer.RawContainerChapter(start: start, end: end, title: title)
    }

    private func source(_ chapters: [Demuxer.RawContainerChapter], formatStart: Double = 0,
                        sourceStartOrigin: Double? = nil) -> Demuxer.ContainerChapterSource {
        Demuxer.ContainerChapterSource(chapters: chapters, containerDuration: 300 - formatStart,
                                       formatStartSeconds: formatStart,
                                       sourceStartOrigin: sourceStartOrigin ?? formatStart)
    }

    @Test("A container that starts at 5 s publishes its chapters from the content start")
    func offsetContainerIsRebasedOntoOrigin() {
        // A Matroska file whose first cluster starts at 5 s, chapters stated in container time.
        let chapters = Demuxer.chapterInfos(
            source([raw(5, 9, "Alpha"), raw(9, 13, "Bravo"), raw(13, 17, "Charlie"), raw(17, 21.2, "Delta")],
                   formatStart: 5),
            origin: 5)
        #expect(chapters.map(\.startSeconds) == [0, 4, 8, 12])
        #expect(chapters.map(\.name) == ["Alpha", "Bravo", "Charlie", "Delta"])
        #expect(chapters.map(\.id) == [0, 1, 2, 3])
        #expect(abs(chapters[3].durationSeconds - 4.2) < 1e-9)
    }

    @Test("A zero-start container publishes its chapters unchanged")
    func zeroOriginIsIdentity() {
        let chapters = Demuxer.chapterInfos(
            source([raw(0, 4, "Alpha"), raw(4, 8, "Bravo")]), origin: 0)
        #expect(chapters.map(\.startSeconds) == [0, 4])
        #expect(chapters.map(\.durationSeconds) == [4, 4])
    }

    @Test("A chapter that ends before the content starts is not on the content timeline")
    func chapterBeforeOriginIsDropped() {
        let chapters = Demuxer.chapterInfos(
            source([raw(0, 5, "Pre-roll"), raw(5, 9, "Alpha")], formatStart: 5), origin: 5)
        #expect(chapters.map(\.name) == ["Alpha"])
        #expect(chapters.map(\.startSeconds) == [0])
        #expect(chapters[0].durationSeconds == 4)
    }

    @Test("A chapter that starts before the content but runs into it begins at the content start")
    func chapterStraddlingOriginIsClamped() {
        let chapters = Demuxer.chapterInfos(
            source([raw(3, 8, "Straddle"), raw(8, 12, "Next")], formatStart: 5), origin: 5)
        #expect(chapters.map(\.startSeconds) == [0, 3])
        #expect(chapters[0].durationSeconds == 3)
    }

    @Test("A chapter whose declared end equals its start is judged by where it really ends")
    func degenerateDeclaredEndIsNotDropped() {
        // MKVs often write end == start. Container start 5 s; chapter 1 at (0,0) runs to chapter 2 at 10 s,
        // so it spans the origin and stays, with its start at the content start and 5 s to run.
        let chapters = Demuxer.chapterInfos(source([raw(0, 0), raw(10, 10)], formatStart: 5), origin: 5)
        #expect(chapters.map(\.startSeconds) == [0, 5])
        #expect(chapters[0].durationSeconds == 5)
    }

    @Test("A sub-second container start does not drop a degenerate first chapter")
    func smallOriginKeepsDegenerateFirstChapter() {
        let chapters = Demuxer.chapterInfos(
            source([raw(0, 0), raw(300, 300)], formatStart: 0.042), origin: 0.042)
        #expect(chapters.count == 2)
        #expect(chapters[0].startSeconds == 0)
        #expect(abs(chapters[1].startSeconds - 299.958) < 1e-9)
    }

    @Test("A degenerate chapter that really ends before the origin is dropped")
    func degenerateChapterWhollyBeforeOriginIsDropped() {
        // (0,0) runs to the next start at 3 s, which is before the 5 s origin; (3,3) runs on to 10 s, so it
        // spans the origin and stays.
        let chapters = Demuxer.chapterInfos(
            source([raw(0, 0, "Pre"), raw(3, 3, "Mid"), raw(10, 10, "Main")], formatStart: 5), origin: 5)
        #expect(chapters.map(\.name) == ["Mid", "Main"])
        #expect(chapters.map(\.startSeconds) == [0, 5])
    }

    @Test("A degenerate last chapter runs to the container duration, so it is kept past the origin")
    func degenerateLastChapterUsesContainerDuration() {
        let chapters = Demuxer.chapterInfos(source([raw(6, 6, "Only")], formatStart: 5), origin: 5)
        #expect(chapters.map(\.startSeconds) == [1])
        #expect(chapters[0].durationSeconds == 294)
    }

    @Test("Unsorted input is judged in start order")
    func unsortedInputIsSortedFirst() {
        let chapters = Demuxer.chapterInfos(source([raw(10, 10, "B"), raw(0, 0, "A")], formatStart: 5), origin: 5)
        #expect(chapters.map(\.name) == ["A", "B"])
        #expect(chapters[0].durationSeconds == 5)
    }

    @Test("The software origin is the container start, with the software clock's 2 s tolerance")
    func softwareOriginFollowsClockAnchor() {
        #expect(PresentationAxis.containerChapterOrigin(
            backend: .software, formatStartSeconds: 5, sourceStartOrigin: 5, isLive: false) == 5)
        // A start inside the tolerance is anchored at zero by the software clock (SWClockAnchorPolicy).
        #expect(PresentationAxis.containerChapterOrigin(
            backend: .software, formatStartSeconds: 1.5, sourceStartOrigin: 1.5, isLive: false) == 0)
    }

    @Test("The software origin follows the host's origin (stream start fallback), not the format start")
    func softwareOriginUsesHostOrigin() {
        // The container states no start (format start reads as 0) but the video stream starts at 600 s.
        #expect(PresentationAxis.containerChapterOrigin(
            backend: .software, formatStartSeconds: 0, sourceStartOrigin: 600, isLive: false) == 600)
    }

    @Test("Once the clock has anchored, its own session zero is the origin")
    func softwareOriginPrefersAnchoredZero() {
        // A cold start anchors on the first sample, which can differ from the predicted origin.
        #expect(PresentationAxis.containerChapterOrigin(
            backend: .software, formatStartSeconds: 0, sourceStartOrigin: 0, softwareClockZero: 600.04,
            isLive: false) == 600.04)
        #expect(PresentationAxis.containerChapterOrigin(
            backend: .software, formatStartSeconds: 5, sourceStartOrigin: 5, softwareClockZero: 0,
            isLive: false) == 0)
    }

    @Test("The native origin is the container start")
    func nativeOrigin() {
        #expect(PresentationAxis.containerChapterOrigin(
            backend: .native, formatStartSeconds: 5, isLive: false) == 5)
        #expect(PresentationAxis.containerChapterOrigin(
            backend: .native, formatStartSeconds: 1.5, isLive: false) == 1.5)
    }

    @Test("Live keeps origin zero")
    func liveOriginIsZero() {
        #expect(PresentationAxis.containerChapterOrigin(
            backend: .native, formatStartSeconds: 5, isLive: true) == 0)
    }

    @Test("Backends whose origin is not established publish the raw container times")
    func unestablishedOriginIsRaw() {
        #expect(PresentationAxis.containerChapterOrigin(
            backend: .none, formatStartSeconds: 5, isLive: false) == 0)
        #expect(PresentationAxis.containerChapterOrigin(
            backend: .audio, formatStartSeconds: 5, isLive: false) == 0)
    }
}

/// The engine republishes `mediaChapters` when the backend settles.
@Suite("Container chapters engine wiring")
@MainActor
struct ContainerChapterEngineWiringTests {

    private func makeSource() -> Demuxer.ContainerChapterSource {
        Demuxer.ContainerChapterSource(
            chapters: [Demuxer.RawContainerChapter(start: 5, end: 9, title: "Alpha"),
                       Demuxer.RawContainerChapter(start: 9, end: 13, title: "Bravo")],
            containerDuration: 8, formatStartSeconds: 5, sourceStartOrigin: 5)
    }

    @Test("Nothing is published while no backend is settled, and the backend then picks the axis")
    func republishesWhenBackendSettles() throws {
        let engine = try AetherEngine()
        engine.containerChapterSource = makeSource()
        engine.republishMediaChapters()
        #expect(engine.mediaChapters.isEmpty)

        engine.playbackBackend = .native
        #expect(engine.mediaChapters.map(\.startSeconds) == [0, 4])

        engine.playbackBackend = .audio
        #expect(engine.mediaChapters.map(\.startSeconds) == [5, 9])
    }

    @Test("A source with no chapters publishes none")
    func noSourcePublishesNone() throws {
        let engine = try AetherEngine()
        engine.playbackBackend = .native
        #expect(engine.mediaChapters.isEmpty)
    }
}

/// Opt-in media check of the published axis against the real seek. Each clip is named by an environment
/// variable so no media is committed; a test skips when its variable is unset.
///   AE_CHAPTER_CLIP_OFFSET  a Matroska file whose first cluster starts at 5 s, chapters at 5/9/13/17 s
///   AE_CHAPTER_CLIP_ZERO    a Matroska file that starts at 0, chapters at 0/4/8/12 s
///
/// Both halves check `sourceTime` as well as `currentTime`: the software-decoded half plays on the
/// overlay over the same native session, with `preferredDecodePath = .software`.
@Suite("Container chapter seek lands on the chapter (media)", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct ContainerChapterSeekMediaTests {

    nonisolated private static func clip(_ variable: String) -> URL? {
        ProcessInfo.processInfo.environment[variable].map { URL(fileURLWithPath: $0) }
    }

    /// Polls until `condition` holds or the timeout passes; returns whether it held.
    private func waitUntil(timeout: Duration, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// Seeks to a chapter start and waits for the clock to settle on the expected value of `reading`.
    private func seekAndSettle(_ engine: AetherEngine, to target: Double, expecting expected: Double,
                               reading: (AetherEngine) -> Double) async throws -> Double {
        await engine.seek(to: target)
        _ = try await waitUntil(timeout: .seconds(4)) { abs(reading(engine) - expected) <= 0.1 }
        return reading(engine)
    }

    /// Loads `url` paused and waits for the session to be ready. Native: the item must be ready before
    /// it takes a seek, or the seek is deferred and superseded.
    private func loadReady(_ url: URL, software: Bool) async throws -> AetherEngine {
        let engine = try AetherEngine()
        var options = LoadOptions()
        options.suppressDisplayCriteria = true
        options.preferredDecodePath = software ? .software : .automatic
        options.autoplay = false
        try await engine.load(url: url, options: options)
        let ready = try await waitUntil(timeout: .seconds(20)) { engine.isSessionReady }
        #expect(ready, "software=\(software) session ready")
        return engine
    }

    /// Seeks to every chapter and reads `sourceTime` once, shortly after the seek returns. The window
    /// is tight on purpose: a clock that runs forward would pass a wide one from an early landing, or
    /// from a seek that did nothing.
    private func checkLandings(_ engine: AetherEngine, _ chapters: [ChapterInfo], _ sourceTimes: [Double],
                               phase: String) async throws {
        for (chapter, source) in zip(chapters, sourceTimes) {
            await engine.seek(to: chapter.startSeconds)
            try await Task.sleep(for: .milliseconds(350))
            let landed = engine.sourceTime
            #expect(landed >= source - 0.1 && landed < source + 0.6,
                    "\(phase): chapter \(chapter.id) @ \(chapter.startSeconds) sourceTime \(landed), want [\(source - 0.1), \(source + 0.6))")
        }
    }

    private func checkEveryChapterLands(url: URL, software: Bool, expectedStarts: [Double],
                                        expectedSourceTimes: [Double]) async throws {
        let engine = try await loadReady(url, software: software)
        defer { engine.stop() }
        let route = software ? "overlay" : "native"
        #expect(engine.mediaChapters.map(\.startSeconds) == expectedStarts, "\(route): published chapter starts")
        for (chapter, source) in zip(engine.mediaChapters, expectedSourceTimes) {
            let landed = try await seekAndSettle(engine, to: chapter.startSeconds,
                                                 expecting: chapter.startSeconds) { $0.currentTime }
            #expect(abs(landed - chapter.startSeconds) < 0.1,
                    "\(route) chapter \(chapter.id) @ \(chapter.startSeconds) landed at \(landed)")
            let reached = try await waitUntil(timeout: .seconds(4)) { abs(engine.sourceTime - source) <= 0.1 }
            #expect(reached, "\(route) chapter \(chapter.id) sourceTime \(engine.sourceTime), want \(source)")
        }
    }

    @Test("Chapter starts on a 5 s container start land on the chapter, software-decoded and native",
          .enabled(if: ContainerChapterSeekMediaTests.clip("AE_CHAPTER_CLIP_OFFSET") != nil))
    func offsetContainerChaptersLand() async throws {
        let url = try #require(Self.clip("AE_CHAPTER_CLIP_OFFSET"))
        try await checkEveryChapterLands(url: url, software: true, expectedStarts: [0, 4, 8, 12],
                                         expectedSourceTimes: [5, 9, 13, 17])
        try await checkEveryChapterLands(url: url, software: false, expectedStarts: [0, 4, 8, 12],
                                         expectedSourceTimes: [5, 9, 13, 17])
    }

    @Test("Chapter starts on a zero-start container land on the chapter, software-decoded and native",
          .enabled(if: ContainerChapterSeekMediaTests.clip("AE_CHAPTER_CLIP_ZERO") != nil))
    func zeroContainerChaptersLand() async throws {
        let url = try #require(Self.clip("AE_CHAPTER_CLIP_ZERO"))
        try await checkEveryChapterLands(url: url, software: true, expectedStarts: [0, 4, 8, 12],
                                         expectedSourceTimes: [0, 4, 8, 12])
        try await checkEveryChapterLands(url: url, software: false, expectedStarts: [0, 4, 8, 12],
                                         expectedSourceTimes: [0, 4, 8, 12])
    }
}
