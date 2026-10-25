import Foundation
import AetherLibavcodec
import AetherLibavutil

/// The session's one reader of its embedded subtitle streams.
///
/// Each stream is read one of two ways, settled once per session (`Route`):
///
/// - **The index** (`SourceIndex`, through `SourceIndexRegistry`): a stream the container lists in full,
///   in a codec whose frame is its packet, is read exactly where the index places each frame, and only
///   when asked (`pull`): the overlay drainer and the OCR worker pull the window they are about to
///   decode, and the packet store is a cache of what was pulled. Its text rendition's cue store is filled
///   whole as soon as the route is known, which is what AVKit needs (it reads a rendition minutes ahead
///   and keeps what it gets), and the frames that fill reads are the stream's pull, for the whole film.
///   Nothing else writes such a stream (`SubtitlePacketStore.setPulledStreams`).
/// - **The walk**: every other stream, read by one side demuxer for all of them, which harvests into the
///   packet store and decodes each text stream into its cue store as it goes. A consumer reading a walked
///   stream states how far ahead it wants it (`demand`); the walk reads to the furthest of those leads and
///   no further, and stops when no consumer of a walked stream asks any more. The pump's tap also writes
///   these, as far as it plays.
///
/// No reader of the source is held between reads: a pull opens its readers and closes them, so the source
/// cache sees no second reader the pump's stream would have to be kept for (`SourceByteCache.Retention`).
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
        /// The playhead on the source axis; nil once the engine is gone. Where a demand anchors the walk.
        let playhead: @MainActor @Sendable () -> Double?
        /// The playhead the walk paces against, read where it parks, off the main actor
        /// (`SourcePlayheadClock`); nil while no clock runs, which the walk waits out.
        let pacingPlayhead: @Sendable () -> Double?
        let duration: @MainActor @Sendable () -> Double
        /// A producer restart is executing (#93): a walk opened now would compete with it for the link.
        let videoRestarting: @MainActor @Sendable () -> Bool
        let linkGate: SideReaderLinkGate
        let fence: @MainActor @Sendable () -> SubtitleResolutionStatement.Fence
        let cuesArrived: @MainActor @Sendable () -> Void
        let endOfFile: @MainActor @Sendable () -> Void
        /// The reading stopped because nobody asks any more, with the reason the last consumer gave.
        let stopped: @MainActor @Sendable (SubtitleDrainStopReason?) -> Void
        /// The routes are settled; the indexed streams are the pulls' from now on.
        let routesSettled: @MainActor @Sendable ([Int32: Route]) -> Void
        /// A pull of the stream stored what it read.
        let pulled: @MainActor @Sendable (Int32) -> Void
    }

    let host: Host
    private let leads = Leads()
    private var resolution: Task<Resolution, Never>!
    /// The resolution once it is in, read synchronously by the drainer and the pulls.
    private var settled: Resolution?
    /// Where a demand that came before the routes asked the walk to start.
    private var pendingAnchor: SubtitleForwardPrefetcher.SideReaderReanchor.Anchor?
    /// Per stream, the pull being read and the flag that ends it.
    private var pullInFlight: [Int32: (from: Double, through: Double, stop: StopFlag)] = [:]
    /// Per stream, a block that failed to read and how often in a row.
    private var pullFailures: [Int32: (block: Int, attempts: Int)] = [:]
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
        Task { @MainActor [weak self] in
            let resolved = await resolving.value
            self?.settle(resolved)
        }
        wholeFill = BlockingWork.detached(priority: .utility) { [host] in
            await Self.fillIndexedRenditions(await resolving.value, host: host)
        }
    }

    /// Whether the walk is running.
    var isReading: Bool { loop != nil }

    /// The routes, once settled.
    func routes() async -> [Int32: Route] { await resolution.value.routes }

    /// A stream's route once the routes are settled; nil before, and for a stream the session never listed.
    func route(of stream: Int32) -> Route? { settled?.routes[stream] }

    /// The routes are in: the indexed streams become the pulls' alone, and a demand that came first is
    /// taken now.
    private func settle(_ resolved: Resolution) {
        guard !closed else { return }
        settled = resolved
        host.packetStore.setPulledStreams(Set(resolved.indexedStreams.map(\.streamIndex)))
        host.routesSettled(resolved.routes)
        let anchor = pendingAnchor
        pendingAnchor = nil
        reconsiderWalk(anchor: anchor)
    }

    /// Whether a stream is the walk's: everything the index does not read, a stream the session never
    /// listed included.
    private func isWalked(_ stream: Int32) -> Bool {
        if case .indexed = settled?.routes[stream] { return false }
        return true
    }

    /// `consumer` reads `streams` and wants the walked ones read to `lead(playhead)` seconds past the playhead.
    /// The walk starts at `anchor` (the playhead when nil) if one of them is walked and it is not running; a
    /// running walk moves to `anchor` in place when one is given, and otherwise reads on to the raised lead
    /// without a move. An indexed stream needs no demand: its consumer pulls what it is about to decode.
    func demand(_ consumer: Consumer, streams: Set<Int32>, lead: @escaping @Sendable (_ playhead: Double) -> Double,
                from anchor: Double? = nil, seekGeneration: UInt64 = 0) {
        guard !closed else { return }
        leads.set(consumer, lead, streams: streams)
        stopReason = nil
        let anchor = anchor.map {
            SubtitleForwardPrefetcher.SideReaderReanchor.Anchor(seconds: max(0, $0), seekGeneration: seekGeneration)
        }
        guard settled != nil else {
            if let anchor { pendingAnchor = anchor }
            return
        }
        reconsiderWalk(anchor: anchor)
    }

    /// `consumer` no longer wants anything. The walk stops once no consumer of a walked stream asks, judged
    /// after the current turn of the main actor, so a consumer that withdraws and asks again in one change
    /// (a re-arm, a track switch) moves the reading instead of closing and reopening it.
    func withdraw(_ consumer: Consumer, reason: SubtitleDrainStopReason? = nil) {
        leads.set(consumer, nil, streams: [])
        if let reason, loop != nil { stopReason = reason }
        reconsiderWalk(anchor: nil)
    }

    /// Starts, moves or stops the walk for what the consumers now ask.
    private func reconsiderWalk(anchor: SubtitleForwardPrefetcher.SideReaderReanchor.Anchor?) {
        guard !closed, settled != nil else { return }
        if leads.demandsAny(where: isWalked) {
            guard loop != nil else {
                start(at: anchor?.seconds ?? max(0, host.playhead() ?? 0))
                return
            }
            if let anchor { move(to: anchor.seconds, seekGeneration: anchor.seekGeneration) }
            return
        }
        guard loop != nil, !stopPending else { return }
        stopPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stopPending = false
            guard !self.leads.demandsAny(where: self.isWalked), self.loop != nil, !self.closed else { return }
            let reason = self.stopReason
            self.stopReason = nil
            self.stopLoop()
            self.host.stopped(reason)
        }
    }

    /// The playhead jumped (a seek, a producer re-anchor): the walk goes on from `seconds`. A walk that
    /// already ended (the end of the file, a spent restart budget) starts again there while a consumer of a
    /// walked stream still asks.
    func move(to seconds: Double, seekGeneration: UInt64 = 0) {
        let anchor = SubtitleForwardPrefetcher.SideReaderReanchor.Anchor(seconds: max(0, seconds),
                                                                         seekGeneration: seekGeneration)
        guard settled != nil else {
            pendingAnchor = anchor
            return
        }
        guard loop != nil else {
            if !closed, leads.demandsAny(where: isWalked) { start(at: anchor.seconds) }
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
        for pull in pullInFlight.values { pull.stop.raise() }
        pullInFlight.removeAll()
        resolution.cancel()
        let resolution = resolution!
        // A host clone serves the fill's lanes; it closes once they are done.
        BlockingWork.detached(priority: .utility) {
            await fill?.value
            if case .clone(let reader)? = await resolution.value.frames { reader.close() }
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

    /// What the routes were settled with: the index, how its frames are read, and every stream.
    struct Resolution: @unchecked Sendable {
        let index: (any SourceIndex)?
        let frames: FrameReaders?
        let routes: [Int32: Route]
        /// The streams the index reads.
        let indexedStreams: [IndexedStream]
        let listed: [IndexedSubtitleStream]
        let assembly: Set<Int32>
    }

    /// A stream the index reads: its track and every frame's block, in time order.
    struct IndexedStream: Sendable {
        let streamIndex: Int32
        let track: UInt64
        let blocks: [SourceIndexBlock]
    }

    /// Where a read of the index's frames gets its readers.
    enum FrameReaders: @unchecked Sendable {
        /// A URL: readers opened for the read and closed after it, so no reader of the source outlives a
        /// read (a second open reader is what makes the source cache keep the pump's whole stream).
        case url(URL, headers: [String: String])
        /// A host's own source, outside the source cache: the clone it was resolved through, held for the
        /// session.
        case clone(IOReader)

        /// Byte sources for up to `count` lanes, each closed by the caller. A reader of exact ranges serves
        /// every lane itself (one reader, one connection); any other gives each lane a reader of its own,
        /// since its one cursor would serialise them.
        func lanes(_ count: Int, label: String) -> [IOReaderByteSource] {
            guard count > 0 else { return [] }
            switch self {
            case .url(let url, let headers):
                guard let first = AetherEngine.indexReader(url: url, headers: headers, label: label) else { return [] }
                guard first is RangeReadableIOReader else {
                    return [IOReaderByteSource(first)] + (1..<count).compactMap { _ in
                        AetherEngine.indexReader(url: url, headers: headers, label: label).map { IOReaderByteSource($0) }
                    }
                }
                return [IOReaderByteSource(first)] + (1..<count).map { _ in IOReaderByteSource(first, closesReader: false) }
            case .clone(let root):
                if root is RangeReadableIOReader {
                    return (0..<count).map { _ in IOReaderByteSource(root, closesReader: false) }
                }
                return (0..<count).compactMap { _ in root.makeIndependentReader().map { IOReaderByteSource($0) } }
            }
        }
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
            return Resolution(index: nil, frames: nil, routes: Dictionary(uniqueKeysWithValues: streams.map { ($0, .walked) }),
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
        // A stream is indexed only where its frames can be pulled: a host's reader has to read exact ranges
        // itself or hand each lane a reader of its own (`FrameReaders.lanes`).
        if inputs.customClone != nil, !(root is RangeReadableIOReader) {
            guard let lane = root.makeIndependentReader() else {
                return allWalked("the host's reader cannot read frames by position", root: root)
            }
            lane.close()
        }
        let began = Date()
        let outcome = await SourceIndexRegistry.shared.index(of: inputs.url, headers: inputs.headers,
                                                             demuxer: demuxer, through: root)
        guard let index = outcome.index else { return allWalked("no usable index: \(outcome)", root: root) }
        let plan = Self.plan(index: index, listed: listed, streams: streams)
        var routes: [Int32: Route] = [:]
        for stream in streams { routes[stream] = .walked }
        for stream in plan.streams { routes[stream.streamIndex] = .indexed(track: stream.track) }
        EngineLog.emit("[SubtitleSource] routes in \(Int(Date().timeIntervalSince(began) * 1000)) ms: indexed "
                       + "\(plan.streams.map(\.streamIndex))"
                       + (plan.refused.isEmpty ? "" : ", walked \(plan.refused.joined(separator: ", "))"),
                       category: .engine)
        // The parse is the only read through this reader. A URL's frames are read by readers of their own
        // per read; a host's clone is the one reader its source has.
        let frames: FrameReaders
        if inputs.customClone != nil {
            frames = .clone(root)
        } else {
            root.close()
            frames = .url(inputs.url, headers: inputs.headers)
        }
        guard !plan.streams.isEmpty else {
            if case .clone(let reader) = frames { reader.close() }
            return Resolution(index: nil, frames: nil, routes: routes, indexedStreams: [], listed: listed, assembly: assembly)
        }
        return Resolution(index: index, frames: frames, routes: routes, indexedStreams: plan.streams,
                          listed: listed, assembly: assembly)
    }

    /// Which of `streams` the index can stand in for: a stream it pairs with a track, of a codec whose frame
    /// is its packet, listed in full. Each refused stream is named with the reason, and is the walk's.
    nonisolated static func plan(index: any SourceIndex, listed: [IndexedSubtitleStream],
                                 streams: Set<Int32>) -> (streams: [IndexedStream], refused: [String]) {
        let tracks = index.trackNumbers(for: listed)
        var plan: [IndexedStream] = []
        var refused: [String] = []
        for streamIndex in streams.sorted() {
            guard let entry = listed.first(where: { $0.streamIndex == streamIndex }) else {
                refused.append("\(streamIndex): not listed")
                continue
            }
            guard let track = tracks[streamIndex] else { refused.append("\(streamIndex): no track"); continue }
            guard index.packetCodecs.contains(entry.codecName) else {
                refused.append("\(streamIndex): \(entry.codecName)")
                continue
            }
            guard index.isComplete(track: track, frameCount: entry.frames) else {
                refused.append("\(streamIndex): incomplete")
                continue
            }
            plan.append(IndexedStream(streamIndex: streamIndex, track: track, blocks: index.blocks(track: track)))
        }
        return (plan, refused)
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
            guard let readers = resolved.frames else { return }
            let began = Date()
            let stop = StopFlag()
            let frames = await withTaskCancellationHandler {
                readFrames(stream.blocks, track: stream.track, index: index, readers: readers, stop: stop)
            } onCancel: { stop.raise() }
            guard !Task.isCancelled else { return }
            // The frames are the stream's pull for the whole film: the overlay reads them from the packet
            // store and never reads a text frame a second time.
            let firstMissing = storeFrames(frames, of: stream.blocks, stream: stream, index: index,
                                           into: host.packetStore)
            notePulled(stream, from: -.infinity, through: .infinity, blocks: stream.blocks, firstMissing: firstMissing,
                       index: index, focus: 0, into: host.packetStore)
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

    // MARK: - Pulls (layer 3 step 3)

    /// How far past what was asked a pull reads, so the window moving on with the playhead costs a read
    /// about every half minute rather than one per drain tick.
    nonisolated static let pullAheadSeconds: Double = 30

    /// Times a block may fail to read in a row before a pull passes over it (a block the index misplaced);
    /// until then each drain tick asks again.
    nonisolated static let pullBlockAttempts = 3

    /// Every frame of the indexed `stream` timed `from` through `through` goes into the packet store, read
    /// where the index places it; returns at once, and `Host.pulled` says when the read is stored. What is
    /// already pulled is not read again, nor what the pull in flight is reading; a pull asked for where that
    /// one will not reach (a landing elsewhere) ends its unread remainder. `focus` is where the reader stands,
    /// which the store keeps nearest when it has to evict.
    func pull(_ stream: Int32, from: Double, through: Double, focus: Double) {
        guard !closed, through >= from, let resolved = settled, let index = resolved.index,
              let readers = resolved.frames,
              let indexed = resolved.indexedStreams.first(where: { $0.streamIndex == stream }) else { return }
        let store = host.packetStore
        let reach = store.pulledReach(streamIndex: stream, from: from)
        if let reach, reach >= through { return }
        let start = reach ?? from
        if let inFlight = pullInFlight[stream] {
            if inFlight.from <= start, start <= inFlight.through { return }
            inFlight.stop.raise()
        }
        let end = through + Self.pullAheadSeconds
        let blocks = indexed.blocks
        let seconds = { (block: SourceIndexBlock) in index.seconds(ticks: block.ticks, track: indexed.track) }
        let lo = Self.firstBlock(blocks, after: start, inclusive: reach == nil, seconds: seconds)
        let hi = Self.firstBlock(blocks, after: end, inclusive: false, seconds: seconds)
        let toRead = lo < hi ? Array(blocks[lo..<hi]) : []
        let stop = StopFlag()
        pullInFlight[stream] = (start, end, stop)
        let began = Date()
        BlockingWork.detached(priority: .userInitiated) { [weak self] in
            let frames = Self.readFrames(toRead, track: indexed.track, index: index, readers: readers, stop: stop)
            let firstMissing = Self.storeFrames(frames, of: toRead, stream: indexed, index: index, into: store)
            Self.notePulled(indexed, from: start, through: end, blocks: toRead, firstMissing: firstMissing,
                            index: index, focus: focus, into: store)
            let milliseconds = Int(Date().timeIntervalSince(began) * 1000)
            await MainActor.run {
                self?.pullLanded(indexed, stop: stop, from: start, through: end, read: frames.count,
                                 failedBlock: firstMissing.map { lo + $0 }, milliseconds: milliseconds)
            }
        }
    }

    /// The time of the indexed `stream`'s first frame after `seconds`: where a bitmap set ends, since the next
    /// display set closes it. Nil past the last frame, and for a stream the index does not read.
    func nextFrameSeconds(_ stream: Int32, after seconds: Double) -> Double? {
        guard let resolved = settled, let index = resolved.index,
              let indexed = resolved.indexedStreams.first(where: { $0.streamIndex == stream }) else { return nil }
        let blocks = indexed.blocks
        let next = Self.firstBlock(blocks, after: seconds, inclusive: false) {
            index.seconds(ticks: $0.ticks, track: indexed.track)
        }
        return next < blocks.count ? index.seconds(ticks: blocks[next].ticks, track: indexed.track) : nil
    }

    private func pullLanded(_ stream: IndexedStream, stop: StopFlag, from: Double, through: Double, read: Int,
                            failedBlock: Int?, milliseconds: Int) {
        if pullInFlight[stream.streamIndex]?.stop === stop { pullInFlight[stream.streamIndex] = nil }
        guard !closed else { return }
        if let failedBlock, !stop.isRaised {
            let attempts = pullFailures[stream.streamIndex]?.block == failedBlock
                ? (pullFailures[stream.streamIndex]?.attempts ?? 0) + 1 : 1
            pullFailures[stream.streamIndex] = (failedBlock, attempts)
            if attempts >= Self.pullBlockAttempts, let index = settled?.index {
                // Passed over: the stretch through it is known, less one frame nobody can read.
                let at = index.seconds(ticks: stream.blocks[failedBlock].ticks, track: stream.track)
                host.packetStore.notePulled(streamIndex: stream.streamIndex, from: from, through: at,
                                            focus: at)
                pullFailures[stream.streamIndex] = nil
                EngineLog.emit("[SubtitleSource] stream \(stream.streamIndex): frame at "
                               + "\(String(format: "%.2f", at))s unreadable \(attempts) times; passed over",
                               category: .engine)
            }
        } else if failedBlock == nil {
            pullFailures[stream.streamIndex] = nil
        }
        if read > 0 {
            EngineLog.emit("[SubtitleSource] pulled stream \(stream.streamIndex) "
                           + "\(String(format: "%.2f", from))-\(String(format: "%.2f", through))s: "
                           + "\(read) frames in \(milliseconds) ms"
                           + (failedBlock == nil ? "" : ", stopped at an unreadable frame")
                           + (stop.isRaised ? ", cut short by a newer pull" : ""),
                           category: .engine)
        }
        host.pulled(stream.streamIndex)
    }

    /// The first block timed after `seconds` (at or after it when `inclusive`), by binary search: blocks are in
    /// time order.
    nonisolated static func firstBlock(_ blocks: [SourceIndexBlock], after seconds: Double, inclusive: Bool,
                                       seconds time: (SourceIndexBlock) -> Double) -> Int {
        var low = 0, high = blocks.count
        while low < high {
            let mid = (low + high) / 2
            let t = time(blocks[mid])
            if inclusive ? t < seconds : t <= seconds { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Every frame read goes into the packet store as libavformat would hand it over. Returns the position of
    /// the first block that was not read, nil when all were.
    @discardableResult
    nonisolated static func storeFrames(_ frames: [Int: SourceIndexFrame], of blocks: [SourceIndexBlock],
                                        stream: IndexedStream, index: any SourceIndex,
                                        into store: SubtitlePacketStore) -> Int? {
        var firstMissing: Int?
        for position in blocks.indices {
            guard let frame = frames[position] else {
                if firstMissing == nil { firstMissing = position }
                continue
            }
            // A frame libavformat drops (an empty payload) the walk would never have seen.
            guard !frame.payload.isEmpty else { continue }
            store.append(streamIndex: stream.streamIndex,
                         ptsSeconds: index.seconds(ticks: frame.ticks, track: stream.track),
                         durationSeconds: frame.durationTicks.map { index.seconds(ticks: $0, track: stream.track) } ?? 0,
                         flags: AV_PKT_FLAG_KEY, payload: Data(frame.payload), webvttSettings: frame.webVTTSettings)
        }
        return firstMissing
    }

    /// Records a read of `blocks` from `from` through `through` as pulled: all of it when every block read,
    /// otherwise up to the first block that did not.
    nonisolated static func notePulled(_ stream: IndexedStream, from: Double, through: Double,
                                       blocks: [SourceIndexBlock], firstMissing: Int?, index: any SourceIndex,
                                       focus: Double, into store: SubtitlePacketStore) {
        guard let firstMissing else {
            store.notePulled(streamIndex: stream.streamIndex, from: from, through: through, focus: focus)
            return
        }
        let stopAt = index.seconds(ticks: blocks[firstMissing].ticks, track: stream.track).nextDown
        guard stopAt >= from else { return }
        store.notePulled(streamIndex: stream.streamIndex, from: from, through: stopAt, focus: focus)
    }

    // MARK: - Forced lines of an indexed bitmap stream

    /// What `indexedForcedLines` found: the forced lines, closed, and how much of the stream was read.
    struct ForcedLines {
        let cues: [SubtitleCue]
        let displaySets: Int
        let forcedDisplaySets: Int
        /// Display sets whose composition header could not be read: the lines are a head start, not all.
        let unreadable: Int
        let milliseconds: Int
    }

    /// The forced lines of `stream` for the whole film, when the index reads it: every display set's
    /// composition header is read (a few hundred bytes each), and only the display sets that carry a forced
    /// object are decoded, each from the last self-contained display set before it. A forced line ends where
    /// the stream's next display set begins. Nil when the stream is walked.
    func indexedForcedLines(stream: Int32) async -> ForcedLines? {
        let resolved = await resolution.value
        guard let index = resolved.index,
              let indexed = resolved.indexedStreams.first(where: { $0.streamIndex == stream }),
              let listed = resolved.listed.first(where: { $0.streamIndex == stream }) else { return nil }
        let host = host
        return await BlockingWork.detached(priority: .utility) {
            await Self.forcedLines(indexed, index: index, timeBase: listed.timeBase, resolved: resolved, host: host)
        }.value
    }

    nonisolated private static func forcedLines(
        _ stream: IndexedStream, index: any SourceIndex, timeBase: AVRational,
        resolved: Resolution, host: Host
    ) async -> ForcedLines? {
        let began = Date()
        let blocks = stream.blocks
        let stop = StopFlag()
        guard let readers = resolved.frames else { return nil }
        let prefixes = await withTaskCancellationHandler {
            readFrames(blocks, track: stream.track, index: index, readers: readers, prefix: 512, stop: stop)
        } onCancel: { stop.raise() }
        guard !Task.isCancelled else { return nil }
        let headers: [PGSCompositionHeader?] = blocks.indices.map { i in
            prefixes[i].flatMap { PGSCompositionHeader.parse($0.payload) }
        }
        let forced = headers.indices.filter { headers[$0]?.isForced == true }
        // Each forced display set, decoded from the self-contained one it builds on.
        var runs: [ClosedRange<Int>] = []
        for f in forced {
            var start = f
            while start > 0, headers[start]?.isSelfContained != true { start -= 1 }
            if let last = runs.last, start <= last.upperBound + 1 {
                runs[runs.count - 1] = last.lowerBound...max(last.upperBound, f)
            } else {
                runs.append(start...f)
            }
        }
        let duration = await MainActor.run { host.duration() }
        var cues: [SubtitleCue] = []
        for run in runs {
            guard !Task.isCancelled,
                  let decoder = await MainActor.run(body: { host.makeDecoder(stream.streamIndex).map(DecoderHandoff.init) })?.decoder
            else { return nil }
            let runBlocks = run.map { blocks[$0] }
            let frames = await withTaskCancellationHandler {
                readFrames(runBlocks, track: stream.track, index: index, readers: readers, stop: stop)
            } onCancel: { stop.raise() }
            for (offset, i) in run.enumerated() {
                guard let frame = frames[offset],
                      let event = decode(frame, index: index, track: stream.track, streamTimeBase: timeBase,
                                         decoder: decoder),
                      headers[i]?.isForced == true else { continue }
                let next = i + 1 < blocks.count
                    ? index.seconds(ticks: blocks[i + 1].ticks, track: stream.track) : duration
                cues.append(contentsOf: event.cues.filter(\.isForced).map { $0.with(endTime: min($0.endTime, next)) })
            }
        }
        return ForcedLines(cues: cues, displaySets: blocks.count, forcedDisplaySets: forced.count,
                           unreadable: headers.filter { $0 == nil }.count,
                           milliseconds: Int(Date().timeIntervalSince(began) * 1000))
    }

    private struct DecoderHandoff: @unchecked Sendable { let decoder: EmbeddedSubtitleDecoder }

    /// Raised by a cancel, read by the lanes, which run on threads of their own outside the task.
    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.lock(); raised = true; lock.unlock() }
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    }

    /// `blocks` read on parallel lanes, by their position in the array. With `prefix`, at most that many
    /// payload bytes of each (enough for a PGS composition header).
    nonisolated static func readFrames(_ blocks: [SourceIndexBlock], track: UInt64, index: any SourceIndex,
                                       readers: FrameReaders, prefix: Int? = nil,
                                       stop: StopFlag) -> [Int: SourceIndexFrame] {
        guard !blocks.isEmpty else { return [:] }
        let sources = readers.lanes(min(readLanes, blocks.count), label: "subpull")
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
                if let frame = index.readFrame(blocks[k], track: track, from: sources[lane], prefix: prefix) {
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
                if let fresh = host.pacingPlayhead() { resumeAt = max(0, fresh) }
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
        do {
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
        guard let walk else { return .init(exit: .openFailed, harvested: 0) }
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
        EngineLog.emit("[SubtitleSource] walking from \(String(format: "%.2f", startAt))s: "
                       + "\(walked.sorted()) pacing=\(pacing)", category: .engine)
        // The walk's demuxer is ended by `stopLoop` (`markClosed`), which ends a read in flight.
        let outcome = await SubtitleForwardPrefetcher.run(
            source: walk, store: store, lead: { leads.furthest(playhead: $0, where: { !indexedStreams.contains($0) }) },
            parkPollNanoseconds: AetherEngine.subtitleForwardPrefetchParkPollNanoseconds,
            link: link, reanchor: reanchor, fence: fence,
            playhead: { host.pacingPlayhead() })
        EngineLog.emit("[SubtitleSource] session exited (reason=\(outcome.exit) cancelled=\(Task.isCancelled)) "
                       + "harvested=\(outcome.harvested)", category: .engine)
        // #250: EOF is the one exit that strengthens the claim: everything ahead of the playhead is read.
        if outcome.exit == .endOfFile { await MainActor.run { host.endOfFile() } }
        return outcome
    }

    /// The consumers' leads and the streams each reads, read by the walk at every park decision.
    final class Leads: @unchecked Sendable {
        private let lock = NSLock()
        private var leads: [Consumer: (lead: @Sendable (Double) -> Double, streams: Set<Int32>)] = [:]

        func set(_ consumer: Consumer, _ lead: (@Sendable (Double) -> Double)?, streams: Set<Int32>) {
            lock.lock(); defer { lock.unlock() }
            leads[consumer] = lead.map { ($0, streams) }
        }

        func clear() {
            lock.lock(); defer { lock.unlock() }
            leads.removeAll()
        }

        var consumers: Set<Consumer> {
            lock.lock(); defer { lock.unlock() }
            return Set(leads.keys)
        }

        /// Whether a consumer reads a stream `matches` picks.
        func demandsAny(where matches: (Int32) -> Bool) -> Bool {
            lock.lock()
            let all = Array(leads.values)
            lock.unlock()
            return all.contains { $0.streams.contains(where: matches) }
        }

        /// The furthest any consumer of a stream `matches` picks asks for; 0 with none, which parks the walk
        /// at the playhead.
        func furthest(playhead: Double, where matches: (Int32) -> Bool) -> Double {
            lock.lock()
            let all = Array(leads.values)
            lock.unlock()
            return all.filter { $0.streams.contains(where: matches) }.map { $0.lead(playhead) }.max() ?? 0
        }
    }

    /// The consumers asking now.
    var consumers: Set<Consumer> { leads.consumers }
}
