import Foundation
import AetherLibavcodec
import AetherLibavutil

/// The session's one reader of its embedded subtitle streams. Every consumer that wants subtitle packets
/// ahead of the pump states how far ahead it wants them (`demand`); the source reads to the furthest of
/// those leads and no further, and stops reading when nobody wants anything.
///
/// Each stream is read one of two ways, settled once per session (`Route`):
///
/// - **The index** (`SourceIndex`, through `SourceIndexRegistry`): a stream the container lists in full,
///   in a codec whose frame is its packet, is read exactly where the index places each frame. Its text
///   rendition's cue store is filled whole as soon as the route is known, which is what AVKit needs (it
///   reads a rendition minutes ahead and keeps what it gets), and its packets reach the packet store as
///   the lead asks.
/// - **The walk**: every other stream, read by one side demuxer for all of them, which harvests into the
///   packet store and decodes each text stream into its cue store as it goes.
///
/// One loop reads both (`SubtitleForwardPrefetcher.CompositeSource`), so the session has one park, one
/// anchor and one coverage frontier. The consumers are the overlay drainer and the OCR worker, which read
/// the packet store, and the native text renditions, which read their cue stores. The pump keeps its own
/// tap; this is everything ahead of it.
@MainActor
final class SubtitleSource {

    /// Who has asked for packets ahead of the playhead. Each holds a lead; the loop reads to the furthest.
    enum Consumer: String, Sendable, CaseIterable {
        /// The overlay drainer's window plus its margin (#151, #362).
        case overlay
        /// The OCR worker's window, which AVKit's own look-ahead can stretch.
        case ocr
        /// A native text rendition the host selected.
        case rendition
        /// The forced rendition the player asked for by itself (`LoadOptions.forcedSubtitleTrack`).
        case forcedRendition
    }

    /// How one stream is read.
    enum Route: Hashable, Sendable {
        case indexed(track: UInt64)
        case walked
    }

    /// What the session gives the source. Its closures run on the main actor; its stores lock themselves.
    struct Host: @unchecked Sendable {
        let url: URL
        /// The load's headers. The session's live ones (`headerStore`) go over them on every request.
        let headers: [String: String]
        let headerStore: RequestHeaderStore?
        /// A clone of a host-provided source per reader; nil for a URL source.
        let customReader: (@MainActor @Sendable () -> IOReader?)?
        let formatHint: String?
        let probesize: Int64?
        let maxAnalyzeDuration: Int64?
        let discTitleID: Int?
        let isLive: Bool
        let packetStore: SubtitlePacketStore
        /// Each text stream's native rendition store, by stream index.
        let cueStores: [Int32: NativeSubtitleCueStore]
        /// The session's own demuxer, which lists the streams and names the index. Nil reads every stream
        /// by the walk.
        let demuxer: Demuxer?
        /// A decoder for a stream, made as the overlay's are, so a cue reads the same whichever reader
        /// decoded it.
        let makeDecoder: @MainActor @Sendable (Int32) -> EmbeddedSubtitleDecoder?
        /// The playhead on the source axis; nil once the engine is gone.
        let playhead: @MainActor @Sendable () -> Double?
        let duration: @MainActor @Sendable () -> Double
        /// A producer restart is executing (#93): a walk opened now would compete with it for the link.
        let videoRestarting: @MainActor @Sendable () -> Bool
        let linkGate: SideReaderLinkGate
        let fence: @MainActor @Sendable () -> SubtitleResolutionStatement.Fence
        let cuesArrived: @MainActor @Sendable () -> Void
        let endOfFile: @MainActor @Sendable () -> Void
        /// The reading stopped because nobody asks any more, with the reason the last consumer gave.
        let stopped: @MainActor @Sendable (SubtitleDrainStopReason?) -> Void
    }

    let host: Host
    private let leads = Leads()
    private var resolution: Task<Resolution, Never>!
    private var wholeFill: Task<Void, Never>?
    private var loop: (task: Task<Void, Never>, generation: Int)?
    private var loopGeneration = 0
    /// The running session's in-place anchor box (#240); nil while a session is opening.
    private var reanchor: SubtitleForwardPrefetcher.SideReaderReanchor?
    /// A move asked for while the session was still opening, taken when it adopts its box.
    private var pendingMove: SubtitleForwardPrefetcher.SideReaderReanchor.Anchor?
    /// The walk's side demuxer, so teardown can end a parked read (`markClosed`) and diagnostics can see it.
    private(set) var walkDemuxer: Demuxer?
    private var closed = false
    private var stopPending = false
    private var stopReason: SubtitleDrainStopReason?

