import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Native subtitle renditions filled from the container's own index (`MatroskaSubtitleIndex`) rather
/// than by reading the stream around them.
///
/// AVKit fetches a subtitle rendition minutes ahead of playback (measured: about 4 minutes past the
/// video it is fetching) and keeps what it gets. A rendition filled by walking the stream can only be
/// as far ahead as the stream has been read, which on a remux is gigabytes, so its far segments were
/// either waited on past AVPlayer's patience or served empty for good. A Matroska file's Cues list
/// every subtitle block with its exact position, so the subtitles can be read on their own:
///
/// - text tracks are read whole at load and their renditions are complete before AVKit asks;
/// - the forced rendition (`LoadOptions.forcedSubtitleTrack`) of a bitmap track is found from the
///   display sets' composition headers, and only its own display sets are decoded and recognized;
/// - a full bitmap track is recognized from the playhead forward, from the index, when it is selected.
///
/// The index is trusted only for a track it provably lists in full (`MatroskaSubtitleIndex.isComplete`).
/// Everything else keeps the stream-walking path, which follows how far ahead AVKit actually asks.
extension AetherEngine {

    /// What the load-time fill knows about one rendition.
    struct IndexedRenditionPlan: Sendable {
        let ordinal: Int
        let streamIndex: Int32
        let trackNumber: UInt64
        let frameCount: Int?
        let timeBase: AVRational
        let language: String?
        let kind: Kind

        enum Kind: Sendable { case text, forcedBitmap, bitmap }
    }

    /// The session's indexed-subtitle state, shared with the fill tasks.
    final class IndexedSubtitleState: @unchecked Sendable {
        let index: MatroskaSubtitleIndex
        let plans: [Int: IndexedRenditionPlan]
        private let root: IOReader
        private let lock = NSLock()
        /// Per ordinal, which of its blocks a bitmap fill has recognized.
        private var processed: [Int: [Bool]] = [:]

        init(index: MatroskaSubtitleIndex, plans: [Int: IndexedRenditionPlan], root: IOReader) {
            self.index = index
            self.plans = plans
            self.root = root
        }

        /// A reader of its own for one lane of work; closed by the caller.
        func makeSource() -> IOReaderByteSource? { root.makeIndependentReader().map(IOReaderByteSource.init) }

        func processedBlocks(_ ordinal: Int, count: Int) -> [Bool] {
            lock.lock(); defer { lock.unlock() }
            return processed[ordinal] ?? [Bool](repeating: false, count: count)
        }

        func markProcessed(_ ordinal: Int, _ indices: [Int], count: Int) {
            lock.lock(); defer { lock.unlock() }
            var marks = processed[ordinal] ?? [Bool](repeating: false, count: count)
            for i in indices where i < marks.count { marks[i] = true }
            processed[ordinal] = marks
        }

        func close() { root.close() }
    }

    /// Parallel readers for block fetches: remote range reads cost a round trip each (about 40 ms
    /// measured through a reverse proxy), so they go out side by side.
    nonisolated static let indexedSubtitleReadLanes = 12

    // MARK: - Load

