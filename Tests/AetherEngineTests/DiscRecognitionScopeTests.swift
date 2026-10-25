import Foundation
import Testing
@testable import AetherEngine

/// Stopping a disc recognition (`DiscRecognitionScope`): the files it reads stop, its own readers are
/// cancelled, the source it reads from is not, and nothing it read reaches the recognition cache.
@Suite("Disc recognition scope", .offCooperativePool)
struct DiscRecognitionScopeTests {

    /// A file whose reads park until it is cancelled, the way an HTTP read parks on a slow origin.
    final class ParkedFile: IOReader, @unchecked Sendable {
        private let released = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private(set) var cancelled = false
        private(set) var closed = false
        let parked = DispatchSemaphore(value: 0)
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            parked.signal()
            released.wait()
            return -1
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { offset }
        func cancel() {
            lock.withLock { cancelled = true }
            released.signal()
        }
        func close() { lock.withLock { closed = true } }
        var wasCancelled: Bool { lock.withLock { cancelled } }
        var wasClosed: Bool { lock.withLock { closed } }
    }

    /// A disc folder of `playlists` playlists whose files all park, recording every file it opens.
    final class ParkedFolder: DiscDirectoryReader, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var opened: [ParkedFile] = []
        let discFiles: [(path: String, size: Int64)]
        var preferredPlaylist: String? { nil }
        init(playlists: Int) {
            discFiles = [("BDMV/index.bdmv", 4)]
                + (0..<playlists).map { (String(format: "BDMV/PLAYLIST/%05d.mpls", $0), 100) }
                + [("BDMV/STREAM/00001.m2ts", 188)]
        }
        func openDiscFile(_ path: String) -> IOReader? {
            let file = ParkedFile()
            lock.withLock { opened.append(file) }
            return file
        }
        var openedFiles: [ParkedFile] { lock.withLock { opened } }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { -1 }
        func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
        func close() {}
    }

    @Test("a stop cancels the files being read, and no file is opened after it")
    func stopCancelsItsFiles() throws {
        let scope = DiscRecognitionScope()
        let file = ParkedFile()
        let finished = DispatchSemaphore(value: 0)
        Thread {
            _ = scope.withFile({ file }) { reader -> Int32 in
                var byte: UInt8 = 0
                return reader.read(&byte, size: 1)
            }
            finished.signal()
        }.start()
        #expect(file.parked.wait(timeout: .now() + 5) == .success)
        scope.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(file.wasCancelled)
        #expect(file.wasClosed)

        var opens = 0
        #expect(scope.withFile({ opens += 1; return ParkedFile() }) { _ in 1 } == nil)
        #expect(opens == 0)
    }

    @Test("a stop from outside the scope is seen before the next file")
    func outsideStop() {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var raised = false
            func raise() { lock.withLock { raised = true } }
            var isRaised: Bool { lock.withLock { raised } }
        }
        let flag = Flag()
        let scope = DiscRecognitionScope(stoppedOutside: { flag.isRaised })
        #expect(!scope.isStopped)
        flag.raise()
        #expect(scope.isStopped)
        #expect(scope.withFile({ ParkedFile() }) { _ in 1 } == nil)
    }

    @Test("a folder recognition stopped mid-read throws at once, its files cancelled, its source untouched")
    func folderRecognitionStops() throws {
        let folder = ParkedFolder(playlists: 300)
        let scope = DiscRecognitionScope()
        final class Outcome: @unchecked Sendable { var error: (any Error)?; var info: DiscInfo? }
        let outcome = Outcome()
        let finished = DispatchSemaphore(value: 0)
        Thread {
            do { outcome.info = try DiscReader.wrap(folder, scope: scope) } catch { outcome.error = error }
            finished.signal()
        }.start()
        // Every lane parks on a file; then stop.
        let deadline = Date().addingTimeInterval(5)
        while folder.openedFiles.count < BlockingWork.readLanes, Date() < deadline { usleep(1_000) }
        #expect(folder.openedFiles.count == BlockingWork.readLanes)
        scope.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(outcome.info == nil)
        #expect((outcome.error as? DiscError) == .recognitionStopped)
        let opened = folder.openedFiles
        #expect(opened.count == BlockingWork.readLanes)
        #expect(opened.allSatisfy { $0.wasCancelled && $0.wasClosed })
    }

    @Test("markClosed during a demuxer's open stops a folder's recognition")
    func markClosedStopsRecognition() throws {
        let folder = ParkedFolder(playlists: 300)
        let demuxer = Demuxer()
        final class Outcome: @unchecked Sendable { var error: (any Error)? }
        let outcome = Outcome()
        let finished = DispatchSemaphore(value: 0)
        Thread {
            do { try demuxer.open(reader: folder) } catch { outcome.error = error }
            finished.signal()
        }.start()
        let deadline = Date().addingTimeInterval(5)
        while folder.openedFiles.count < BlockingWork.readLanes, Date() < deadline { usleep(1_000) }
        demuxer.markClosed()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        let openFailed = outcome.error != nil
        #expect(openFailed)
        #expect(folder.openedFiles.allSatisfy { $0.wasCancelled })
        demuxer.close()
    }

    @Test("a stopped image recognition is not cached")
    func stoppedImageIsNotCached() throws {
        let image = BluRayEPMapSeekTests.image()
        let key = "scope-test-\(UUID().uuidString)"
        let scope = DiscRecognitionScope()
        scope.stop()
        #expect(throws: DiscError.recognitionStopped) {
            try DiscReader.wrap(DataIOReader(data: image), cacheKey: key, scope: scope)
        }
        #expect(DiscRecognitionCache.lookup(key: key, selectTitleID: nil) == nil)
        // The same disc, not stopped, is recognized and cached.
        #expect(try DiscReader.wrap(DataIOReader(data: image), cacheKey: key) != nil)
        #expect(DiscRecognitionCache.lookup(key: key, selectTitleID: nil) != nil)
    }
}
