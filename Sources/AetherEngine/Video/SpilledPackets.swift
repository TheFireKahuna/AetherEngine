import Foundation
import AetherLibavcodec

/// The access units an overlay tap keeps until AVPlayer's clock reaches them, held on disk rather than in memory.
///
/// The producer cuts ahead of AVPlayer, by its forward window and as far as a subtitle consumer asks it to read, and a
/// tap keeps every unit it is handed until the clock has passed it. In memory that grows with the producer's lead (a
/// Dolby Vision enhancement layer is about 85 KB a frame, a software-decoded stream's whole picture more), so each unit
/// is written once, as it is cut, and read back on the decode thread just before it is decoded, from the page cache in
/// the usual case. The files are unlinked as soon as they are opened, so they go with the store or with the process,
/// and a chunk's space goes back once no unit written to it is kept.
final class SpilledPackets: @unchecked Sendable {

    /// Where one unit was written. Keeping it keeps its chunk.
    struct Ref: @unchecked Sendable {
        fileprivate let chunk: Chunk
        fileprivate let offset: Int64
        let length: Int
    }

    fileprivate final class Chunk {
        let fd: Int32
        init(fd: Int32) { self.fd = fd }
        deinit { Darwin.close(fd) }
    }

    /// A chunk is closed to new units at this size; its space goes back when the last unit in it is dropped.
    static let chunkBytes: Int64 = 32 << 20

    private let lock = NSLock()
    private var current: Chunk?
    private var currentLength: Int64 = 0
    private var loggedFailure = false

    /// Writes `packet` (which stays the caller's) and returns where; nil when the volume refused it, and the unit is
    /// then kept without anything to decode.
    func write(_ packet: UnsafeMutablePointer<AVPacket>) -> Ref? {
        guard let data = try? SoftwareStoredPacket(copying: packet).encoded() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if current == nil || (currentLength > 0 && currentLength + Int64(data.count) > Self.chunkBytes) {
            current = nil
            guard let chunk = Self.openChunk() else { return noteFailure("no chunk file: errno \(errno)") }
            current = chunk
            currentLength = 0
        }
        guard let chunk = current else { return nil }
        let written = data.withUnsafeBytes { Self.writeFully($0, to: chunk.fd, at: currentLength) }
        guard written else {
            current = nil
            return noteFailure("write failed: errno \(errno)")
        }
        let ref = Ref(chunk: chunk, offset: currentLength, length: data.count)
        currentLength += Int64(data.count)
        return ref
    }

    /// The unit at `ref`, as a packet the caller owns (`trackedPacketFree`); nil when it cannot be read back.
    static func read(_ ref: Ref) -> UnsafeMutablePointer<AVPacket>? {
        var data = Data(count: ref.length)
        let read = data.withUnsafeMutableBytes { readFully($0, from: ref.chunk.fd, at: ref.offset) }
        guard read else { return nil }
        return try? SoftwareStoredPacket.decode(data).makeAVPacket()
    }

    /// Closes the chunk being written; chunks still holding kept units close with their last one.
    func close() {
        lock.lock()
        current = nil
        lock.unlock()
    }

    private func noteFailure(_ reason: String) -> Ref? {
        guard !loggedFailure else { return nil }
        loggedFailure = true
        EngineLog.emit("[SpilledPackets] a unit was not kept on disk (\(reason)); units the volume refuses are kept with nothing to decode",
                       category: .swPlayback)
        return nil
    }

    private static func openChunk() -> Chunk? {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-overlay-units-\(UUID().uuidString)").path
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        unlink(path)
        return Chunk(fd: fd)
    }

    private static func writeFully(_ bytes: UnsafeRawBufferPointer, to fd: Int32, at offset: Int64) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        var done = 0
        while done < bytes.count {
            let n = pwrite(fd, base + done, bytes.count - done, off_t(offset) + off_t(done))
            if n > 0 { done += n; continue }
            if n < 0, errno == EINTR { continue }
            return false
        }
        return true
    }

    private static func readFully(_ bytes: UnsafeMutableRawBufferPointer, from fd: Int32, at offset: Int64) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        var done = 0
        while done < bytes.count {
            let n = pread(fd, base + done, bytes.count - done, off_t(offset) + off_t(done))
            if n > 0 { done += n; continue }
            if n < 0, errno == EINTR { continue }
            return false
        }
        return true
    }
}
