import Darwin
import Foundation
import os

/// Seekable `IOReader` over a local file. Reads on demand (no whole-file load), so it suits
/// multi-GB ISO images, and each read is one `pread` straight into the caller's buffer: no
/// allocation, no copy and nothing autoreleased. Threading: the cursor lock makes read/seek safe
/// off the engine's demux thread; `readRange` leaves the cursor alone and runs concurrently.
final class FileIOReader: RangeReadableIOReader, @unchecked Sendable {
    private let fd: Int32
    private let url: URL
    private let size: Int64
    private struct Cursor {
        var position: Int64 = 0
        var closed = false
    }
    private let cursor = OSAllocatedUnfairLock(initialState: Cursor())

    init?(url: URL) {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
        self.url = url
        self.size = Int64(st.st_size)
    }

    /// The descriptor goes with the reader rather than with `close()`: a `readRange` lane still in
    /// its `pread` keeps a reader alive, and closing under it could hand the number to another open.
    deinit { Darwin.close(fd) }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size n: Int32) -> Int32 {
        guard let buffer, n > 0 else { return -1 }
        return cursor.withLockUnchecked { state -> Int32 in
            guard !state.closed else { return -1 }
            guard let got = Self.pread(fd, into: buffer, count: Int(n), at: state.position) else { return -1 }
            state.position += Int64(got)
            return Int32(got)
        }
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == 65536 { return size }
        return cursor.withLock { state -> Int64 in
            let target: Int64
            switch whence {
            case SEEK_SET: target = offset
            case SEEK_CUR: target = state.position + offset
            case SEEK_END: target = size + offset
            default: return -1
            }
            guard target >= 0 else { return -1 }
            state.position = target
            return target
        }
    }

    func readRange(at offset: Int64, count: Int) -> Data? {
        guard offset >= 0, count > 0, offset < size else { return Data() }
        guard !cursor.withLock({ $0.closed }) else { return nil }
        let want = Int(min(Int64(count), size - offset))
        guard let buffer = malloc(want) else { return nil }
        var done = 0
        while done < want {
            guard let got = Self.pread(fd, into: buffer + done, count: want - done, at: offset + Int64(done)) else {
                free(buffer)
                return nil
            }
            if got == 0 { break }   // the file shrank since it was opened
            done += got
        }
        guard done > 0 else {
            free(buffer)
            return Data()
        }
        return Data(bytesNoCopy: buffer, count: done, deallocator: .free)
    }

    func close() { cursor.withLock { $0.closed = true } }

    func makeIndependentReader() -> IOReader? { FileIOReader(url: url) }

    /// One `pread`, retried across signals. nil on an error, 0 at end of file.
    private static func pread(_ fd: Int32, into buffer: UnsafeMutableRawPointer, count: Int, at offset: Int64) -> Int? {
        while true {
            let n = Darwin.pread(fd, buffer, count, off_t(offset))
            if n >= 0 { return n }
            if errno != EINTR { return nil }
        }
    }
}