    init(host: Host) {
        self.host = host
        let indexable = !host.isLive && host.discTitleID == nil && host.demuxer != nil
        let inputs = ResolutionInputs(url: host.url, headers: Self.requestHeaders(host), demuxer: host.demuxer,
                                      indexable: indexable, customClone: host.customReader?())
        let resolving = BlockingWork.detached(priority: .utility) { await Self.resolve(inputs) }
        resolution = resolving
        wholeFill = BlockingWork.detached(priority: .utility) { [host] in
            await Self.fillIndexedRenditions(await resolving.value, host: host)
        }
    }

    /// Whether the loop is running.
    var isReading: Bool { loop != nil }

    /// The routes, once settled.
    func routes() async -> [Int32: Route] { await resolution.value.routes }

    /// `consumer` wants packets to `lead(playhead)` seconds past the playhead. Starts the loop at `anchor`
    /// (the playhead when nil) if it is not running; a running loop moves to `anchor` in place when one is
    /// given, and otherwise reads on to the raised lead without a move.
    func demand(_ consumer: Consumer, lead: @escaping @Sendable (_ playhead: Double) -> Double,
                from anchor: Double? = nil, seekGeneration: UInt64 = 0) {
        guard !closed else { return }
        leads.set(consumer, lead)
        stopReason = nil
        guard loop != nil else {
            start(at: max(0, anchor ?? host.playhead() ?? 0))
            return
        }
        if let anchor { move(to: anchor, seekGeneration: seekGeneration) }
    }

