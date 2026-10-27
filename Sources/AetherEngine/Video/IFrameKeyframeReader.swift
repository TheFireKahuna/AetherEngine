// Sources/AetherEngine/Video/IFrameKeyframeReader.swift
import Foundation
import AetherLibavcodec

/// AE#682: reads the keyframe that opens an I-frame entry. Only the bytes are used; the fragment is
/// stamped from the plan, so no reader's timestamp ladder (DTS on mp4, PTS on Matroska, the #409
/// shift) has to agree with the session's.
///
/// Two ways to read one, by what the source's index covers, settled at the first request:
///
/// - The index (`SourceIndex`: Matroska's Cues, an MP4's sample entries) places each keyframe, which
///   is read exactly, at the position libavformat's own index gave the segment plan, through the bytes
///   the source cache already shares. No demuxer.
/// - Any other container (AVI, FLV, ASF, MPEG-TS, a disc title, ...) wraps its packets in framing only
///   libavformat takes apart (a chunk header, a tag, a multiplexed payload), so a demuxer of its own reads
///   the keyframe there, seeking to its time over exact range reads of the source. A disc title seeks by
///   its EP maps or its time map; a transport or program stream by a timestamp search, bounded by the
///   keyframes the session's pump has already read (`knownKeyframes`).
///
/// An index that could not be read is a failed request, not the other way: it is asked again after
/// the cool-down. Either way the packet gets the P7 conversion the playing samples get.
///
/// A dense still (a source with no keyframe list, `pictureRun`) is the picture at a time rather than a
/// keyframe: the packets from the keyframe at or before it to that picture, for the still builder to decode.
final class IFrameKeyframeReader: @unchecked Sendable {

    /// The packets that end on the picture a dense still shows, in decode order: from the keyframe at or
    /// before the still's time on, up to the first picture at or after it (`targetPts`), and far enough past
    /// it that no later packet can present between the two.
    struct PictureRun: Sendable {
        struct Packet: Sendable {
            let data: Data
            let pts: Int64
            let dts: Int64
            let isKeyframe: Bool
        }
        let packets: [Packet]
        let targetPts: Int64
    }

    /// A source whose index places its keyframes.
    struct IndexedSource {
        let index: any SourceIndex
        let track: UInt64
        /// The exact reads, closed with the reader.
        let bytes: IOReaderByteSource
        /// Aborts a read in flight.
        let cancel: () -> Void
    }

    /// What the index says about this source's keyframes.
    enum Resolution {
        case indexed(IndexedSource)
        /// The container's keyframes are libavformat's to read; why, for the log.
        case notIndexed(String)
        /// The index could not be read this time.
        case failed(String)
    }

    private enum Route {
        case index(IndexedSource)
        case demuxer
    }

    private let resolveIndex: @Sendable () async -> Resolution
    private let position: (Int64) -> Int64?
    private let open: (Demuxer) throws -> (@Sendable () -> Void)
    private let knownKeyframes: () -> [DemuxedSampleTable.Entry]
    private let cleanup: () -> Void
    private let convertP7ToProfile81: Bool
    private let nalFraming: VideoNALFraming
    private let readDeadlineSeconds: TimeInterval
    private let now: () -> Date

    private let lock = NSLock()
    /// One request at a time, whoever asks (the I-frame rendition, the compositor preview, a scrub still): a
    /// demuxer route's seek and the reads after it belong to one request. Not taken by `interrupt()`.
    private let requestLock = NSLock()
    private var route: Route?
    private var resolving = false
    private var delivered: Resolution?
    private var demuxer: Demuxer?
    /// Closes what the open read the demuxer through.
    private var closeSource: (@Sendable () -> Void)?
    private var isOpen = false
    /// Recorded keyframes already added to the demuxer's index, by decode time.
    private var adoptedKeyframes: Set<Int64> = []
    private var videoIndex: Int32 = -1
    private var interrupted = false
    private var cleanedUp = false
    private var consecutiveFailures = 0
    private var blockedUntil = Date.distantPast

