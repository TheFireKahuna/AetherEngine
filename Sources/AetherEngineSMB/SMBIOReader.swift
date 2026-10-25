import Foundation
import os
import AetherEngine

/// One-shot holder for a blocking read's result. Written once inside the bridging Task, read once after the semaphore wait; the DispatchSemaphore provides the happens-before edge that makes @unchecked Sendable safe.
private final class ReadOutcome: @unchecked Sendable {
    var result: Result<Data, Error> = .success(Data())
}

/// Bridges a `ByteRangeSource` into the engine's `IOReader`. `read`/`seek`
/// are synchronous blocking calls on the engine's demux thread; the async
/// source is driven through a `DispatchSemaphore`.
public final class SMBIOReader: IOReader, @unchecked Sendable {
    private let source: ByteRangeSource
    private let ownsSource: Bool
    public let discImageProbeEnabled: Bool
    // The cursor, the block and `didClose` are only accessed on the demux/teardown thread
    // per the IOReader contract; no lock needed.
    private var position: Int64 = 0
    private var didClose = false
    /// The last block fetched and where it starts. FFmpeg reads a few hundred KB at a time, and a
    /// round trip per read caps throughput at read size over latency, so the reader fetches blocks
    /// that grow while reads stay sequential, up to what one SMB READ may carry, and serves from them.
    private var block = Data()
    private var blockStart: Int64 = 0
    private var readAhead: ReadAhead
    /// Per-read in-flight state, published so cancel() (a different thread) can both cancel the
    /// background work and, crucially, unblock read()'s semaphore wait. The underlying SMB read
    /// is an in-flight network round-trip that task.cancel() may not interrupt promptly (it can
    /// block until the connection times out), so task.cancel() alone could not reliably wake the
    /// wait and teardown could stall; cancel() now signals the semaphore directly and read() aborts.
    private final class Inflight: @unchecked Sendable {
        let task: Task<Void, Never>
        let semaphore: DispatchSemaphore
        var cancelled = false
        init(task: Task<Void, Never>, semaphore: DispatchSemaphore) {
            self.task = task
            self.semaphore = semaphore
        }
    }
    // Written on the demux thread (read()), read/mutated on a different thread (cancel()); guarded.
    private let inFlightLock = OSAllocatedUnfairLock<Inflight?>(initialState: nil)

    /// `AVSEEK_SIZE` from FFmpeg: return total size, do not move.
    private let avseekSize: Int32 = 65536

    /// - Parameter discImageProbeEnabled: Keep enabled for an SMB path that is a raw ISO/UDF disc
    ///   image. Set to `false` for an ordinary media file to avoid sparse signature reads before
    ///   container probing.
    public init(
        source: ByteRangeSource,
        ownsSource: Bool = true,
        discImageProbeEnabled: Bool = true
    ) {
        self.source = source
        self.ownsSource = ownsSource
        self.discImageProbeEnabled = discImageProbeEnabled
        self.readAhead = ReadAhead(floor: Self.blockFloor, ceiling: source.preferredReadSize)
    }

    /// The smallest block worth a round trip: FFmpeg's own read through the engine's AVIO bridge.
    static let blockFloor = 256 * 1024

