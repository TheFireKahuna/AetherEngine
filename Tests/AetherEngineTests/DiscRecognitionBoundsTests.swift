import Foundation
import Testing
@testable import AetherEngine

/// Audit NET-103: disc recognition trusted the image's own counts. A crafted Blu-ray made the
/// title-assembly loop quadratic (1000 PlayItems x 2000 extents took 0.6 s, 4000 took 9.2 s), kept every
/// parsed `.mpls` alive (a UDF directory under its 8 MB cap names about 160k files that can all point at
/// one ICB, so memory passed 2 GB after about 1000 entries), and grouped a DVD by any VTS number.
struct DiscRecognitionBoundsTests {

    private typealias Extents = [(offset: Int64, length: Int64)]

    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private func be32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    private func mpls(playItems declared: Int, present: Int? = nil) -> [UInt8] {
        func item(_ index: Int) -> [UInt8] {
            var body: [UInt8] = []
            body += Array(String(format: "%05d", index % 100_000).utf8)
            body += Array("M2TS".utf8)
            body += be16(0)
            body.append(0)
            body += be32(0)
            body += be32(45_000)
            body += [UInt8](repeating: 0, count: 8)
            return be16(body.count) + body
        }
        var playlist: [UInt8] = []
        playlist += be32(0)
        playlist += be16(0)
        playlist += be16(declared)
        playlist += be16(0)
        for index in 0..<(present ?? declared) { playlist += item(index) }
        var out: [UInt8] = []
        out += Array("MPLS".utf8)
        out += Array("0200".utf8)
        out += be32(40)
        out += be32(0)
        out += [UInt8](repeating: 0, count: 40 - out.count)
        out += playlist
        return out
    }

    private func entries(_ count: Int) -> [UDFEntry] {
        (0..<count).map { UDFEntry(name: "\(String(format: "%05d", $0)).mpls", isDir: false, icbBlock: 7, icbPartRef: 1) }
    }

    /// A stub source where every entry is a playlist of `bytes`, declared at `declaredLength`.
    private final class PlaylistSource: @unchecked Sendable {
        let bytes: [UInt8]
        let declaredLength: Int64
        private(set) var extentCalls = 0
        private(set) var readCalls = 0
        init(bytes: [UInt8], declaredLength: Int64? = nil) {
            self.bytes = bytes
            self.declaredLength = declaredLength ?? Int64(bytes.count)
        }
        func scan(_ list: [UDFEntry]) -> [MPLSPlaylist] {
            DiscReader.scanPlaylists(list,
                                     extents: { entries in
                                         self.extentCalls += entries.count
                                         return entries.map { _ in [(offset: Int64(0), length: self.declaredLength)] }
                                     },
                                     read: { _ in self.readCalls += 1; return self.bytes })
        }
    }

    // MARK: - Small file reads