    /// Reads the index and fills what it can, off the main actor. Called once per load, after the
    /// native subtitle stores exist.
    func startIndexedSubtitleFill(session: HLSVideoEngine, url: URL) {
        cancelIndexedSubtitleFill()
        guard !loadedOptions.isLive, let demuxer = session.demuxer,
              demuxer.containerFormatName?.contains("matroska") == true else { return }
        let stores = session.nativeSubtitleCueStoresForSession
        // Every subtitle stream in order (they map onto the TrackEntries by order), with the facts the
        // renditions need from them.
        var streams: [MatroskaSubtitleIndex.SubtitleStream] = []
        var facts: [Int32: (frames: Int?, timeBase: AVRational)] = [:]
        var index: Int32 = 0
        while let stream = demuxer.withStream(at: index, { st -> (MatroskaSubtitleIndex.SubtitleStream, Int?, AVRational)? in
            guard st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { return nil }
            func tag(_ key: String) -> String? {
                av_dict_get(st.pointee.metadata, key, nil, AV_DICT_IGNORE_SUFFIX).map { String(cString: $0.pointee.value) }
            }
            let frames = tag("NUMBER_OF_FRAMES").flatMap { Int($0) }
            let subtitle = MatroskaSubtitleIndex.SubtitleStream(
                streamIndex: index, trackID: st.pointee.id,
                codecName: String(cString: avcodec_get_name(st.pointee.codecpar.pointee.codec_id)),
                language: av_dict_get(st.pointee.metadata, "language", nil, 0).map { String(cString: $0.pointee.value) },
                frames: frames, bytes: tag("NUMBER_OF_BYTES").flatMap { Int64($0) })
            return (subtitle, frames, st.pointee.time_base)
        }) {
            if let (subtitle, frames, timeBase) = stream {
                streams.append(subtitle)
                facts[index] = (frames, timeBase)
            }
            index += 1
        }
        var pending: [(ordinal: Int, stream: Int32, kind: IndexedRenditionPlan.Kind, language: String?)] = []
        for (ordinal, entry) in nativeSubtitleTrackTable.enumerated() {
            guard ordinal < stores.count, let stream = entry.sourceStreamIndex, entry.externalID == nil,
                  facts[Int32(stream)] != nil else { continue }
            let kind: IndexedRenditionPlan.Kind = !entry.needsOCR ? .text
                : entry.forcedCuesOnly ? .forcedBitmap : .bitmap
            pending.append((ordinal, Int32(stream), kind, entry.language))
        }
        guard !pending.isEmpty else { return }

        let opener = indexedSubtitleReaderOpener(url: url)
        let duration = duration
        indexedSubtitleTask = BlockingWork.detached(priority: .utility) { [weak self] in
            guard let root = opener() else {
                EngineLog.emit("[IndexedSubtitles] source not range-readable; the stream-walking fill stays",
                               category: .engine)
                return
            }
            let source = IOReaderByteSource(root)
            let began = Date()
            let index: MatroskaSubtitleIndex
            do {
                index = try MatroskaSubtitleIndex.read(from: source)
            } catch {
                EngineLog.emit("[IndexedSubtitles] no usable index (\(error)); the stream-walking fill stays",
                               category: .engine)
                root.close()
                return
            }
            let tracks = index.trackNumbers(for: streams)
            guard !tracks.isEmpty else {
                EngineLog.emit("[IndexedSubtitles] the subtitle streams do not line up with the file's tracks "
                               + "(\(streams.count) streams, \(index.subtitleTracks.count) tracks); "
                               + "the stream-walking fill stays", category: .engine)
                root.close()
                return
            }
            var complete: [Int: IndexedRenditionPlan] = [:]
            for item in pending {
                guard let track = tracks[item.stream], let fact = facts[item.stream],
                      index.isComplete(track: track, frameCount: fact.frames) else { continue }
                complete[item.ordinal] = IndexedRenditionPlan(
                    ordinal: item.ordinal, streamIndex: item.stream, trackNumber: track, frameCount: fact.frames,
                    timeBase: fact.timeBase, language: item.language, kind: item.kind)
            }
            let refused = pending.count - complete.count
            EngineLog.emit("[IndexedSubtitles] index read in \(Int(Date().timeIntervalSince(began) * 1000)) ms: "
                           + "\(complete.count) of \(pending.count) renditions provably complete in it"
                           + (refused > 0 ? " (\(refused) left to the stream-walking fill)" : ""),
                           category: .engine)
            guard !complete.isEmpty, !Task.isCancelled else { root.close(); return }
            let state = IndexedSubtitleState(index: index, plans: complete, root: root)
            let installed = await MainActor.run { [weak self] () -> Bool in
                guard let self, !Task.isCancelled else { return false }
                self.indexedSubtitles = state
                return true
            }
            guard installed else { state.close(); return }

            for plan in complete.values.sorted(by: { $0.ordinal < $1.ordinal }) where plan.kind == .text {
                guard !Task.isCancelled else { return }
                await self?.fillIndexedText(plan, state: state, duration: duration, stores: stores)
            }
            for plan in complete.values where plan.kind == .forcedBitmap {
                guard !Task.isCancelled else { return }
                await self?.fillIndexedForced(plan, state: state, duration: duration, stores: stores)
            }
        }
    }

    /// A range reader over the session's source, opened off the main actor.
    private func indexedSubtitleReaderOpener(url: URL) -> @Sendable () -> IOReader? {
        if isCustomSource {
            let clone = customReader?.makeIndependentReader()
            return { clone }
        }
        if url.isFileURL { return { FileIOReader(url: url) } }
        var headers = loadedOptions.httpHeaders
        headers.merge(sessionRequestHeaders.current) { _, new in new }
        let resolved = headers
        return {
            HTTPDiscIOReader(url: url, extraHeaders: resolved, baseChunkSize: 4096, maxChunkSize: 4 * 1024 * 1024)
        }
    }

