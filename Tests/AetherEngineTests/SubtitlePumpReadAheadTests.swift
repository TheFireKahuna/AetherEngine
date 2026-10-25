import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// Layer 3 step 5: a subtitle stream the container's index does not list (a transport stream's, a disc's,
/// a Matroska file's without subtitle Cues) reaches the packet store only through the session's own reader
/// of the source, so its consumers' leads move that reader's read-ahead instead of opening a second one.
@Suite("The pump reads ahead for subtitles")
struct SubtitlePumpReadAheadTests {

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    // MARK: - The consumers' leads

    @Test("the read-ahead is the furthest lead of a consumer of a pumped stream, and nil with none")
    func readAheadIsTheFurthestPumpedLead() {
        let leads = SubtitleSource.Leads()
        #expect(leads.readAhead(playhead: 100) == nil)
        #expect(!leads.demandsPumped)
        leads.set(.overlay, { _ in 75 }, streams: [3])
        leads.set(.ocr, { _ in 270 }, streams: [4])
        #expect(leads.readAhead(playhead: 100) == 270)
        // Once the routes settle, a stream the index reads asks nothing of the pump.
        leads.setIndexed([4])
        #expect(leads.readAhead(playhead: 100) == 75)
        leads.setIndexed([3, 4])
        #expect(leads.readAhead(playhead: 100) == nil)
        #expect(!leads.demandsPumped)
        leads.setIndexed([])
        leads.set(.ocr, nil, streams: [])
        #expect(leads.readAhead(playhead: 100) == 75)
        // A lead can depend on the playhead (AVKit's requests stretch a rendition's).
        leads.set(.rendition, { 400 - $0 }, streams: [5])
        #expect(leads.readAhead(playhead: 100) == 300)
        leads.clear()
        #expect(leads.readAhead(playhead: 100) == nil)
    }