    /// An image read the way `HTTPDiscIOReader` reads one: a read outside its one window fetches a new
    /// window from there.
    private final class WindowedImage: IOReader, @unchecked Sendable {
        let base: DataIOReader
        let window: Int64
        private var position: Int64 = 0
        private var windowStart: Int64 = -1
        private(set) var fetches = 0
        init(_ data: Data, window: Int64 = 256 * 1024) { base = DataIOReader(data: data); self.window = window }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            if windowStart < 0 || position < windowStart || position >= windowStart + window {
                fetches += 1
                windowStart = position
            }
            let n = min(Int64(size), windowStart + window - position)
            _ = base.seek(offset: position, whence: SEEK_SET)
            let got = base.read(buffer, size: Int32(n))
            if got > 0 { position += Int64(got) }
            return got
        }
        func seek(offset: Int64, whence: Int32) -> Int64 {
            guard whence == SEEK_SET else { return base.seek(offset: offset, whence: whence) }
            position = offset
            return offset
        }
        func close() {}
    }

    @Test("an image's small files are read in the order they sit on it, a few windows for hundreds of files")
    func imageFilesReadInDiscOrder() {
        // 400 files of 2 KB laid end to end, asked for in a scrambled order (a title's clips rarely sit in
        // play order).
        let count = 400, size = 2048
        let data = Data((0..<count * size).map { UInt8(truncatingIfNeeded: $0 / size) })
        var rng = SystemRandomNumberGenerator()
        let asked = (0..<count).shuffled(using: &rng)
        let extents: [Extents] = asked.map { [(offset: Int64($0 * size), length: Int64(size))] }
        let image = WindowedImage(data)
        let files = DiscReader.readImageFiles(declared: extents.map { $0[0].length },
                                              offsets: extents.map { $0[0].offset }, scope: DiscRecognitionScope(),
                                              read: { DiscReader.readAll(image, extents[$0]) })
        #expect(files.map { $0.first.map(Int.init) } == asked.map { Optional($0 % 256) })
        #expect(image.fetches <= (count * size) / (256 * 1024) + 1)

        // The same reads in the order asked cost a window nearly every file.
        let unordered = WindowedImage(data)
        for e in extents { _ = DiscReader.readAll(unordered, e) }
        #expect(unordered.fetches > count / 2)
    }

    @Test("a run of short reads from an image ends the reading")
    func imageShortRunStops() {
        var reads = 0
        let files = DiscReader.readImageFiles(declared: Array(repeating: 100, count: 1000),
                                              offsets: (0..<1000).map(Int64.init), scope: DiscRecognitionScope(),
                                              read: { _ in reads += 1; return [] })
        #expect(files.count == 1000)
        #expect(reads == DiscReader.maxConsecutiveShortReads)
    }

    @Test("a folder's small files are read in lanes, results in the order asked")
    func folderFilesReadInLanes() {
        final class Gauge: @unchecked Sendable {
            let lock = NSLock()
            var inFlight = 0, peak = 0
            func enter() { lock.lock(); inFlight += 1; peak = max(peak, inFlight); lock.unlock() }
            func leave() { lock.lock(); inFlight -= 1; lock.unlock() }
        }
        let gauge = Gauge()
        let files = DiscReader.readFolderFiles(count: 200, scope: DiscRecognitionScope()) { i in
            gauge.enter()
            defer { gauge.leave() }
            Thread.sleep(forTimeInterval: 0.002)
            return [UInt8(truncatingIfNeeded: i)]
        }
        #expect(files.map { $0.first } == (0..<200).map { Optional(UInt8(truncatingIfNeeded: $0)) })
        #expect(gauge.peak > 1)
        #expect(gauge.peak <= BlockingWork.readLanes)
    }

    // MARK: - MPLSParser

    @Test("a playlist may hold at most 999 PlayItems, the BD-ROM limit")
    func playItemCountIsBounded() {
        #expect(MPLSParser.parse(mpls(playItems: 999))?.clipIDs.count == 999)
        #expect(MPLSParser.parse(mpls(playItems: 1000)) == nil)
        #expect(MPLSParser.parse(mpls(playItems: 65_535, present: 10)) == nil)
    }

    // MARK: - PLAYLIST scan

    @Test("a PLAYLIST directory of 160k aliases is read at most 4000 times")
    func playlistEntriesAreCapped() {
        let source = PlaylistSource(bytes: mpls(playItems: 1))
        let parsed = source.scan(entries(160_000))
        #expect(parsed.count == DiscReader.maxPlaylistFiles)
        #expect(source.extentCalls == DiscReader.maxPlaylistFiles)
        #expect(source.readCalls == DiscReader.maxPlaylistFiles)
    }

    @Test("entries that are not .mpls files cost nothing against the cap")
    func otherEntriesAreNotCounted() {
        let source = PlaylistSource(bytes: mpls(playItems: 1))
        var list = (0..<10_000).map { UDFEntry(name: "\($0).clpi", isDir: false, icbBlock: 7, icbPartRef: 1) }
        list += entries(3)
        #expect(source.scan(list).count == 3)
        #expect(source.extentCalls == 3)
    }

    @Test("playlist bytes are read up to a total budget")
    func playlistBytesAreBudgeted() {
        let oneMiB = 1 << 20
        var padded = mpls(playItems: 1)
        padded += [UInt8](repeating: 0, count: oneMiB - padded.count)
        let source = PlaylistSource(bytes: padded)
        let parsed = source.scan(entries(200))
        let expected = Int(DiscReader.maxPlaylistBytes) / oneMiB
        #expect(parsed.count == expected)
        #expect(source.readCalls == expected)
    }

    @Test("an oversized playlist extent is skipped without being read or charged")
    func oversizedPlaylistIsNotRead() {
        let source = PlaylistSource(bytes: [], declaredLength: 64 * 1024 * 1024)
        #expect(source.scan(entries(10)).isEmpty)
        #expect(source.readCalls == 0)
    }

    @Test("parsed PlayItems are kept up to a total budget")
    func playItemsAreBudgeted() {
        let source = PlaylistSource(bytes: mpls(playItems: 999))
        let parsed = source.scan(entries(600))
        #expect(parsed.count == DiscReader.maxPlaylistItems / 999)
        #expect(parsed.reduce(0) { $0 + $1.clipIDs.count } <= DiscReader.maxPlaylistItems)
    }

    @Test("a source that stops delivering ends the scan after a short run of failures")
    func unreadableSourceEndsTheScan() {
        let source = PlaylistSource(bytes: [], declaredLength: 100)
        #expect(source.scan(entries(1000)).isEmpty)
        #expect(source.readCalls < 100)
    }

    @Test("an unparseable playlist does not end the scan")
    func garbagePlaylistsDoNotEndTheScan() {
        let garbage = [UInt8](repeating: 0xAB, count: 64)
        let source = PlaylistSource(bytes: garbage)
        #expect(source.scan(entries(100)).isEmpty)
        #expect(source.readCalls == 100)
    }

    // MARK: - Title assembly

    private func extents(_ count: Int, length: Int64 = 1 << 20, base: Int64 = 0) -> Extents {
        (0..<count).map { (offset: base + Int64($0) * length, length: length) }
    }

    @Test("a repeated clip is resolved once and the byte starts run")
    func repeatedClipIsLookedUpOnce() {
        var lookups: [String] = []
        let ids = ["00001", "00002", "00001", "00002", "00001"]
        let result = DiscReader.assembleBluRayTitle(
            clipIDs: ids, subtractTicks: [0, 45_000, 0, 45_000, 0],
            cumulativeBeforeTicks: [0, 90_000, 180_000, 270_000, 360_000],
            extentsOfClip: { clip in
                lookups.append(clip)
                return clip == "00001" ? self.extents(2, length: 100) : self.extents(1, length: 1000)
            })
        #expect(lookups == ["00001", "00002"])
        #expect(result.extents.count == 8)
        #expect(result.clipTimeline.map(\.concatByteStart) == [0, 200, 1200, 1400, 2400])
        #expect(result.clipTimeline.map(\.cumulativeBeforeSec) == [0, 2, 4, 6, 8])
        #expect(result.clipTimeline.map(\.predictedShiftSec) == [0, 1, 0, 1, 0])
    }

    @Test("a clip without a stream file is skipped and keeps its index for the tick tables")
    func missingClipIsSkipped() {
        let result = DiscReader.assembleBluRayTitle(
            clipIDs: ["00001", "00002", "00003"], subtractTicks: [0, 45_000, 90_000],
            cumulativeBeforeTicks: [0, 45_000, 90_000],
            extentsOfClip: { clip in clip == "00002" ? nil : self.extents(1, length: 500) })
        #expect(result.extents.count == 2)
        #expect(result.clipTimeline.map(\.concatByteStart) == [0, 500])
        #expect(result.clipTimeline.map(\.predictedShiftSec) == [0, 2])
    }

    @Test("a title whose clips hold 2M extents stops at the cap, fast, with consistent spans")
    func titleExtentsAreCapped() {
        let ids = (0..<999).map { String(format: "%05d", $0 % 3) }
        let started = ContinuousClock.now
        let result = DiscReader.assembleBluRayTitle(
            clipIDs: ids, subtractTicks: [], cumulativeBeforeTicks: [],
            extentsOfClip: { _ in self.extents(2_100) })
        #expect(ContinuousClock.now - started < .seconds(2))
        let fit = DiscReader.maxTitleExtents / 2_100
        #expect(result.clipTimeline.count == fit)
        #expect(result.extents.count == fit * 2_100)
        #expect(result.clipTimeline.last?.concatByteStart == Int64(fit - 1) * 2_100 * Int64(1 << 20))
    }

    @Test("a single clip that alone passes the extent cap yields no title")
    func oversizedClipYieldsNothing() {
        let result = DiscReader.assembleBluRayTitle(
            clipIDs: ["00001"], subtractTicks: [], cumulativeBeforeTicks: [],
            extentsOfClip: { _ in self.extents(DiscReader.maxTitleExtents + 1, length: 1) })
        #expect(result.extents.isEmpty)
        #expect(result.clipTimeline.isEmpty)
    }

    // MARK: - DVD

    @Test("a DVD has title sets 1 to 99, and 8000 names beyond that are not grouped")
    func vtsNumbersAreBounded() {
        var files: [DiscFile] = [
            .init(name: "VTS_01_1.VOB", startSector: 2, length: 100),
            .init(name: "VTS_99_1.VOB", startSector: 3, length: 200),
            .init(name: "VTS_00_1.VOB", startSector: 4, length: 300),
            .init(name: "VTS_100_1.VOB", startSector: 5, length: 400),
        ]
        for index in 101..<8_100 { files.append(.init(name: "VTS_\(index)_1.VOB", startSector: index, length: 10)) }
        let started = ContinuousClock.now
        let groups = DVDTitleSelector.enumerateTitleVOBGroups(files)
        #expect(groups.map(\.vtsn) == [99, 1])
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("an ISO naming a VTS beyond 99 never makes that set a title")
    func dvdWrapIgnoresOutOfRangeTitleSets() throws {
        let data = ISO9660Fixture.make(files: [
            .init(name: "VTS_01_1.VOB", length: 2048),
            .init(name: "VTS_150_1.VOB", length: 900_000_000),
        ])
        let info = try #require(try DiscReader.wrap(DataIOReader(data: data)))
        #expect(info.titles.count == 1)
        #expect(info.titles.first?.dvdVTSN == 1)
    }
}