    func cancelIndexedSubtitleFill() {
        indexedSubtitleTask?.cancel()
        indexedSubtitleTask = nil
        indexedBitmapFillTask?.cancel()
        indexedBitmapFillTask = nil
        indexedBitmapFillOrdinal = nil
        indexedSubtitles?.close()
        indexedSubtitles = nil
    }

    // MARK: - Text

    /// Every block of a text track, decoded in order into its store, which is then complete.
    nonisolated private func fillIndexedText(_ plan: IndexedRenditionPlan, state: IndexedSubtitleState,
                                             duration: Double, stores: [NativeSubtitleCueStore]) async {
        guard plan.ordinal < stores.count, let blocks = state.index.blocksByTrack[plan.trackNumber],
              let decoder = await makeIndexedDecoder(plan) else { return }
        let store = stores[plan.ordinal]
        let began = Date()
        let frames = Self.readFrames(blocks.indices.map { ($0, blocks[$0]) }, track: plan.trackNumber,
                                     state: state, prefix: nil)
        guard !Task.isCancelled else { return }
        var cues: [SubtitleCue] = []
        var missing = 0
        for i in blocks.indices {
            guard let frame = frames[i] else { missing += 1; continue }
            if let event = Self.decode(frame, plan: plan, index: state.index, decoder: decoder) {
                cues.append(contentsOf: event.cues)
            }
        }
        guard missing == 0 else {
            store.appendCues(cues)
            EngineLog.emit("[IndexedSubtitles] text ordinal=\(plan.ordinal): \(missing) of \(blocks.count) blocks "
                           + "unreadable; its \(cues.count) cues are a head start, the rendition stays open",
                           category: .engine)
            return
        }
        store.appendCues(cues)
        store.noteRead(from: 0, through: max(duration, cues.map(\.endTime).max() ?? 0))
        store.markFinished()
        EngineLog.emit("[IndexedSubtitles] text ordinal=\(plan.ordinal) complete: \(blocks.count) blocks, "
                       + "\(cues.count) cues in \(Int(Date().timeIntervalSince(began) * 1000)) ms",
                       category: .engine)
        await MainActor.run { [weak self] in self?.indexedRenditionCompleted(plan.ordinal) }
    }

    // MARK: - Forced bitmap

    /// The forced lines of a bitmap track: every display set's composition header is read (a few hundred
    /// bytes each), and only the display sets that carry a forced object are decoded, each from the last
    /// self-contained display set before it, and recognized. A forced line ends where the track's next
    /// display set begins.
    nonisolated private func fillIndexedForced(_ plan: IndexedRenditionPlan, state: IndexedSubtitleState,
                                               duration: Double, stores: [NativeSubtitleCueStore]) async {
        guard plan.ordinal < stores.count, let blocks = state.index.blocksByTrack[plan.trackNumber] else { return }
        let store = stores[plan.ordinal]
        let began = Date()
        let prefixes = Self.readFrames(blocks.indices.map { ($0, blocks[$0]) }, track: plan.trackNumber,
                                       state: state, prefix: 512)
        let headers: [PGSCompositionHeader?] = blocks.indices.map { i in
            prefixes[i].flatMap { PGSCompositionHeader.parse($0.payload) }
        }
        guard !Task.isCancelled else { return }
        let unreadable = headers.filter { $0 == nil }.count
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
        var cues: [SubtitleCue] = []
        for run in runs {
            guard !Task.isCancelled, let decoder = await makeIndexedDecoder(plan) else { return }
            let frames = Self.readFrames(run.map { ($0, blocks[$0]) }, track: plan.trackNumber,
                                         state: state, prefix: nil)
            for i in run {
                guard let frame = frames[i],
                      let event = Self.decode(frame, plan: plan, index: state.index, decoder: decoder),
                      headers[i]?.isForced == true else { continue }
                let next = i + 1 < blocks.count ? state.index.seconds(ticks: blocks[i + 1].ticks) : duration
                cues.append(contentsOf: event.cues.filter(\.isForced).map { $0.with(endTime: min($0.endTime, next)) })
            }
        }
        if !cues.isEmpty {
            await SubtitleImageOCR.appendRecognized(cues: cues, language: plan.language, to: store)
        }
        guard !Task.isCancelled else { return }
        guard unreadable == 0 else {
            EngineLog.emit("[IndexedSubtitles] forced ordinal=\(plan.ordinal): \(unreadable) of \(blocks.count) "
                           + "headers unreadable; \(cues.count) forced lines are a head start, the rendition stays open",
                           category: .engine)
            return
        }
        store.noteRead(from: 0, through: max(duration, cues.map(\.endTime).max() ?? 0))
        store.markFinished()
        EngineLog.emit("[IndexedSubtitles] forced ordinal=\(plan.ordinal) complete: \(blocks.count) display sets, "
                       + "\(forced.count) forced, \(cues.count) lines recognized in "
                       + "\(Int(Date().timeIntervalSince(began) * 1000)) ms", category: .engine)
        await MainActor.run { [weak self] in self?.indexedRenditionCompleted(plan.ordinal) }
    }

