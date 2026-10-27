// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import CoreMedia
import CoreVideo
import Foundation
@testable import AetherEngine

/// The GPU slot wait must not hold the decoder lock.
///
/// With a composer whose in-flight limit is 1 and whose first completion is
/// held by the test, a second composition started on another thread blocks in
/// `acquireSlot()` with no lock held, so `flush()` returns promptly. On the
/// pre-fix code the wait sat inside `composeAsync` while the VideoToolbox
/// thread held the decoder lock, and `flush()` hung behind it.
@Suite(.serialized, .offCooperativePoolOneLane, .timeLimit(.minutes(5)))
struct DualLayerGpuSlotWaitTests {

    /// Fake composer with an in-flight limit of 1. The first composition's
    /// completion is held until the test releases it; the slot is held with
    /// it, the way the real composer holds the slot until the command buffer
    /// retires.
    final class GatedFakeComposer: FelComposing, @unchecked Sendable {
        private let slots = DispatchSemaphore(value: 1)
        private let lock = NSLock()
        private var held: (@Sendable (CVPixelBuffer?) -> Void)?
        private var heldBase: CVPixelBuffer?
        private(set) var acquireCalls = 0
        private(set) var completedCount = 0
        var acquireCallCount: Int { lock.lock(); defer { lock.unlock() }; return acquireCalls }

        func acquireSlot() {
            lock.lock(); acquireCalls += 1; lock.unlock()
            slots.wait()
        }

        func releaseSlot() { slots.signal() }

        func composeAsync(
            baseBuffer: CVPixelBuffer,
            enhancementBuffer: CVPixelBuffer,
            params: DoviMetalParams,
            frameIndex: UInt32,
            completion: @escaping @Sendable (CVPixelBuffer?) -> Void
        ) {
            acquireSlot()
            composeAsyncWithAcquiredSlot(
                baseBuffer: baseBuffer, enhancementBuffer: enhancementBuffer,
                params: params, frameIndex: frameIndex, completion: completion)
        }

        func composeAsyncWithAcquiredSlot(
            baseBuffer: CVPixelBuffer,
            enhancementBuffer: CVPixelBuffer,
            params: DoviMetalParams,
            frameIndex: UInt32,
            completion: @escaping @Sendable (CVPixelBuffer?) -> Void
        ) {
            lock.lock()
            let isFirst = held == nil && completedCount == 0
            if isFirst {
                held = completion
                heldBase = baseBuffer
            }
            lock.unlock()
            if !isFirst {
                // Later frames finish synchronously through the base layer once
                // the test has released the first slot. Ticket ordering in
                // `deliver` is what the ordering test exercises, not the hop.
                slots.signal()
                lock.lock(); completedCount += 1; lock.unlock()
                completion(baseBuffer)
            }
        }

        /// Releases the held first composition: delivers its base layer as the
        /// composed result and frees the slot.
        func releaseFirst() {
            let completion: (@Sendable (CVPixelBuffer?) -> Void)?
            let base: CVPixelBuffer?
            lock.lock()
            completion = held; base = heldBase
            held = nil; heldBase = nil
            completedCount += 1
            lock.unlock()
            if let completion {
                completion(base)
            }
            slots.signal()
        }

        func flush() {}
    }

    private static let frameTicks: Int64 = 3754
    private static func pts(_ frame: Int64) -> CMTime {
        CMTime(value: frame * frameTicks, timescale: 90000)
    }