    /// A keyframe sits at the seek target or right behind it; this bounds a source that claims an
    /// index entry no keyframe backs.
    private static let maxPacketsPerRead = 256
    /// A picture run spans at most a GOP and its reorder tail: ten seconds at 60 frames.
    private static let maxPacketsPerRun = 640

    /// How long the reader refuses to touch the source after a failed open or read. Requests are
    /// served one at a time and AVKit sends five at once, so without this a stalled connection
    /// answers them a full read deadline apart; with it they fall through to a cached neighbour.
    static func coolDownSeconds(afterConsecutiveFailures failures: Int) -> TimeInterval {
        failures <= 1 ? 5 : 30
    }

    /// `resolveIndex` says whether the source's index places its keyframes, asked at the first request
    /// and again after one that failed. `position` is libavformat's index position for a plan
    /// keyframe's time. `open` opens the demuxer route's demuxer, and receives one that `interrupt()`
    /// can already reach, so a slow open is abortable; it hands back what closes the source it opened.
    /// `knownKeyframes` are the keyframes the session's own demuxer has read, adopted into the demuxer
    /// route's index before each seek. `cleanup` runs once, from `close()`, whether or not anything was
    /// ever opened.
    init(resolveIndex: @escaping @Sendable () async -> Resolution,
         position: @escaping (Int64) -> Int64?,
         open: @escaping (Demuxer) throws -> (@Sendable () -> Void),
         knownKeyframes: @escaping () -> [DemuxedSampleTable.Entry] = { [] },
         cleanup: @escaping () -> Void = {},
         convertP7ToProfile81: Bool = false,
         nalFraming: VideoNALFraming = .lengthPrefixed(size: 4),
         readDeadlineSeconds: TimeInterval = 8,
         now: @escaping () -> Date = Date.init) {
        self.resolveIndex = resolveIndex
        self.position = position
        self.open = open
        self.knownKeyframes = knownKeyframes
        self.cleanup = cleanup
        self.convertP7ToProfile81 = convertP7ToProfile81
        self.nalFraming = nalFraming
        self.readDeadlineSeconds = readDeadlineSeconds
        self.now = now
    }

    /// Whether the keyframes come from the index; nil until the first resolution answered.
    var readsFromIndex: Bool? {
        lock.lock(); defer { lock.unlock() }
        switch route {
        case .index?: return true
        case .demuxer?: return false
        case nil: return nil
        }
    }

    private var isInterrupted: Bool {
        lock.lock(); defer { lock.unlock() }
        return interrupted
    }

    func payload(startPts: Int64) -> Data? {
        requestLock.lock()
        defer { requestLock.unlock() }
        lock.lock()
        let held = interrupted || now() < blockedUntil
        lock.unlock()
        if held { return nil }
        guard let route = readyRoute() else { return nil }
        let packet: UnsafeMutablePointer<AVPacket>?
        switch route {
        case .index(let source):
            packet = read(source, startPts: startPts)
        case .demuxer:
            // A failed open has counted itself.
            guard let dem = readyDemuxer() else { return nil }
            packet = read(dem, startPts: startPts)
        }
        if let packet {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { av_packet_free(&owned) }
            if convertP7ToProfile81 {
                _ = DoviRpuConverter.convertPacketToProfile81(packet, framing: nalFraming)
            }
            if let bytes = packet.pointee.data, packet.pointee.size > 0 {
                lock.lock(); consecutiveFailures = 0; lock.unlock()
                return Data(bytes: bytes, count: Int(packet.pointee.size))
            }
        }
        guard !isInterrupted else { return nil }
        // The session treats a demuxer whose read failed as suspect-dead and reopens; so does this.
        if case .demuxer = route, let dem = lockedDemuxer() { drop(dem) }
        noteFailure("read failed at pts=\(startPts)")
        return nil
    }

    // MARK: - Route