    /// `consumer` no longer wants anything. The loop stops once nobody asks, judged after the current
    /// turn of the main actor, so a consumer that withdraws and asks again in one change (a re-arm, a
    /// track switch) moves the reading instead of closing and reopening it.
    func withdraw(_ consumer: Consumer, reason: SubtitleDrainStopReason? = nil) {
        leads.set(consumer, nil)
        guard leads.isEmpty, loop != nil else { return }
        if let reason { stopReason = reason }
        guard !stopPending else { return }
        stopPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stopPending = false
            guard self.leads.isEmpty, self.loop != nil, !self.closed else { return }
            let reason = self.stopReason
            self.stopReason = nil
            self.stopLoop()
            self.host.stopped(reason)
        }
    }

    /// The playhead jumped (a seek, a producer re-anchor): the reading goes on from `seconds`. A loop
    /// that already ended (the end of the file, a spent restart budget) starts again there while anyone
    /// still asks.
    func move(to seconds: Double, seekGeneration: UInt64 = 0) {
        let anchor = SubtitleForwardPrefetcher.SideReaderReanchor.Anchor(seconds: max(0, seconds),
                                                                         seekGeneration: seekGeneration)
        guard loop != nil else {
            if !closed, !leads.isEmpty { start(at: anchor.seconds) }
            return
        }
        if let reanchor {
            reanchor.request(anchor.seconds, seekGeneration: anchor.seekGeneration)
        } else {
            pendingMove = anchor
        }
    }

    /// Session teardown.
    func close() {
        closed = true
        leads.clear()
        if loop != nil {
            stopLoop()
            host.stopped(.sessionStopped)
        }
        let fill = wholeFill
        fill?.cancel()
        wholeFill = nil
        resolution.cancel()
        let resolution = resolution!
        // The fill's lanes read through the root; it closes once they are done.
        BlockingWork.detached(priority: .utility) {
            await fill?.value
            await resolution.value.root?.close()
        }
    }

    private func stopLoop() {
        loop?.task.cancel()
        loop = nil
        walkDemuxer?.markClosed()
        walkDemuxer = nil
        reanchor = nil
        pendingMove = nil
    }

    // MARK: - Resolution

    /// What the routes were settled with: the index, what its frames are read through, and every stream.
    struct Resolution: @unchecked Sendable {
        let index: (any SourceIndex)?
        /// What the index's frames are read through; closed with the source.
        let root: IOReader?
        let routes: [Int32: Route]
        /// The streams the index reads, as the loop reads them.
        let indexedStreams: [SubtitleForwardPrefetcher.IndexSource.Stream]
        let listed: [IndexedSubtitleStream]
        let assembly: Set<Int32>

        /// A reader of the index's frames for one lane of work, closed by the caller. A root that reads
        /// exact ranges serves every lane itself (one reader, one session, one connection); any other gets
        /// a reader of its own per lane, since its one cursor would serialise them.
        func laneSource() -> IOReaderByteSource? {
            guard let root else { return nil }
            if root is RangeReadableIOReader { return IOReaderByteSource(root, closesReader: false) }
            return root.makeIndependentReader().map { IOReaderByteSource($0) }
        }

        /// The walk is needed: some stream is walked, or no stream could be listed at all.
        var needsWalk: Bool { routes.isEmpty || routes.values.contains(.walked) }
    }

    private struct ResolutionInputs: @unchecked Sendable {
        let url: URL
        let headers: [String: String]
        let demuxer: Demuxer?
        let indexable: Bool
        let customClone: IOReader?
    }

    nonisolated private static func requestHeaders(_ host: Host) -> [String: String] {
        var headers = host.headers
        headers.merge(host.headerStore?.current ?? [:]) { _, new in new }
        return headers
    }

    /// Asks the registry for the source's one index and gives each subtitle stream its route.
    nonisolated private static func resolve(_ inputs: ResolutionInputs) async -> Resolution {
        let listed = inputs.demuxer.map { AetherEngine.indexedSubtitleStreams(of: $0) } ?? []
        let streams = inputs.demuxer?.subtitleStreamIndices() ?? []
        let assembly = inputs.demuxer?.splitDisplaySetSubtitleStreamIndices() ?? []
        func allWalked(_ why: String, root: IOReader? = nil) -> Resolution {
            root?.close()
            if !streams.isEmpty {
                EngineLog.emit("[SubtitleSource] every stream walked (\(why)): \(streams.sorted())", category: .engine)
            }
            return Resolution(index: nil, root: nil, routes: Dictionary(uniqueKeysWithValues: streams.map { ($0, .walked) }),
                              indexedStreams: [], listed: listed, assembly: assembly)
        }
        guard inputs.indexable, let demuxer = inputs.demuxer, !streams.isEmpty else {
            return allWalked(inputs.demuxer == nil ? "no session demuxer" : "live, a disc or no subtitle streams",
                             root: inputs.customClone)
        }
        guard let root = inputs.customClone
                ?? AetherEngine.indexReader(url: inputs.url, headers: inputs.headers, label: "subindex") else {
            return allWalked("the source cannot be read by range")
        }
        let began = Date()
        let outcome = await SourceIndexRegistry.shared.index(of: inputs.url, headers: inputs.headers,
                                                             demuxer: demuxer, through: root)
        guard let index = outcome.index else { return allWalked("no usable index: \(outcome)", root: root) }
        let plan = SubtitleForwardPrefetcher.IndexSource.plan(index: index, listed: listed, streams: streams)
        var routes: [Int32: Route] = [:]
        for stream in streams { routes[stream] = .walked }
        for stream in plan.streams { routes[stream.streamIndex] = .indexed(track: stream.track) }
        EngineLog.emit("[SubtitleSource] routes in \(Int(Date().timeIntervalSince(began) * 1000)) ms: indexed "
                       + "\(plan.streams.map(\.streamIndex))"
                       + (plan.refused.isEmpty ? "" : ", walked \(plan.refused.joined(separator: ", "))"),
                       category: .engine)
        guard !plan.streams.isEmpty else {
            root.close()
            return Resolution(index: nil, root: nil, routes: routes, indexedStreams: [], listed: listed, assembly: assembly)
        }
        return Resolution(index: index, root: root, routes: routes, indexedStreams: plan.streams,
                          listed: listed, assembly: assembly)
    }

    // MARK: - Indexed renditions, whole

    /// Parallel lanes for block reads: a remote range read costs a round trip each (about 40 ms measured
    /// through a reverse proxy), so they go out side by side.
    nonisolated static let readLanes = 12

    /// Every indexed text stream with a rendition: all of its frames, decoded in order into its store,
    /// which is then complete. A stream with frames that could not be read keeps what was read as a head
    /// start and stays open.
    nonisolated private static func fillIndexedRenditions(_ resolved: Resolution, host: Host) async {
        guard let index = resolved.index else { return }
        for stream in resolved.indexedStreams {
            guard !Task.isCancelled else { return }
            guard let store = host.cueStores[stream.streamIndex],
                  let listed = resolved.listed.first(where: { $0.streamIndex == stream.streamIndex }),
                  let decoder = await MainActor.run(body: { host.makeDecoder(stream.streamIndex).map(DecoderHandoff.init) })?.decoder,
                  !EmbeddedSubtitleDecoder.isBitmapCodec(decoder.codecID) else { continue }
            let began = Date()
            let stop = StopFlag()
            let frames = await withTaskCancellationHandler {
                readFrames(stream.blocks, track: stream.track, index: index, resolved: resolved, stop: stop)
            } onCancel: { stop.raise() }
            guard !Task.isCancelled else { return }
            var cues: [SubtitleCue] = []
            var missing = 0
            for i in stream.blocks.indices {
                guard let frame = frames[i] else { missing += 1; continue }
                if let event = decode(frame, index: index, track: stream.track, streamTimeBase: listed.timeBase,
                                      decoder: decoder) {
                    cues.append(contentsOf: event.cues)
                }
            }
            store.appendCues(cues)
            if !cues.isEmpty { await MainActor.run { host.cuesArrived() } }
            guard missing == 0 else {
                EngineLog.emit("[SubtitleSource] stream \(stream.streamIndex): \(missing) of \(stream.blocks.count) "
                               + "frames unreadable; its \(cues.count) cues are a head start, the rendition stays open",
                               category: .engine)
                continue
            }
            let duration = await MainActor.run { host.duration() }
            store.noteRead(from: 0, through: max(duration, cues.map(\.endTime).max() ?? 0))
            store.markFinished()
            EngineLog.emit("[SubtitleSource] stream \(stream.streamIndex) complete from the index: "
                           + "\(stream.blocks.count) frames, \(cues.count) cues in "
                           + "\(Int(Date().timeIntervalSince(began) * 1000)) ms", category: .engine)
        }
    }

    private struct DecoderHandoff: @unchecked Sendable { let decoder: EmbeddedSubtitleDecoder }

    /// Raised by a cancel, read by the lanes, which run on threads of their own outside the task.
    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.lock(); raised = true; lock.unlock() }
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    }

    /// `blocks` read on parallel lanes, by their position in the array.
    nonisolated static func readFrames(_ blocks: [SourceIndexBlock], track: UInt64, index: any SourceIndex,
                                       resolved: Resolution, stop: StopFlag) -> [Int: SourceIndexFrame] {
        guard !blocks.isEmpty else { return [:] }
        let sources = (0..<min(readLanes, blocks.count)).compactMap { _ in resolved.laneSource() }
        defer { sources.forEach { $0.close() } }
        guard !sources.isEmpty else { return [:] }
        final class Frames: @unchecked Sendable {
            let lock = NSLock()
            var byPosition: [Int: SourceIndexFrame] = [:]
        }
        let out = Frames()
        DispatchQueue.concurrentPerform(iterations: sources.count) { lane in
            var k = lane
            while k < blocks.count, !stop.isRaised {
                if let frame = index.readFrame(blocks[k], track: track, from: sources[lane]) {
                    out.lock.lock(); out.byPosition[k] = frame; out.lock.unlock()
                }
                k += sources.count
            }
        }
        return out.byPosition
    }

    /// One frame through the decoder as the packet libavformat would hand over (WebVTT settings as side
    /// data), timed on the stream's time base.
    nonisolated static func decode(_ frame: SourceIndexFrame, index: any SourceIndex, track: UInt64,
                                   streamTimeBase: AVRational,
                                   decoder: EmbeddedSubtitleDecoder) -> EmbeddedSubtitleDecoder.SubtitleEvent? {
        let payload = frame.payload
        guard !payload.isEmpty, let packet = trackedPacketAlloc() else { return nil }
        defer { var p: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&p) }
        guard av_new_packet(packet, Int32(payload.count)) == 0 else { return nil }
        payload.withUnsafeBufferPointer { packet.pointee.data.update(from: $0.baseAddress!, count: $0.count) }
        if let settings = frame.webVTTSettings { WebVTTCueSettings.attach(settings: settings, to: packet) }
        let ticksBase = index.timeBase(track: track)
        let toStream = { (ticks: Int64) -> Int64 in av_rescale_q(ticks, ticksBase, streamTimeBase) }
        packet.pointee.pts = toStream(frame.ticks)
        packet.pointee.dts = packet.pointee.pts
        if let duration = frame.durationTicks { packet.pointee.duration = toStream(duration) }
        return decoder.decode(packet: packet, streamTimeBase: streamTimeBase)
    }

    // MARK: - The loop

    private func start(at anchor: Double) {
        loopGeneration += 1
        let generation = loopGeneration
        let leads = leads
        let link = SideReaderLinkArbiter(gate: host.linkGate)
        let url = host.url
        let resolution = resolution!
        let host = host
        let task = BlockingWork.detached(priority: .utility) { [weak self] in
            // #231: restart on a read error, bounded, at the playhead the failure left behind.
            var budget = SubtitleForwardPrefetcher.RestartBudget(
                maxConsecutiveFailures: AetherEngine.subtitleForwardPrefetchMaxConsecutiveFailures,
                maxRestarts: AetherEngine.subtitleForwardPrefetchMaxRestarts,
                backoffNanoseconds: AetherEngine.subtitleForwardPrefetchRestartBackoffNanoseconds)
            var resumeAt = anchor
            var holding = false
            let resolved = await resolution.value
            defer {
                Task { @MainActor [weak self] in
                    if let self, self.loop?.generation == generation { self.loop = nil }
                }
            }
            while !Task.isCancelled {
                let paced = OriginRequestBudget.shared.isPaced(url)
                let serial = OriginRequestBudget.shared.requiresSerialRequests(url)
                if SubtitleForwardPrefetcher.shouldHold(originPaced: paced, originSerial: serial) {
                    if !holding {
                        EngineLog.emit("[SubtitleSource] holding: origin is metered (paced=\(paced) serial=\(serial))",
                                       category: .engine)
                        holding = true
                    }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    continue
                }
                if holding {
                    EngineLog.emit("[SubtitleSource] resuming: origin is no longer metered", category: .engine)
                    holding = false
                }
                guard let self else { return }
                let outcome = await self.runSession(from: resumeAt, resolved: resolved, host: host, leads: leads,
                                                    link: link)
                guard outcome.exit.isRestartable, !Task.isCancelled else { return }
                guard let backoff = budget.chargeFailure(harvested: outcome.harvested) else {
                    EngineLog.emit("[SubtitleSource] giving up after \(budget.restarts) restarts "
                                   + "(\(budget.consecutiveFailures) consecutive): nothing past the pump's own "
                                   + "reading is read for the rest of this session", category: .engine)
                    return
                }
                do { try await Task.sleep(nanoseconds: backoff) } catch { return }
                guard let fresh = await MainActor.run(body: { host.playhead() }) else { return }
                resumeAt = max(0, fresh)
                EngineLog.emit("[SubtitleSource] restarting after a read failure (restart \(budget.restarts)) at "
                               + "\(String(format: "%.2f", resumeAt))s", category: .engine)
            }
        }
        loop = (task, generation)
    }

    /// One session of the loop: the walk opened and positioned where any stream is walked, the index's
    /// cursors placed, then read until the end, a failure or a cancel.
    nonisolated private func runSession(from startAt: Double, resolved: Resolution, host: Host, leads: Leads,
                                        link: SideReaderLinkArbiter) async -> SubtitleForwardPrefetcher.Outcome {
        let store = host.packetStore
        let indexedStreams = Set(resolved.indexedStreams.map(\.streamIndex))
        var demuxer: Demuxer?
        /// The walk's demuxer as teardown knows it, opened or not.
        var registeredDemuxer: Demuxer?
        var clone: IOReader?
        var walk: SubtitleForwardPrefetcher.DemuxerSource?
        var pacing: Int32 = -1
        var walked: Set<Int32> = []
        var adoptedBox: SubtitleForwardPrefetcher.SideReaderReanchor? = nil
        defer {
            demuxer?.close()
            clone?.close()
            let registered = registeredDemuxer
            let ended = adoptedBox
            Task { @MainActor [weak self, weak registered] in
                guard let self else { return }
                if let registered, self.walkDemuxer === registered { self.walkDemuxer = nil }
                // A move asked of this session after it ended goes to the next one.
                if let ended, self.reanchor === ended { self.reanchor = nil }
            }
        }
        let engineDuration = await MainActor.run { host.duration() }
        if resolved.needsWalk {
            // #93, #240: a walk opened during a producer restart, or the seek it serves, competes with it
            // for the link, and its open costs the container header, the cue prewarm and the positioning
            // seek. Bounded: a source that never leaves the seek state ends up with a walk that opened
            // late, not with none.
            let deadline = DispatchTime.now() + 30.0
            while !Task.isCancelled, DispatchTime.now() < deadline {
                let busy = await MainActor.run { host.videoRestarting() }
                if !busy, !link.shouldDeferOpen() { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !Task.isCancelled else { return .init(exit: .cancelled, harvested: 0) }
            if let customReader = host.customReader {
                guard let made = await MainActor.run(body: { customReader() }) else {
                    return .init(exit: .openFailed, harvested: 0)
                }
                clone = made
            }
            let opening = Demuxer()
            let registered = await MainActor.run { [weak self] () -> Bool in
                guard !Task.isCancelled, let self else { return false }
                self.walkDemuxer = opening
                return true
            }
            guard registered else { return .init(exit: .cancelled, harvested: 0) }
            registeredDemuxer = opening
            let profile = DemuxerOpenProfile.subtitleSideDemuxer(
                callerProbesize: host.probesize, callerMaxAnalyzeDuration: host.maxAnalyzeDuration)
                .withReaderLabel("subwalk").withRequestHeaders(host.headerStore)
            do {
                if let clone {
                    try opening.open(reader: clone, formatHint: host.formatHint, profile: profile,
                                     selectTitleID: host.discTitleID, discCacheKey: host.url.absoluteString)
                } else {
                    try opening.open(url: host.url, extraHeaders: host.headers, profile: profile,
                                     selectTitleID: host.discTitleID)
                }
            } catch {
                EngineLog.emit("[SubtitleSource] walk open failed: \(error)", category: .engine)
                return .init(exit: .openFailed, harvested: 0)
            }
            demuxer = opening
            walked = opening.subtitleStreamIndices().subtracting(indexedStreams)
            if !walked.isEmpty {
                let assembly = opening.splitDisplaySetSubtitleStreamIndices()
                // #230: one non-subtitle stream stays deliverable at AVDISCARD_NONKEY so the loop has a
                // read-position control point between cues. AVDISCARD_ALL is applied inside av_read_frame,
                // so a fully discarded source hands the loop nothing at all between two subtitle packets
                // and a single read call walks whatever lies between them.
                pacing = opening.prefetchPacingStreamIndex()
                opening.discardAllStreamsExcept(walked, pacing: pacing)
                // The pump's rule decides where a prewarm loads anything (`HLSVideoEngine.cuePrewarmMayRun`).
                let duration = opening.duration
                if duration > 0, HLSVideoEngine.cuePrewarmMayRun(opening) {
                    opening.seekBounded(to: duration * 0.5, timeout: AetherEngine.sideReaderSeekBudgetSeconds)
                }
                // #234: anchored on the subtitle axis. A -1 seek lets libavformat pick the reference
                // stream by score, the pacing stream outranks the subtitle one there, and the seek lands on
                // a video keyframe in another Matroska cluster, behind which the landing cue is lost.
                let landed = SubtitleForwardPrefetcher.reposition(
                    demuxer: opening, to: startAt, anchorStreamIndex: walked.min() ?? -1,
                    fallbackDuration: engineDuration, timeout: AetherEngine.sideReaderSeekBudgetSeconds)
                if landed != .seek {
                    EngineLog.emit("[SubtitleSource] walk seek to \(String(format: "%.2f", startAt))s timed out or "
                                   + "failed; byte-estimate fallback \(landed == .byteEstimate ? "applied" : "unavailable")",
                                   category: .engine)
                }
                var routes: [Int32: SubtitleForwardPrefetcher.CueRoute] = [:]
                for stream in walked.sorted() {
                    guard let store = host.cueStores[stream],
                          let decoder = await MainActor.run(body: { host.makeDecoder(stream).map(DecoderHandoff.init) })?.decoder,
                          !EmbeddedSubtitleDecoder.isBitmapCodec(decoder.codecID) else { continue }
                    routes[stream] = .init(decoder: decoder, store: store)
                }
                let arrived = host.cuesArrived
                let announce: @Sendable () -> Void = { Task { @MainActor in arrived() } }
                walk = SubtitleForwardPrefetcher.DemuxerSource(
                    demuxer: opening, streamIndices: walked, assemblyIndices: assembly, pacingIndex: pacing,
                    cueRoutes: routes, cuesArrived: routes.isEmpty ? nil : announce)
            }
        }
        // The index's frames through a reader of the loop's own, so a cancel can end a read in flight.
        var indexReader: IOReader?
        var indexSource: SubtitleForwardPrefetcher.IndexSource?
        if let index = resolved.index, !resolved.indexedStreams.isEmpty,
           let reader = resolved.root?.makeIndependentReader() {
            indexReader = reader
            indexSource = .init(index: index, bytes: IOReaderByteSource(reader, closesReader: false),
                                streams: resolved.indexedStreams, assemblyIndices: resolved.assembly, from: startAt)
        }
        defer { indexReader?.close() }
        let source: SubtitleForwardPrefetcher.Source
        switch (indexSource, walk) {
        case let (index?, walk?): source = SubtitleForwardPrefetcher.CompositeSource(index: index, walk: walk, from: startAt)
        case let (index?, nil): source = index
        case let (nil, walk?): source = walk
        case (nil, nil): return .init(exit: .openFailed, harvested: 0)
        }
        // #416: this session reads forwards from here, and nothing below it is this reader's to claim.
        store.noteHarvestAnchor(.prefetch, at: startAt)
        // #240: the running loop's own anchor box, so a jump moves the cursor instead of rebuilding the
        // session. It carries the walk's positioning inputs, so an in-place move cannot drift from the
        // rules above. #250: the fence its read positions belong to, captured in the same hop.
        let reanchor = SubtitleForwardPrefetcher.SideReaderReanchor(
            anchorStreamIndex: walked.min() ?? -1, fallbackDuration: engineDuration,
            seekTimeout: AetherEngine.sideReaderSeekBudgetSeconds)
        adoptedBox = reanchor
        let opened = demuxer
        let adopted = await MainActor.run { [weak self] () -> SubtitleResolutionStatement.Fence? in
            guard !Task.isCancelled, let self, self.walkDemuxer === opened else { return nil }
            self.reanchor = reanchor
            if let move = self.pendingMove {
                reanchor.request(move.seconds, seekGeneration: move.seekGeneration)
                self.pendingMove = nil
            }
            return host.fence()
        }
        guard let fence = adopted else { return .init(exit: .cancelled, harvested: 0) }
        EngineLog.emit("[SubtitleSource] reading from \(String(format: "%.2f", startAt))s: indexed "
                       + "\(resolved.indexedStreams.map(\.streamIndex)) walked \(walked.sorted()) pacing=\(pacing)",
                       category: .engine)
        let outcome = await withTaskCancellationHandler {
            await SubtitleForwardPrefetcher.run(
                source: source, store: store, lead: { leads.furthest(playhead: $0) },
                parkPollNanoseconds: AetherEngine.subtitleForwardPrefetchParkPollNanoseconds,
                link: link, reanchor: reanchor, fence: fence,
                playhead: { await MainActor.run(body: { host.playhead() }) })
        } onCancel: {
            // A block read in flight is a ranged GET; teardown must not wait out its timeout. The walk's
            // demuxer is ended by `stopLoop` (`markClosed`).
            indexReader?.cancel()
        }
        EngineLog.emit("[SubtitleSource] session exited (reason=\(outcome.exit) cancelled=\(Task.isCancelled)) "
                       + "harvested=\(outcome.harvested)", category: .engine)
        // #250: EOF is the one exit that strengthens the claim: everything ahead of the playhead is read.
        if outcome.exit == .endOfFile { await MainActor.run { host.endOfFile() } }
        return outcome
    }

    /// The consumers' leads, read by the loop at every park decision.
    final class Leads: @unchecked Sendable {
        private let lock = NSLock()
        private var leads: [Consumer: @Sendable (Double) -> Double] = [:]

        func set(_ consumer: Consumer, _ lead: (@Sendable (Double) -> Double)?) {
            lock.lock(); defer { lock.unlock() }
            leads[consumer] = lead
        }

        func clear() {
            lock.lock(); defer { lock.unlock() }
            leads.removeAll()
        }

        var isEmpty: Bool {
            lock.lock(); defer { lock.unlock() }
            return leads.isEmpty
        }

        var consumers: Set<Consumer> {
            lock.lock(); defer { lock.unlock() }
            return Set(leads.keys)
        }

        /// The furthest any consumer asks for; 0 with none, which parks the loop at the playhead.
        func furthest(playhead: Double) -> Double {
            lock.lock()
            let all = Array(leads.values)
            lock.unlock()
            return all.map { $0(playhead) }.max() ?? 0
        }
    }

    /// The consumers asking now.
    var consumers: Set<Consumer> { leads.consumers }
}