    private static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                         [kCVPixelBufferMetalCompatibilityKey: true,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                                         &out)
        return status == kCVReturnSuccess ? out : nil
    }

    private final class Deliveries: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var points: [CMTime] = []
        private var metadata: [Data?] = []
        func record(_ buffer: CVPixelBuffer, _ pts: CMTime, _ hdr10: Data?) {
            let payload = CVBufferCopyAttachment(buffer, DoviDisplayMetadata.rpuDataKey as CFString, nil) as? Data
            lock.lock(); points.append(pts); metadata.append(payload); lock.unlock()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return points.count }
        var metadataPayloads: [Data?] { lock.lock(); defer { lock.unlock() }; return metadata }
    }

    /// Set once by a worker thread when it has finished; read by the test.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Baton-pass box: the test thread stops touching the buffer once it is
    /// handed to the background thread, mirroring the decoder's own handoff.
    private struct SendablePixelBuffer: @unchecked Sendable {
        let value: CVPixelBuffer
    }

    @Test("a second composition blocked on the GPU slot does not stall flush()")
    func blockedSlotDoesNotStallFlush() async throws {
        let bl0 = try #require(Self.makeBuffer(width: 64, height: 64))
        let el0 = try #require(Self.makeBuffer(width: 32, height: 32))
        let bl1 = try #require(Self.makeBuffer(width: 64, height: 64))
        let el1 = try #require(Self.makeBuffer(width: 32, height: 32))

        let composer = GatedFakeComposer()
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: composer)
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)
        decoder.seedRPUForTesting(pts: Self.pts(0), params: DoviMetalParams(), displayMetadataNAL: nil)
        decoder.seedRPUForTesting(pts: Self.pts(1), params: DoviMetalParams(), displayMetadataNAL: nil)

        // First pair composes and holds the only slot.
        decoder.handleEnhancementLayerFrame(elBuffer: el0, pts: Self.pts(0))
        decoder.handleBaseLayerFrame(baseBuffer: bl0, pts: Self.pts(0), hdr10Data: nil)

        // Second pair on another thread: its enhancement layer queues without
        // blocking, then its base layer matches and parks in acquireSlot().
        let bl1Box = SendablePixelBuffer(value: bl1)
        let el1Box = SendablePixelBuffer(value: el1)
        // A dedicated thread, not the global queue: other suites run concurrently and
        // can saturate GCD's pool, which starved this closure past the deadline.
        let workerDone = Flag()
        let worker = Thread {
            decoder.handleEnhancementLayerFrame(elBuffer: el1Box.value, pts: Self.pts(1))
            decoder.handleBaseLayerFrame(baseBuffer: bl1Box.value, pts: Self.pts(1), hdr10Data: nil)
            workerDone.set()
        }
        worker.start()
        // Wait until the background thread is inside the slot wait (on the
        // pre-fix code it instead holds the decoder lock here, which is what
        // made flush() hang). Then flush() must still return promptly.
        try await waitFor { composer.acquireCallCount == 2 }

        // flush() runs while the second composition is parked in `acquireSlot` and the first is held
        // by the gate. Returning at all is the proof (it would wait on the decoder lock otherwise,
        // and the suite's time limit would report the hang); no wall-clock bound is asserted.
        decoder.flush()

        // Release the held composition and let the second finish; the flush
        // retired both tickets, so neither may be delivered after it.
        composer.releaseFirst()
        try await waitFor { workerDone.isSet }
        decoder.quiesceForTesting()
        #expect(deliveries.count == 0, "frames composed before flush() must not be delivered after it")
        decoder.close()
    }

    /// The frame handlers are VideoToolbox output callbacks, and VideoToolbox can make one on the thread
    /// that submitted the frame while `HardwareVideoDecoder.lock` is held: a handler that waits for a GPU
    /// slot there stalls that session's whole output, and with it decode of both layers. Before the compose
    /// queue, the second pair's base-layer handler parked in `acquireSlot()` until the first composition
    /// retired; now it hands the composition to the queue and returns while every slot is still held.
    @Test("the VideoToolbox-side handler returns promptly while every composer slot is held")
    func handlerReturnsWhileSlotsAreHeld() async throws {
        let bl0 = try #require(Self.makeBuffer(width: 64, height: 64))
        let el0 = try #require(Self.makeBuffer(width: 32, height: 32))
        let bl1 = try #require(Self.makeBuffer(width: 64, height: 64))
        let el1 = try #require(Self.makeBuffer(width: 32, height: 32))

        let composer = GatedFakeComposer()
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: composer)
        defer { decoder.close() }
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)
        decoder.seedRPUForTesting(pts: Self.pts(0), params: DoviMetalParams(), displayMetadataNAL: nil)
        decoder.seedRPUForTesting(pts: Self.pts(1), params: DoviMetalParams(), displayMetadataNAL: nil)

        // First pair takes the only slot and holds it.
        decoder.handleEnhancementLayerFrame(elBuffer: el0, pts: Self.pts(0))
        decoder.handleBaseLayerFrame(baseBuffer: bl0, pts: Self.pts(0), hdr10Data: nil)
        try await waitFor { composer.acquireCallCount == 1 }

        // Second pair on a dedicated thread, standing in for the VideoToolbox callback.
        let bl1Box = SendablePixelBuffer(value: bl1)
        let el1Box = SendablePixelBuffer(value: el1)
        let workerDone = Flag()
        let worker = Thread {
            decoder.handleEnhancementLayerFrame(elBuffer: el1Box.value, pts: Self.pts(1))
            decoder.handleBaseLayerFrame(baseBuffer: bl1Box.value, pts: Self.pts(1), hdr10Data: nil)
            workerDone.set()
        }
        worker.start()
        // The bound is the assertion: the handlers do no waiting of their own, so a loaded machine
        // finishes them in far less; a handler parked on the slot never does until it is released.
        let returnedWhileHeld = try await waitFor(upTo: .seconds(5)) { workerDone.isSet }
        #expect(returnedWhileHeld, "the base-layer handler waited for a GPU slot on the callback thread")

        // The composition it handed off is the one now waiting for the slot.
        try await waitFor { composer.acquireCallCount == 2 }
        composer.releaseFirst()
        try await waitFor { workerDone.isSet }
        try await waitFor { deliveries.count >= 2 }
        decoder.quiesceForTesting()
        let points = deliveries.points
        #expect(points.count == 2)
        if points.count == 2 {
            #expect(CMTimeCompare(points[0], Self.pts(0)) == 0)
            #expect(CMTimeCompare(points[1], Self.pts(1)) == 0)
        }
    }

    /// A composition handed to the compose queue before a `flush()` belongs to the old feed: it must
    /// neither be delivered nor take a GPU slot once it reaches the front of the queue.
    @Test("a composition still queued when flush() runs never reaches the GPU or delivery")
    func queuedCompositionIsRetiredByFlush() async throws {
        let composer = GatedFakeComposer()
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: composer)
        defer { decoder.close() }
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)
        for i in 0...2 {
            decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: DoviMetalParams(), displayMetadataNAL: nil)
        }
        let pairs = try (0...2).map { _ -> (SendablePixelBuffer, SendablePixelBuffer) in
            let bl = try #require(Self.makeBuffer(width: 64, height: 64))
            let el = try #require(Self.makeBuffer(width: 32, height: 32))
            return (SendablePixelBuffer(value: bl), SendablePixelBuffer(value: el))
        }
        let workerDone = Flag()
        let worker = Thread {
            for (i, pair) in pairs.enumerated() {
                decoder.handleEnhancementLayerFrame(elBuffer: pair.1.value, pts: Self.pts(Int64(i)))
                decoder.handleBaseLayerFrame(baseBuffer: pair.0.value, pts: Self.pts(Int64(i)), hdr10Data: nil)
            }
            workerDone.set()
        }
        worker.start()
        // Frame 0 holds the slot, frame 1 waits for it on the compose queue, frame 2 is queued behind.
        // Bounded, so a handler that parks on the slot itself fails here instead of hanging the suite.
        let queued = try await waitFor(upTo: .seconds(5)) { workerDone.isSet && composer.acquireCallCount == 2 }
        #expect(queued, "the handlers waited for a GPU slot on the callback thread")
        guard queued else {
            composer.releaseFirst()
            try await waitFor { workerDone.isSet }
            return
        }
        decoder.flush()
        composer.releaseFirst()
        decoder.quiesceForTesting()
        #expect(deliveries.count == 0, "frames composed or queued before flush() must not be delivered after it")
        #expect(composer.acquireCallCount == 2, "a composition queued before flush() must not take a GPU slot")
    }

    /// The callback threads no longer absorb GPU backpressure, so the feed does: with
    /// `maxComposesAwaitingSlot` compositions queued behind a held slot, `decode(packet:)`'s wait holds
    /// the demux thread until the backlog drains.
    @Test("the feed waits while the compose backlog is full, and resumes once it drains")
    func feedWaitsOnComposeBacklog() async throws {
        let composer = GatedFakeComposer()
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: composer)
        defer { decoder.close() }
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)
        let backlog = DualLayerVideoDecoder.maxComposesAwaitingSlot
        for i in 0...backlog {
            decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: DoviMetalParams(), displayMetadataNAL: nil)
        }
        // Frame 0 holds the only slot; the next `backlog` frames queue behind it.
        for i in 0...backlog {
            let bl = try #require(Self.makeBuffer(width: 64, height: 64))
            let el = try #require(Self.makeBuffer(width: 32, height: 32))
            decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }
        try await waitFor { composer.acquireCallCount == 2 }

        let feedDone = Flag()
        let feeder = Thread {
            decoder.waitForComposeBacklog()
            feedDone.set()
        }
        feeder.start()
        // The bound is the assertion, and it can only err towards passing: the wait cannot end while the
        // slot is held (short of the 2 s stall report), however late the thread starts.
        let endedWhileFull = try await waitFor(upTo: .milliseconds(200)) { feedDone.isSet }
        #expect(!endedWhileFull, "the feed did not wait for a full compose backlog")

        composer.releaseFirst()
        try await waitFor { feedDone.isSet }
        try await waitFor { deliveries.count == backlog + 1 }
        decoder.quiesceForTesting()
        #expect(deliveries.count == backlog + 1)
    }

    /// Frame 0 holds the only slot and `maxComposesAwaitingSlot` more queue behind it: the backlog is full.
    private func fillComposeBacklog(_ decoder: DualLayerVideoDecoder, _ composer: GatedFakeComposer) async throws {
        decoder.primeForTesting(enhancementLayer: true)
        let backlog = DualLayerVideoDecoder.maxComposesAwaitingSlot
        for i in 0...backlog {
            decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: DoviMetalParams(), displayMetadataNAL: nil)
        }
        for i in 0...backlog {
            let bl = try #require(Self.makeBuffer(width: 64, height: 64))
            let el = try #require(Self.makeBuffer(width: 32, height: 32))
            decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }
        try await waitFor { composer.acquireCallCount == 2 }
    }

    /// A seek must not wait for the GPU: `flush()` wakes a feed parked on the full backlog at once,
    /// where it used to sit out a fixed 0.5 s.
    @Test("flush() releases a feed waiting on a full compose backlog at once")
    func flushReleasesBacklogWaiter() async throws {
        let composer = GatedFakeComposer()
        let decoder = DualLayerVideoDecoder(composer: composer)
        defer { composer.releaseFirst(); decoder.close() }
        decoder.onFrame = { _, _, _ in }
        try await fillComposeBacklog(decoder, composer)

        let feedDone = Flag()
        let feeder = Thread {
            decoder.waitForComposeBacklog()
            feedDone.set()
        }
        feeder.start()
        let early = try await waitFor(upTo: .milliseconds(150)) { feedDone.isSet }
        #expect(!early, "the feed did not wait for a full compose backlog")
        let started = CFAbsoluteTimeGetCurrent()
        let flusher = Thread { decoder.flush() }
        flusher.start()
        try await waitFor { feedDone.isSet }
        // Well under the stall timeout; the old cap was 0.5 s.
        #expect(CFAbsoluteTimeGetCurrent() - started < 0.4)
    }

    /// A GPU whose work never completes: the backlog stands full, and after `composeStallTimeout` the
    /// stall is reported once and the feed refused from then on, so nothing more is decoded and queued.
    /// Before, the feed went on after 0.5 s per packet and the queued buffers grew without bound.
    @Test("a GPU that never completes is reported once as a stall, and the feed is refused after it",
          .timeLimit(.minutes(1)))
    func stalledComposerIsReportedAndRefused() async throws {
        let composer = GatedFakeComposer()
        let decoder = DualLayerVideoDecoder(composer: composer)
        defer { composer.releaseFirst(); decoder.close() }
        decoder.onFrame = { _, _, _ in }
        let reportCount = Flag()
        let errors = ErrorBox()
        decoder.onFatalDecodeError = { error in errors.record(error); reportCount.set() }
        try await fillComposeBacklog(decoder, composer)

        let started = CFAbsoluteTimeGetCurrent()
        let result = ResultBox()
        let feeder = Thread { result.set(decoder.waitForComposeBacklog()) }
        feeder.start()
        try await waitFor { result.value != nil }
        let waited = CFAbsoluteTimeGetCurrent() - started
        #expect(result.value == false)
        #expect(waited >= DualLayerVideoDecoder.composeStallTimeout - 0.1, "reported after \(waited) s")
        #expect(reportCount.isSet)
        if case .composerStalled? = errors.first as? VideoDecoderError {} else {
            Issue.record("expected composerStalled, got \(String(describing: errors.first))")
        }
        // Every later packet is refused at once, and the stall is not reported again.
        let again = CFAbsoluteTimeGetCurrent()
        #expect(decoder.waitForComposeBacklog() == false)
        #expect(CFAbsoluteTimeGetCurrent() - again < 0.05)
        #expect(errors.count == 1)
        #expect(composer.acquireCallCount == 2, "nothing more reached the GPU")
    }

    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var errors: [Error] = []
        func record(_ e: Error) { lock.lock(); errors.append(e); lock.unlock() }
        var first: Error? { lock.lock(); defer { lock.unlock() }; return errors.first }
        var count: Int { lock.lock(); defer { lock.unlock() }; return errors.count }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?
        func set(_ v: Bool) { lock.lock(); stored = v; lock.unlock() }
        var value: Bool? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    @Test("a frame with no usable RPU borrows the previous frame's parameters, but only for a short run")
    func missingRpuBorrowsPreviousParameters() async throws {
        let composer = GatedFakeComposer()
        let decoder = DualLayerVideoDecoder(composer: composer)
        decoder.onFrame = { _, _, _ in }
        decoder.primeForTesting(enhancementLayer: true)
        let limit = DualLayerVideoDecoder.maxBorrowedParamsRun
        // Packets in decode order: frame 0 has a real RPU, every later one has none.
        decoder.seedRPUForTesting(pts: Self.pts(0), params: DoviMetalParams(), displayMetadataNAL: nil)
        for i in 1...(limit + 1) {
            decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: nil, displayMetadataNAL: nil)
        }
        let box = try (0...(limit + 1)).map { _ -> (SendablePixelBuffer, SendablePixelBuffer) in
            let bl = try #require(Self.makeBuffer(width: 64, height: 64))
            let el = try #require(Self.makeBuffer(width: 32, height: 32))
            return (SendablePixelBuffer(value: bl), SendablePixelBuffer(value: el))
        }
        let workerDone = Flag()
        let worker = Thread {
            for (i, pair) in box.enumerated() {
                decoder.handleEnhancementLayerFrame(elBuffer: pair.1.value, pts: Self.pts(Int64(i)))
                decoder.handleBaseLayerFrame(baseBuffer: pair.0.value, pts: Self.pts(Int64(i)), hdr10Data: nil)
            }
            workerDone.set()
        }
        worker.start()
        // Frame 0 holds the only slot. Frame 1 borrows and parks in acquireSlot (count 2). Frames after
        // the borrow limit must bypass instead of reaching the composer.
        try await waitFor { composer.acquireCallCount == 2 }
        composer.releaseFirst()
        try await waitFor { workerDone.isSet }
        // The handlers hand compositions to the compose queue and return: wait for the queue too.
        decoder.quiesceForTesting()
        #expect(composer.acquireCallCount == 1 + limit)
        decoder.close()
    }

    @Test("borrowed parameters carry display metadata only within the borrow limit, and flush clears it")
    func missingRpuBorrowsPreviousDisplayMetadata() async throws {
        let composer = GatedFakeComposer()
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: composer)
        defer { decoder.close() }
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)
        let nal: [UInt8] = [0x7C, 0x01, 0x19, 0x42, 0x03]
        let payload = Data(nal.dropFirst(2))
        let limit = DualLayerVideoDecoder.maxBorrowedParamsRun
        decoder.seedRPUForTesting(pts: Self.pts(0), params: DoviMetalParams(), displayMetadataNAL: nal)
        for i in 1...(limit + 1) {
            decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: nil, displayMetadataNAL: nil)
        }

        for i in 0...(limit + 1) {
            let bl = try #require(Self.makeBuffer(width: 64, height: 64))
            let el = try #require(Self.makeBuffer(width: 32, height: 32))
            let pts = Self.pts(Int64(i))
            if i.isMultiple(of: 2) {
                decoder.handleEnhancementLayerFrame(elBuffer: el, pts: pts)
                decoder.handleBaseLayerFrame(baseBuffer: bl, pts: pts, hdr10Data: nil)
            } else {
                decoder.handleBaseLayerFrame(baseBuffer: bl, pts: pts, hdr10Data: nil)
                decoder.handleEnhancementLayerFrame(elBuffer: el, pts: pts)
            }
            if i == 0 { composer.releaseFirst() }
        }
        try await waitFor { deliveries.count >= limit + 2 }
        #expect(deliveries.metadataPayloads == Array(repeating: Optional(payload), count: limit + 1) + [nil])
        #expect(composer.acquireCallCount == 1 + limit)

        decoder.seedRPUForTesting(pts: Self.pts(10), params: DoviMetalParams(), displayMetadataNAL: nal)
        let bl = try #require(Self.makeBuffer(width: 64, height: 64))
        let el = try #require(Self.makeBuffer(width: 32, height: 32))
        decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(10), hdr10Data: nil)
        decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(10))
        try await waitFor { deliveries.count >= limit + 3 }
        #expect(deliveries.count == limit + 3)
        decoder.flush()
        for i in 11...12 {
            decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: nil, displayMetadataNAL: nil)
            let bl = try #require(Self.makeBuffer(width: 64, height: 64))
            let el = try #require(Self.makeBuffer(width: 32, height: 32))
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
            decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
        }
        try await waitFor { deliveries.count >= limit + 5 }
        #expect(deliveries.metadataPayloads == Array(repeating: Optional(payload), count: limit + 1) + [nil, payload, nil, nil])
        #expect(composer.acquireCallCount == 2 + limit)
    }

    @Test("ordering still holds across two gated compositions")
    func gatedCompositionsDeliverInOrder() async throws {
        let bl0 = try #require(Self.makeBuffer(width: 64, height: 64))
        let el0 = try #require(Self.makeBuffer(width: 32, height: 32))
        let bl1 = try #require(Self.makeBuffer(width: 64, height: 64))
        let el1 = try #require(Self.makeBuffer(width: 32, height: 32))

        let composer = GatedFakeComposer()
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: composer)
        defer { decoder.close() }
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)
        decoder.seedRPUForTesting(pts: Self.pts(0), params: DoviMetalParams(), displayMetadataNAL: nil)
        decoder.seedRPUForTesting(pts: Self.pts(1), params: DoviMetalParams(), displayMetadataNAL: nil)

        decoder.handleEnhancementLayerFrame(elBuffer: el0, pts: Self.pts(0))
        decoder.handleBaseLayerFrame(baseBuffer: bl0, pts: Self.pts(0), hdr10Data: nil)
        // Second composition blocks on the held slot on another thread.
        let bl1Box = SendablePixelBuffer(value: bl1)
        let el1Box = SendablePixelBuffer(value: el1)
        // A dedicated thread, not the global queue: other suites run concurrently and
        // can saturate GCD's pool, which starved this closure past the deadline.
        let worker = Thread {
            decoder.handleEnhancementLayerFrame(elBuffer: el1Box.value, pts: Self.pts(1))
            decoder.handleBaseLayerFrame(baseBuffer: bl1Box.value, pts: Self.pts(1), hdr10Data: nil)
        }
        worker.start()
        try await waitFor { composer.acquireCallCount == 2 }
        composer.releaseFirst()

        try await waitFor { deliveries.count >= 2 }
        #expect(deliveries.count == 2)
        let points = deliveries.points
        if points.count == 2 {
            #expect(CMTimeCompare(points[0], Self.pts(0)) == 0)
            #expect(CMTimeCompare(points[1], Self.pts(1)) == 0)
        }
    }
}
#endif