    // MARK: - Full bitmap, on demand

    /// Recognizes a selected bitmap track from its index: from the display set the playhead is in, on
    /// to the end, then from the start. Each run starts on a self-contained display set with a decoder
    /// of its own; a seek that leaves the run starts a new one at the playhead. The store's reading
    /// follows the run around the playhead, so the segment server knows what is truly empty. Returns
    /// false when the index does not cover the ordinal, and the OCR worker should serve it instead.
    func startIndexedBitmapFill(ordinal: Int) -> Bool {
        guard let state = indexedSubtitles, let plan = state.plans[ordinal], plan.kind != .text,
              let store = nativeStore(atOrdinal: ordinal) else { return false }
        if plan.kind == .forcedBitmap || store.isFinished { return true }   // the load-time fill owns it
        if indexedBitmapFillOrdinal == ordinal, indexedBitmapFillTask != nil { return true }
        indexedBitmapFillTask?.cancel()
        indexedBitmapFillOrdinal = ordinal
        store.markFeeding()
        let duration = duration
        EngineLog.emit("[IndexedSubtitles] bitmap ordinal=\(ordinal) recognized from the index, from the playhead",
                       category: .engine)
        indexedBitmapFillTask = BlockingWork.detached(priority: .utility) { [weak self] in
            await self?.runIndexedBitmapFill(plan, state: state, store: store, duration: duration)
        }
        return true
    }

    nonisolated private func runIndexedBitmapFill(_ plan: IndexedRenditionPlan, state: IndexedSubtitleState,
                                                  store: NativeSubtitleCueStore, duration: Double) async {
        guard let blocks = state.index.blocksByTrack[plan.trackNumber] else { return }
        let index = state.index
        let batch = 24
        while !Task.isCancelled {
            let done = state.processedBlocks(plan.ordinal, count: blocks.count)
            guard let playhead = await MainActor.run(body: { [weak self] in self?.sourceTime }) else { return }
            // The first block not yet recognized at or after the playhead, else the first one at all.
            let here = blocks.firstIndex { index.seconds(ticks: $0.ticks) >= playhead - 5 } ?? blocks.count
            guard let start = (here..<blocks.count).first(where: { !done[$0] })
                    ?? (0..<blocks.count).first(where: { !done[$0] }) else {
                store.noteRead(from: 0, through: duration)
                store.markFinished()
                EngineLog.emit("[IndexedSubtitles] bitmap ordinal=\(plan.ordinal) complete: \(blocks.count) display sets",
                               category: .engine)
                return
            }
            let aroundPlayhead = start >= here
            guard let decoder = await makeIndexedDecoder(plan) else { return }
            // Back to the self-contained display set this one builds on.
            var cursor = start
            var lookback = 0
            while cursor > 0, lookback < 16 {
                guard let frame = Self.readFrames([(cursor, blocks[cursor])], track: plan.trackNumber,
                                                  state: state, prefix: 512)[cursor],
                      let header = PGSCompositionHeader.parse(frame.payload), !header.isSelfContained else { break }
                cursor -= 1
                lookback += 1
            }
            let runStart = index.seconds(ticks: blocks[cursor].ticks)
            // Forward from there in batches, until the run meets recognized ground, ends, or the viewer
            // seeks away from it.
            while !Task.isCancelled, cursor < blocks.count {
                let upper = min(blocks.count, cursor + batch)
                let range = Array(cursor..<upper)
                let frames = Self.readFrames(range.map { ($0, blocks[$0]) }, track: plan.trackNumber,
                                             state: state, prefix: nil)
                var cues: [SubtitleCue] = []
                for i in range {
                    guard let frame = frames[i],
                          let event = Self.decode(frame, plan: plan, index: index, decoder: decoder) else { continue }
                    let next = i + 1 < blocks.count ? index.seconds(ticks: blocks[i + 1].ticks) : duration
                    cues.append(contentsOf: event.cues.map { $0.with(endTime: min($0.endTime, next)) })
                }
                if !cues.isEmpty {
                    await SubtitleImageOCR.appendRecognized(cues: cues, language: plan.language, to: store)
                }
                state.markProcessed(plan.ordinal, range, count: blocks.count)
                cursor = upper
                let through = cursor < blocks.count ? index.seconds(ticks: blocks[cursor].ticks) : duration
                if aroundPlayhead { store.noteRead(from: runStart, through: through) }
                let nowDone = state.processedBlocks(plan.ordinal, count: blocks.count)
                if cursor < blocks.count, nowDone[cursor] { break }
                guard let now = await MainActor.run(body: { [weak self] in self?.sourceTime }) else { return }
                if aroundPlayhead, now < runStart - 5 || now > through + 30 { break }
            }
        }
    }