    @Test("the overlay asks for a read-ahead only for VOD sessions with embedded drain targets and a source")
    func overlayGating() {
        #expect(AetherEngine.shouldReadOverlaySubtitlesAhead(
            isLive: false, hasEmbeddedDrainTargets: true, hasSource: true))
        #expect(!AetherEngine.shouldReadOverlaySubtitlesAhead(
            isLive: true, hasEmbeddedDrainTargets: true, hasSource: true))
        #expect(!AetherEngine.shouldReadOverlaySubtitlesAhead(
            isLive: false, hasEmbeddedDrainTargets: false, hasSource: true))
        #expect(!AetherEngine.shouldReadOverlaySubtitlesAhead(
            isLive: false, hasEmbeddedDrainTargets: true, hasSource: false))
    }

    // MARK: - The native route's producer

    /// The real producer over a six-second transport stream in one-second plan slots, with a forward
    /// window of one segment and a consumer that never fetches: it parks at once unless a subtitle
    /// consumer asks it to read on.
    @Test("the producer reads on past its forward window to the segment a subtitle consumer asks for",
          .timeLimit(.minutes(1)))
    func producerReadsOnToTheReach() async throws {
        let written = TransportStreamFixture.write([.init(frames: 150)])
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: written.data), formatHint: "mpegts")
        defer { demuxer.close() }
        let index = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: index))
        let cache = SegmentCache(forwardWindow: 1, backwardWindow: 64)
        defer { cache.close() }
        let producer = try HLSSegmentProducer(
            demuxer: demuxer, videoStreamIndex: index,
            video: .init(codecpar: UnsafePointer(stream.pointee.codecpar), timeBase: stream.pointee.time_base,
                         codecTagOverride: "avc1"),
            audio: nil, cache: cache, targetSegmentDurationSeconds: 1, videoFallbackDurationPts: 3600,
            desiredFirstVideoTfdtPts: 0,
            segmentBoundaries: (0..<7).map { 900_000 + Int64($0) * 90_000 },
            planAnchorVideoPts: 900_000, isLive: false, bufferAheadSegments: 1)
        let reach = Box<Int?>(nil)
        let reads = Box<[Double]>([])
        let finished = Box(false)
        producer.subtitleReadAheadReach = { reach.value }
        producer.onSourceReadThrough = { seconds in reads.value.append(seconds) }
        producer.onPumpFinished = { _ in finished.value = true }
        producer.start()
        defer { producer.stop(); _ = producer.waitForFinish(timeout: 2) }

        // Parked at its forward window: the segment past it is not cut.
        try await waitFor { producer.isAdvanceParked }
        let parkedAt = cache.highestStoredIndex
        #expect(parkedAt <= 1)

        // Asked to segment 4, it reads on to it and parks again. Until it notices the reach it is still
        // parked below it, so what is waited for is parked with segment 3 stored; parked, it cuts no more.
        reach.value = 4
        try await waitFor { producer.isAdvanceParked && cache.highestStoredIndex >= 3 }
        #expect(cache.highestStoredIndex < 5)
        let read = reads.value
        #expect(!read.isEmpty)
        #expect(read == read.sorted(), "a pump reads forwards")
        // The reads are on the source axis: the fixture starts at 10 s.
        #expect((read.first ?? 0) >= 10)
        #expect(read.allSatisfy { $0.isFinite })

        // Asked past the end, it reads the rest and says so.
        reach.value = 100
        try await waitFor { finished.value }
        #expect(reads.value.last == .infinity)
    }

    // MARK: - The software route's read-ahead

    @Test("the software read-ahead reads past its forward window as far as a subtitle consumer asks",
          .timeLimit(.minutes(1)))
    func softwareReadAheadHonoursTheLead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sub-readahead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func packetsBeforePark(readAhead: Double?) throws -> Int {
            let counter = Box(0)
            let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64 * 1024, retainConsumed: true,
                                                  parentDirectory: root)
            let source = SoftwarePacketReadAhead(
                video: .init(index: 0, numerator: 1, denominator: 1000), audio: nil,
                byteBudget: 10_000_000, forwardSeconds: 10, initialSourceClock: 0, fifo: fifo,
                readAheadSeconds: { readAhead }
            ) { _ in
                counter.value += 1
                // 25 pictures a second on a 1/1000 time base.
                let pts = Int64(counter.value - 1) * 40
                return SoftwareStoredPacket(pts: pts, dts: pts, duration: 40, position: 0, streamIndex: 0,
                                            flags: 0x1, timeBaseNumerator: 1, timeBaseDenominator: 1000,
                                            bytes: Data(repeating: 7, count: 100), sideData: [])
            }
            source.start()
            defer { source.close() }
            let deadline = Date().addingTimeInterval(10)
            var previous = -1
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.15)
                if counter.value == previous, previous > 0 { break }
                previous = counter.value
            }
            return counter.value
        }
        // 10 s of 25 fps is 250 pictures; 30 s is 750.
        let own = try packetsBeforePark(readAhead: nil)
        let asked = try packetsBeforePark(readAhead: 30)
        #expect(abs(own - 250) <= 5)
        #expect(abs(asked - 750) <= 5)
    }

    // MARK: - What the store knows was read

    @Test("a reading that reached the end of the source covers everything from its anchor on")
    func endOfSourceCoversTheRest() {
        let store = SubtitlePacketStore()
        store.noteHarvestAnchor(at: 10)
        store.noteHarvestProgress(through: 20)
        #expect(store.harvestReach(from: 12) == 20)
        store.noteHarvestEnd()
        #expect(store.harvestReach(from: 12) == .infinity)
        #expect(store.hasReadSpan(from: 10, through: 10_000))
        #expect(store.harvestReach(from: 5) == nil)
        // A new anchor ends that run: the reading after it is a fresh one.
        store.noteHarvestAnchor(at: 50)
        #expect(store.harvestReach(from: 50) == .infinity)
    }

    @Test("a cue store read to the end of the source answers every window past its start")
    func cueStoreReadToTheEnd() {
        let store = NativeSubtitleCueStore()
        store.noteRead(from: 10, through: .infinity)
        #expect(store.readThrough(at: 500) == .infinity)
        #expect(store.readThrough(at: 5) == 0)
    }

    @Test("a split display set assembles across its chunks into one packet")
    func splitDisplaySetAssembles() {
        let store = SubtitlePacketStore()
        let pcs: [UInt8] = [0x16, 0x00, 0x04, 0xAA, 0xAA, 0xAA, 0xAA]
        let ods: [UInt8] = [0x15, 0x00, 0x02, 0x0A, 0x0A]
        let end: [UInt8] = [0x80, 0x00, 0x00]
        store.harvestChunk(streamIndex: 0, ptsSeconds: 10, durationSeconds: 0, flags: 0,
                           payload: Data(pcs), assembleSplitDisplaySets: true)
        store.harvestChunk(streamIndex: 0, ptsSeconds: nil, durationSeconds: 0, flags: 0,
                           payload: Data(ods), assembleSplitDisplaySets: true)
        store.harvestChunk(streamIndex: 0, ptsSeconds: nil, durationSeconds: 0, flags: 0,
                           payload: Data(end), assembleSplitDisplaySets: true)
        let entries = store.entries(streamIndex: 0, from: 0, through: 100)
        #expect(entries.count == 1)
        #expect(entries.first?.payload == Data(pcs + ods + end))
    }

    // MARK: - Diagnostics

    @Test("the memprobe states the pump's window alone, and the read-ahead asked against what was read")
    func memprobeFragments() {
        #expect(AetherEngine.readerWindowFragment(pump: nil).isEmpty)
        let pump = AetherEngine.readerWindowFragment(
            pump: (windowBytes: 12 * 1024 * 1024, aheadBytes: 8 * 1024 * 1024, parked: true))
        #expect(pump == "pumpWinMB=12 pumpAheadMB=8 pumpParked=1 ")
        #expect(AetherEngine.subtitleReadAheadFragment(asked: nil, read: nil) == "subReadAhead=off subRead=none ")
        #expect(AetherEngine.subtitleReadAheadFragment(asked: 270, read: 41.25) == "subReadAhead=270s subRead=41.2s ")
        #expect(AetherEngine.subtitleReadAheadFragment(asked: 75, read: .infinity) == "subReadAhead=75s subRead=eof ")
    }

    @Test("the seek signal mirrors what it is set to")
    func seekSignalMirrors() {
        let signal = SeekInFlightSignal()
        #expect(!signal.isSeeking)
        signal.set(true)
        #expect(signal.isSeeking)
        signal.set(false)
        #expect(!signal.isSeeking)
    }

    // MARK: - Helpers

    /// Waits until `value` stops changing for half a second.
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(condition())
    }
}
