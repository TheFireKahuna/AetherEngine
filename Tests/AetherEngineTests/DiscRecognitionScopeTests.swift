import Darwin
import Foundation
import Testing
@testable import AetherEngine

/// Stopping a disc recognition (`DiscRecognitionScope`): the files it reads stop, its own readers are
/// cancelled, the source it reads from is not, and nothing it read reaches the recognition cache.
@Suite("Disc recognition scope", .offCooperativePool)
struct DiscRecognitionScopeTests {

    /// An origin that takes every connection and never answers, the way a slow origin parks an HTTP read: how many
    /// requests reached it, and how many of their connections the client has since closed.
    final class ParkingOrigin: @unchecked Sendable {
        private let listener: LoopbackListener
        private let lock = NSLock()
        private var opened = 0, closed = 0

        init() throws {
            listener = try #require(LoopbackListener(backlog: 64))
            listener.start { [self] fd in
                lock.withLock { opened += 1 }
                Thread.detachNewThread { [self] in
                    var byte: UInt8 = 0
                    while recv(fd, &byte, 1, 0) > 0 {}
                    Darwin.close(fd)
                    lock.withLock { closed += 1 }
                }
                return true
            }
        }
        deinit { listener.stop() }

        func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(listener.port)/\(UUID().uuidString)/\(path)")! }
        var requests: Int { lock.withLock { opened } }
        var closedConnections: Int { lock.withLock { closed } }

        /// A disc folder of `playlists` playlists, every file served here.
        func folder(playlists: Int) -> HTTPDiscDirectoryReader {
            let files = [("BDMV/index.bdmv", Int64(4))]
                + (0..<playlists).map { (String(format: "BDMV/PLAYLIST/%05d.mpls", $0), Int64(100)) }
                + [("BDMV/STREAM/00001.m2ts", Int64(188))]
            return HTTPDiscDirectoryReader(files: files.map { .init(path: $0.0, size: $0.1, url: url($0.0)) })
        }
    }

    private static func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { usleep(1_000) }
    }

    @Test("a stop cancels the files being read, and no file is opened after it")
    func stopCancelsItsFiles() throws {
        let origin = try ParkingOrigin()
        let scope = DiscRecognitionScope()
        let file = try #require(HTTPDiscIOReader(url: origin.url("index.bdmv"), knownSize: 4))
        let finished = DispatchSemaphore(value: 0)
        Thread {
            _ = scope.withFile({ file }) { reader -> Int32 in
                var byte: UInt8 = 0
                return reader.read(&byte, size: 1)
            }
            finished.signal()
        }.start()
        Self.waitUntil { origin.requests == 1 }
        #expect(origin.requests == 1, "the read is parked on the origin")
        scope.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        Self.waitUntil { origin.closedConnections == 1 }
        #expect(origin.closedConnections == 1, "the file was cancelled and closed")

        var opens = 0
        #expect(scope.withFile({ opens += 1; return file }) { _ in 1 } == nil)
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
        #expect(scope.withFile({ DataIOReader(data: Data()) }) { _ in 1 } == nil)
    }

    @Test("a folder recognition stopped mid-read throws at once, its files cancelled, its source untouched")
    func folderRecognitionStops() throws {
        let origin = try ParkingOrigin()
        let folder = origin.folder(playlists: 300)
        let scope = DiscRecognitionScope()
        final class Outcome: @unchecked Sendable { var error: (any Error)?; var info: DiscInfo? }
        let outcome = Outcome()
        let finished = DispatchSemaphore(value: 0)
        Thread {
            do { outcome.info = try DiscReader.wrap(folder, scope: scope) } catch { outcome.error = error }
            finished.signal()
        }.start()
        // Every lane parks on a file; then stop.
        Self.waitUntil { origin.requests == BlockingWork.readLanes }
        #expect(origin.requests == BlockingWork.readLanes)
        scope.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(outcome.info == nil)
        #expect((outcome.error as? DiscError) == .recognitionStopped)
        Self.waitUntil { origin.closedConnections == BlockingWork.readLanes }
        #expect(origin.requests == BlockingWork.readLanes, "no file opened after the stop")
        #expect(origin.closedConnections == BlockingWork.readLanes, "every file cancelled and closed")
    }

    @Test("markClosed during a demuxer's open stops a folder's recognition")
    func markClosedStopsRecognition() throws {
        let origin = try ParkingOrigin()
        let folder = origin.folder(playlists: 300)
        let demuxer = Demuxer()
        final class Outcome: @unchecked Sendable { var error: (any Error)? }
        let outcome = Outcome()
        let finished = DispatchSemaphore(value: 0)
        Thread {
            do { try demuxer.open(reader: folder) } catch { outcome.error = error }
            finished.signal()
        }.start()
        Self.waitUntil { origin.requests == BlockingWork.readLanes }
        demuxer.markClosed()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        let openFailed = outcome.error != nil
        #expect(openFailed)
        Self.waitUntil { origin.closedConnections == origin.requests }
        #expect(origin.closedConnections == origin.requests, "every parked file cancelled")
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