    public func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return 0 }
        if position >= source.byteSize { return 0 }
        if position < blockStart || position >= blockStart + Int64(block.count) {
            let data: Data
            if let ahead = takeNextBlock(at: position) {
                data = ahead
            } else {
                let length = readAhead.size(forReadAt: position, requested: Int(size))
                guard let fetched = fetch(at: position, length: length) else { return -1 }
                data = fetched
            }
            if data.isEmpty { return 0 } // EOF
            blockStart = position
            block = data
            readAhead.fetched(at: position, count: data.count)
            startNextBlock(after: position + Int64(data.count), requested: Int(size))
        }
        // #243 (same family as the file and HTTP disc readers): this runs on FFmpeg's read
        // callback, i.e. on a demux pump thread that never returns from its dispatch block and
        // so never drains its autorelease pool. The SMB body arrives as a dispatch_data-backed
        // `Data`, and anything the copy bridges out on this thread would be stranded for the
        // whole session, at the source's read rate.
        return autoreleasepool { () -> Int32 in
            let from = Int(position - blockStart)
            let n = min(Int(size), block.count - from)
            let lower = block.startIndex + from
            block.copyBytes(to: UnsafeMutableBufferPointer(start: buffer, count: n), from: lower..<(lower + n))
            position += Int64(n)
            return Int32(n)
        }
    }

    // MARK: - Read-ahead

    /// The next block of a sequential walk, read while the demuxer consumes the current one, so the
    /// round trip overlaps the consumption instead of following it. One block at a time.
    private final class NextBlock: @unchecked Sendable {
        let offset: Int64
        let task: Task<Data?, Never>
        init(offset: Int64, task: Task<Data?, Never>) {
            self.offset = offset
            self.task = task
        }
    }
    private let nextBlockLock = OSAllocatedUnfairLock<NextBlock?>(initialState: nil)

    /// Starts reading the block at `offset` once reads have turned sequential (the block has grown
    /// past its floor) and the file has more. Demux thread.
    private func startNextBlock(after offset: Int64, requested: Int) {
        guard offset < source.byteSize, readAhead.current > readAhead.floor else { return }
        let length = readAhead.size(forReadAt: offset, requested: requested)
        let task = Task { [source] () -> Data? in
            try? await source.read(at: offset, length: length)
        }
        let replaced = nextBlockLock.withLock { state -> NextBlock? in
            defer { state = NextBlock(offset: offset, task: task) }
            return state
        }
        replaced?.task.cancel()
    }

    /// The read-ahead block when it starts at `offset`, waiting for it if it is still on its way;
    /// nil (and the block dropped) for a read anywhere else, a failed read or a cancel. Demux thread.
    private func takeNextBlock(at offset: Int64) -> Data? {
        guard let next = nextBlockLock.withLock({ state -> NextBlock? in
            defer { state = nil }
            return state
        }) else { return nil }
        guard next.offset == offset else {
            next.task.cancel()
            return nil
        }
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = ReadOutcome()
        let waiter = Task {
            if let data = await next.task.value { outcome.result = .success(data) }
            else { outcome.result = .failure(CancellationError()) }
            semaphore.signal()
        }
        inFlightLock.withLock { $0 = Inflight(task: waiter, semaphore: semaphore) }
        semaphore.wait()
        let wasCancelled = inFlightLock.withLock { state -> Bool in
            let c = state?.cancelled ?? false
            state = nil
            return c
        }
        if wasCancelled { next.task.cancel(); return nil }
        guard case .success(let data) = outcome.result else { return nil }
        return data
    }

    /// One round trip for `length` bytes at `offset`, blocking the demux thread on it. nil on an
    /// error or a cancel.
    private func fetch(at offset: Int64, length: Int) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = ReadOutcome()
        let task = Task { [source] in
            do { outcome.result = .success(try await source.read(at: offset, length: length)) }
            catch { outcome.result = .failure(error) }
            semaphore.signal()
        }
        inFlightLock.withLock { $0 = Inflight(task: task, semaphore: semaphore) }
        semaphore.wait()
        // cancel() may have signalled to unblock teardown while the SMB read is still running.
        // In that case do NOT read `outcome`: the background Task may still be writing it (the
        // semaphore's happens-before edge only covers the Task's own signal). Abort instead.
        let wasCancelled = inFlightLock.withLock { state -> Bool in
            let c = state?.cancelled ?? false
            state = nil
            return c
        }
        if wasCancelled { return nil }

        switch outcome.result {
        case .failure(let error):
            // Log the underlying SMB error (auth failure, share gone, connection reset) before the
            // -1 sentinel; without it a NAS bug report has nothing to go on. .verbose = Release-retrievable.
            EngineLog.emit("[SMBIOReader] read failed at offset \(offset): \(error.localizedDescription)",
                           category: .demux, level: .verbose)
            return nil
        case .success(let data):
            return data
        }
    }

    public func seek(offset: Int64, whence: Int32) -> Int64 {
        let candidate: Int64
        switch whence {
        case Int32(SEEK_SET): candidate = offset
        case Int32(SEEK_CUR): candidate = position + offset
        case Int32(SEEK_END): candidate = source.byteSize + offset
        case avseekSize:      return source.byteSize
        default:              return -1
        }
        guard candidate >= 0 else { return -1 }
        position = candidate
        return position
    }

    public func cancel() {
        nextBlockLock.withLock { state in
            state?.task.cancel()
            state = nil
        }
        inFlightLock.withLock { state in
            state?.cancelled = true
            state?.task.cancel()
            state?.semaphore.signal()   // wake read()'s wait; the SMB op drains in the background
        }
    }

    public func makeIndependentReader() -> IOReader? {
        // Range reads are serialised per connection by SMBClient, so the
        // independent reader shares the connection but never owns its teardown.
        SMBIOReader(
            source: source,
            ownsSource: false,
            discImageProbeEnabled: discImageProbeEnabled
        )
    }

    public func close() {
        guard !didClose else { return }
        didClose = true
        nextBlockLock.withLock { state in
            state?.task.cancel()
            state = nil
        }
        if ownsSource { source.close() }
    }
}