    // MARK: - Shared

    /// After a rendition became complete from the index: the stream-walking feeders it no longer needs
    /// stand down.
    func indexedRenditionCompleted(_ ordinal: Int) {
        if subtitleOCRArmedOrdinal == ordinal, indexedSubtitles?.plans[ordinal]?.kind == .forcedBitmap {
            cancelSubtitleOCRWorker()
        }
        let stores = nativeSubtitleReaderParams?.stores ?? []
        let readerRouted = nativeSubtitleTrackTable.indices.filter {
            $0 < stores.count && nativeSubtitleTrackTable[$0].sourceStreamIndex != nil
                && !nativeSubtitleTrackTable[$0].needsOCR && nativeSubtitleTrackTable[$0].externalID == nil
        }
        if nativeSubtitleReadersTask != nil, readerRouted.allSatisfy({ stores[$0].isFinished }) {
            EngineLog.emit("[IndexedSubtitles] every text rendition is complete; the side readers stand down",
                           category: .engine)
            cancelNativeSubtitleReaders()
        }
    }

    /// A decoder for `plan`'s stream, made the way the overlay's are so its cues match the tap's.
    nonisolated private func makeIndexedDecoder(_ plan: IndexedRenditionPlan) async -> EmbeddedSubtitleDecoder? {
        // Handed over once and then used by this fill alone, as the OCR worker's tick plan does.
        struct Handoff: @unchecked Sendable { let decoder: EmbeddedSubtitleDecoder? }
        return await MainActor.run { [weak self] in
            Handoff(decoder: self?.makeSubtitleDrainDecoder(streamIndex: plan.streamIndex))
        }.decoder
    }

    /// `items` read on parallel lanes; the result is indexed like the blocks' positions in the track.
    nonisolated static func readFrames(_ items: [(Int, MatroskaSubtitleIndex.Block)], track: UInt64,
                                       state: IndexedSubtitleState, prefix: Int?) -> [Int: MatroskaSubtitleIndex.Frame] {
        guard !items.isEmpty else { return [:] }
        let laneCount = min(indexedSubtitleReadLanes, items.count)
        let sources = (0..<laneCount).compactMap { _ in state.makeSource() }
        defer { sources.forEach { $0.close() } }
        guard !sources.isEmpty else { return [:] }
        let lock = NSLock()
        var out: [Int: MatroskaSubtitleIndex.Frame] = [:]
        DispatchQueue.concurrentPerform(iterations: sources.count) { lane in
            var k = lane
            while k < items.count, !Task.isCancelled {
                let (position, block) = items[k]
                if let frame = state.index.readFrame(block, track: track, from: sources[lane], prefix: prefix) {
                    lock.lock(); out[position] = frame; lock.unlock()
                }
                k += sources.count
            }
        }
        return out
    }

    /// One frame through the decoder, timed on the stream's time base.
    nonisolated static func decode(_ frame: MatroskaSubtitleIndex.Frame, plan: IndexedRenditionPlan,
                                   index: MatroskaSubtitleIndex,
                                   decoder: EmbeddedSubtitleDecoder) -> EmbeddedSubtitleDecoder.SubtitleEvent? {
        guard !frame.payload.isEmpty, let packet = trackedPacketAlloc() else { return nil }
        defer { var p: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&p) }
        guard av_new_packet(packet, Int32(frame.payload.count)) == 0 else { return nil }
        frame.payload.withUnsafeBufferPointer { packet.pointee.data.update(from: $0.baseAddress!, count: $0.count) }
        let nanosPerTick = index.timestampScale
        let toStream = { (ticks: Int64) -> Int64 in
            av_rescale_q(ticks, AVRational(num: Int32(clamping: nanosPerTick), den: 1_000_000_000), plan.timeBase)
        }
        packet.pointee.pts = toStream(frame.ticks)
        packet.pointee.dts = packet.pointee.pts
        if let duration = frame.durationTicks { packet.pointee.duration = toStream(duration) }
        return decoder.decode(packet: packet, streamTimeBase: plan.timeBase)
    }
}