    /// The route, settled by the first resolution that answers. Asked on the reading thread, which
    /// waits for it in slices so `interrupt()` ends the wait. Nothing else does: the resolution's reads
    /// carry their own deadlines, and a parse that is slow but moving would only be asked again.
    private func readyRoute() -> Route? {
        lock.lock()
        if let route { lock.unlock(); return route }
        if !resolving, delivered == nil {
            resolving = true
            let resolve = resolveIndex
            BlockingWork.detached(priority: .userInitiated) { [weak self] in
                let resolution = await resolve()
                self?.deliver(resolution)
            }
        }
        lock.unlock()
        let started = DispatchTime.now()
        var answer: Resolution?
        while answer == nil {
            lock.lock()
            answer = delivered
            delivered = nil
            let stop = interrupted
            lock.unlock()
            if stop { return nil }
            if answer != nil { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let resolved: Route
        let line: String
        switch answer {
        case .indexed(let source)?:
            resolved = .index(source)
            line = "keyframes read from the index (track \(source.track))"
        case .notIndexed(let reason)?:
            resolved = .demuxer
            line = "keyframes read by a demuxer of their own: \(reason)"
        case .failed(let reason)?:
            noteFailure("index unreadable: \(reason)")
            return nil
        case nil:
            return nil
        }
        lock.lock()
        route = resolved
        lock.unlock()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        EngineLog.emit("[IFrameKeyframes] \(line) (\(String(format: "%.0f", ms))ms)", category: .session)
        return resolved
    }

    /// A resolution's answer, kept for the request waiting on it; closed instead once the reader is
    /// interrupted, since nothing will read through it.
    private func deliver(_ resolution: Resolution) {
        lock.lock()
        resolving = false
        guard !interrupted else {
            lock.unlock()
            if case .indexed(let source) = resolution { source.bytes.close() }
            return
        }
        delivered = resolution
        lock.unlock()
    }

    // MARK: - The index route

    /// The keyframe the index places at the plan keyframe's position, as a packet.
    private func read(_ source: IndexedSource, startPts: Int64) -> UnsafeMutablePointer<AVPacket>? {
        guard let position = position(startPts),
              let bytes = source.index.readKeyframe(track: source.track, position: position, ticks: startPts,
                                                    from: source.bytes),
              !bytes.isEmpty, !isInterrupted,
              let packet = av_packet_alloc() else { return nil }
        guard av_new_packet(packet, Int32(bytes.count)) == 0, let data = packet.pointee.data else {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&owned)
            return nil
        }
        bytes.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: bytes.count) }
        return packet
    }

    // MARK: - The demuxer route

    private func lockedDemuxer() -> Demuxer? {
        lock.lock(); defer { lock.unlock() }
        return demuxer
    }

    private func drop(_ dem: Demuxer) {
        lock.lock()
        var closer: (@Sendable () -> Void)?
        if demuxer === dem {
            demuxer = nil
            isOpen = false
            closer = closeSource
            closeSource = nil
            adoptedKeyframes = []
        }
        lock.unlock()
        dem.markClosed()
        dem.close()
        closer?()
    }

    private func noteFailure(_ what: String) {
        lock.lock()
        guard !interrupted else { lock.unlock(); return }
        consecutiveFailures += 1
        let coolDown = Self.coolDownSeconds(afterConsecutiveFailures: consecutiveFailures)
        blockedUntil = now().addingTimeInterval(coolDown)
        let failures = consecutiveFailures
        lock.unlock()
        EngineLog.emit("[IFrameKeyframes] \(what); leaving the source alone for "
                       + "\(Int(coolDown))s (consecutive failures: \(failures))", category: .session)
    }

    private func readyDemuxer() -> Demuxer? {
        lock.lock()
        if interrupted { lock.unlock(); return nil }
        if let demuxer, isOpen { lock.unlock(); return demuxer }
        let dem = Demuxer()
        demuxer = dem
        lock.unlock()

        let started = DispatchTime.now()
        do {
            let closer = try open(dem)
            lock.lock()
            if demuxer === dem { closeSource = closer } else { lock.unlock(); closer(); return nil }
            lock.unlock()
        } catch {
            drop(dem)
            noteFailure("open failed: \(error)")
            return nil
        }
        let index = dem.videoStreamIndex
        guard index >= 0 else {
            drop(dem)
            noteFailure("open failed: no video stream")
            return nil
        }
        dem.discardAllStreamsExcept([index])
        lock.lock()
        if interrupted {
            lock.unlock()
            drop(dem)
            return nil
        }
        isOpen = true
        videoIndex = index
        lock.unlock()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        EngineLog.emit("[IFrameKeyframes] demuxer opened in \(String(format: "%.0f", ms))ms", category: .session)
        return dem
    }

    /// The keyframes the session's demuxer has read since the last seek, added to this one's index so the
    /// seek is bounded by them.
    private func adoptKnownKeyframes(_ dem: Demuxer) {
        let known = knownKeyframes()
        lock.lock()
        let fresh = known.filter { !adoptedKeyframes.contains($0.timestamp) }
        adoptedKeyframes.formUnion(fresh.map(\.timestamp))
        lock.unlock()
        if !fresh.isEmpty { dem.adoptRecordedKeyframes(fresh, streamIndex: videoIndex) }
    }

    /// Positions `dem` for a read at `startPts` on the video stream's axis: at or before it, a disc title by
    /// its maps.
    private func position(_ dem: Demuxer, at startPts: Int64, atOrBefore: Bool) -> Bool {
        adoptKnownKeyframes(dem)
        if !dem.isDiscSource, dem.seek(to: startPts, streamIndex: videoIndex, atOrBefore: atOrBefore) { return true }
        guard let stream = dem.stream(at: videoIndex) else { return false }
        let tb = stream.pointee.time_base
        return tb.den > 0 && dem.seek(to: Double(startPts) * Double(tb.num) / Double(tb.den))
    }

    /// The first keyframe at or after the seek to `startPts`. A failed open already counted itself.
    private func read(_ dem: Demuxer, startPts: Int64) -> UnsafeMutablePointer<AVPacket>? {
        dem.beginReadDeadline(secondsFromNow: readDeadlineSeconds)
        defer { dem.endReadDeadline() }
        guard position(dem, at: startPts, atOrBefore: false) else { return nil }
        for _ in 0..<Self.maxPacketsPerRead {
            if isInterrupted { return nil }
            guard let packet = try? dem.readPacket() else { return nil }
            guard packet.pointee.stream_index == videoIndex,
                  (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0 else {
                var owned: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&owned)
                continue
            }
            return packet
        }
        return nil
    }

    // MARK: - Dense stills

    /// The packets from the keyframe at or before `targetPts` to the first picture at or after it, read by
    /// the demuxer route. The read stops once a packet's decode time reaches that picture's time: every
    /// later packet presents at or after its own decode time, so none can come between. nil on a failure,
    /// which counts toward the cool-down as a keyframe's does.
    func pictureRun(atPts targetPts: Int64) -> PictureRun? {
        requestLock.lock()
        defer { requestLock.unlock() }
        lock.lock()
        let held = interrupted || now() < blockedUntil
        lock.unlock()
        if held { return nil }
        guard readyRoute() != nil, let dem = readyDemuxer() else { return nil }
        if let run = readRun(dem, targetPts: targetPts) {
            lock.lock(); consecutiveFailures = 0; lock.unlock()
            return run
        }
        guard !isInterrupted else { return nil }
        drop(dem)
        noteFailure("picture read failed at pts=\(targetPts)")
        return nil
    }

    /// How far before a still's time the first positioning reads, doubled for each one that lands past the
    /// keyframe the picture needs, in seconds: a timestamp search lands near a time, not on a keyframe.
    static let runBackoffSeconds: [Double] = [1, 2, 4, 8, 16]

    /// A recorded keyframe at or before the target opens the run where it begins, if it is no further back
    /// than a GOP is long; otherwise the run is positioned a little before the target, further each time the
    /// first keyframe read turns out to be past it.
    private func readRun(_ dem: Demuxer, targetPts: Int64) -> PictureRun? {
        dem.beginReadDeadline(secondsFromNow: readDeadlineSeconds)
        defer { dem.endReadDeadline() }
        adoptKnownKeyframes(dem)
        guard let stream = dem.stream(at: videoIndex) else { return nil }
        let tb = stream.pointee.time_base
        guard tb.num > 0, tb.den > 0 else { return nil }
        let ticksPerSecond = Double(tb.den) / Double(tb.num)
        let reach = Int64((Self.runBackoffSeconds.last ?? 16) * ticksPerSecond)
        if !dem.isDiscSource,
           let keyframe = dem.recordedKeyframes(streamIndex: videoIndex)
               .last(where: { $0.timestamp <= targetPts && targetPts - $0.timestamp <= reach }),
           dem.seek(toRecordedKeyframeAt: keyframe.pos),
           case .run(let run) = collectRun(dem, targetPts: targetPts) {
            return run
        }
        for backoff in Self.runBackoffSeconds {
            if isInterrupted { return nil }
            let from = targetPts - Int64(backoff * ticksPerSecond)
            guard position(dem, at: from, atOrBefore: true) else { return nil }
            switch collectRun(dem, targetPts: targetPts) {
            case .run(let run): return run
            case .openedPastTarget: continue
            case .failed: return nil
            }
        }
        return nil
    }

    private enum RunRead {
        case run(PictureRun)
        /// The first keyframe read was already past the target: position further back.
        case openedPastTarget
        case failed
    }

    /// Reads from where `dem` stands: from its first keyframe on, up to the first picture at or after
    /// `targetPts` and on until a packet's decode time reaches it.
    private func collectRun(_ dem: Demuxer, targetPts: Int64) -> RunRead {
        var packets: [PictureRun.Packet] = []
        var target: Int64?
        for _ in 0..<Self.maxPacketsPerRun {
            if isInterrupted { return .failed }
            guard let packet = try? dem.readPacket() else { break }
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { av_packet_free(&owned) }
            guard packet.pointee.stream_index == videoIndex, let data = packet.pointee.data,
                  packet.pointee.size > 0 else { continue }
            let isKeyframe = packet.pointee.flags & AV_PKT_FLAG_KEY != 0
            // A run opens on a keyframe; whatever the seek landed before one is not decodable from here.
            if packets.isEmpty, !isKeyframe { continue }
            let pts = packet.pointee.pts, dts = packet.pointee.dts == Int64.min ? pts : packet.pointee.dts
            if packets.isEmpty, dts != Int64.min, dts > targetPts { return .openedPastTarget }
            // A later keyframe still at or before the target opens the run instead: the pictures that
            // lean on the one before it present before it, so none of them can be the target.
            if isKeyframe, target == nil, pts != Int64.min, pts <= targetPts { packets.removeAll() }
            packets.append(.init(data: Data(bytes: data, count: Int(packet.pointee.size)), pts: pts, dts: dts,
                                 isKeyframe: isKeyframe))
            if pts != Int64.min, pts >= targetPts { target = min(target ?? pts, pts) }
            if let target, dts != Int64.min, dts >= target { break }
        }
        guard let target, !packets.isEmpty else { return .failed }
        return .run(PictureRun(packets: packets, targetPts: target))
    }

    // MARK: - Lifetime

    /// Any thread. Aborts a resolution, an open or a read in flight and makes every later call
    /// answer nil.
    func interrupt() {
        lock.lock()
        interrupted = true
        let dem = demuxer
        let route = route
        lock.unlock()
        dem?.markClosed()
        if case .index(let source) = route { source.cancel() }
    }

    /// The reading thread, after `interrupt()`.
    func close() {
        lock.lock()
        let dem = demuxer
        demuxer = nil
        isOpen = false
        let closer = closeSource
        closeSource = nil
        let route = route
        let unread = delivered
        delivered = nil
        let runCleanup = !cleanedUp
        cleanedUp = true
        lock.unlock()
        dem?.close()
        closer?()
        if case .indexed(let source)? = unread { source.bytes.close() }
        if runCleanup {
            if case .index(let source) = route { source.bytes.close() }
            cleanup()
        }
    }
}
