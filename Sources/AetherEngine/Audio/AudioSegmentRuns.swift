import AetherLibavcodec
import AetherLibavutil
import Foundation

/// A producer's segments as its bridged audio is routed to them (`HLSSegmentProducer`): segment
/// `baseIndex + i` holds the output whose routed time, its pts less the audio delay the bridge stamps
/// in, falls in the plan's [boundaries[i], boundaries[i + 1]), the first and the last open-ended.
struct AudioRunPlan {
    let baseIndex: Int
    /// The plan's boundaries from the producer's first segment on: absolute, video time base.
    let boundaries: [Int64]
    let planAnchor: Int64
    let videoTimeBase: AVRational
    /// The bridge's output time base, which routed time is counted in.
    let outputTimeBase: AVRational
    /// The audio delay the bridge stamps into its output (`setOutputOffset`), output ticks.
    let delayTicks: Int64

    /// The segment output stamped `pts` belongs to.
    func segment(ofOutputPts pts: Int64) -> Int {
        segment(ofRouted: pts &- delayTicks)
    }

    func segment(ofRouted ticks: Int64) -> Int {
        baseIndex + HLSSegmentProducer.segmentOffset(
            forAbsolutePts: av_rescale_q(ticks, outputTimeBase, videoTimeBase) &+ planAnchor,
            boundaries: boundaries)
    }

    /// The first routed tick of segment `index`, nil past the plan's last segment. The producer's
    /// first segment starts at its boundary: routing puts everything before it there too, and nothing
    /// before it is made.
    func start(ofSegment index: Int) -> Int64? {
        let i = index - baseIndex
        guard i >= 0, i <= boundaries.count - 2 else { return nil }
        var tick = av_rescale_q(boundaries[i] &- planAnchor, videoTimeBase, outputTimeBase)
        guard i > 0 else { return tick }
        // The rescale rounds; the tick routing itself starts the segment at is the one that counts.
        while segment(ofRouted: tick - 1) >= index { tick -= 1 }
        while segment(ofRouted: tick) < index { tick += 1 }
        return tick
    }
}

/// VOD audio made a segment at a time, so a segment comes out the same however playback reached it.
///
/// One bridge run for a whole session puts into segment N whatever its decoder, resampler and
/// encoder carried over from where the run began, and a seek begins a run somewhere else; most of
/// those stages forget their start only to within rounding, the encoders' rate control never. So
/// each segment's audio comes from a run of its own (a fresh bridge from `makeRun`), started on the
/// output's packet grid at least the encoder's memory before the segment's first packet, and fed
/// from the source the rest of the run's declared memory before that (`AudioTranscodingBridge.runSpan`).
/// The grid is the output timeline's, from its zero, so a run's packets fall where its neighbours'
/// do.
/// Its output from the segment's first packet up to the next segment's is the segment; before that
/// it only settles the stages. Continuous playback runs the same runs from the same packets, the
/// next one starting while the last finishes from packets kept here (`ring`), so the same segment
/// comes out byte for byte either way. Where a stage has not forgotten its start by the segment's
/// first packet, two adjacent segments meet with that much difference at their seam.
///
/// A run is fed from the last packet at or before where its memory reaches, except MP3's, which
/// starts at the packet its first needed frame's main data begins in (`MP3MainData`): the format's
/// worst case is seconds, the stream's own reservoir rarely a frame or two.
///
/// The engine holds one, built from the session's template; every producer feeds a session of its
/// own (`producerBridge()`), which it ends when its pump does (`producerFinished()`). So a producer
/// a restart abandoned can only ever feed runs no one reads, and a restart needs nothing from the
/// engine's: the new producer's session starts clean.
final class AudioSegmentRuns: AudioTranscodingBridge, @unchecked Sendable {

    /// What the engine's and every producer's sessions share.
    private final class Shared: @unchecked Sendable {
        /// Unfed: its parameters and sample entry describe every run's output, and the muxer holds them.
        let template: any AudioTranscodingBridge
        let makeRun: () throws -> any AudioTranscodingBridge
        let lock = NSLock()
        /// Over the whole session: what every retired run counted, and the bytes handed on.
        var retiredStats = AudioBridge.FeedStats()
        var bytesOut: Int64 = 0
        /// The latest producer's session, which the engine's reports for.
        weak var current: AudioSegmentRuns?
        init(template: any AudioTranscodingBridge, makeRun: @escaping () throws -> any AudioTranscodingBridge) {
            self.template = template
            self.makeRun = makeRun
        }
    }

    private final class Run {
        let segment: Int
        let start: Int64
        let end: Int64?
        let bridge: any AudioTranscodingBridge
        var held: [UnsafeMutablePointer<AVPacket>] = []
        /// It handed over a packet of the next segment: everything of its own is out.
        var finished = false
        init(segment: Int, start: Int64, end: Int64?, bridge: any AudioTranscodingBridge) {
            self.segment = segment
            self.start = start
            self.end = end
            self.bridge = bridge
        }
    }

    private let shared: Shared
    /// A producer's session, not the engine's.
    private let isSession: Bool
    private var template: any AudioTranscodingBridge { shared.template }
    private let sourceTimeBase: AVRational
    private let packetFrames: Int64
    /// Before a run's encoder starts: what the stages ahead of it need fed.
    private let preEncoderMemory: Int64
    private let encoderMemory: Int64
    /// MP3's decoder memory as `AudioStageSpan` bounds it, and the part of it that is not the
    /// reservoir (`AudioStageSpan.mp3OverlapFrames`), output ticks; nil for another codec.
    private let mp3DecoderMemory: (bound: Int64, overlap: Int64)?
    /// Packets kept for the next run: its memory, and a second for the longest source packet.
    private let ringTicks: Int64

    private let lock = NSLock()
    private var plan: AudioRunPlan?
    private var nextSegment: Int?
    private var runs: [Run] = []
    private var ring: [UnsafeMutablePointer<AVPacket>] = []
    private var sourceStart: Int64?
    private var outputOffsetSeconds: Double = 0
    private var reportedMissingPlan = false
    private var runsStartedShort = 0

    /// Nil where the template states no `runSpan`: with a stage's memory unknown, no run start can
    /// be said to settle it.
    init?(template: any AudioTranscodingBridge, sourceCodecpar: UnsafePointer<AVCodecParameters>,
          sourceTimeBase: AVRational, makeRun: @escaping () throws -> any AudioTranscodingBridge) {
        guard let span = template.runSpan else { return nil }
        shared = Shared(template: template, makeRun: makeRun)
        isSession = false
        self.sourceTimeBase = sourceTimeBase
        packetFrames = Int64(max(template.runPacketFrames, 1))
        encoderMemory = Int64(template.runEncoderMemory)
        preEncoderMemory = Int64(span.memory) - encoderMemory
        let outputRate = Int64(template.encoderTimeBase.den / max(template.encoderTimeBase.num, 1))
        let par = sourceCodecpar.pointee
        let sampleRate = Int64(par.sample_rate)
        mp3DecoderMemory = par.codec_id == AV_CODEC_ID_MP3 && sampleRate > 0
            ? (bound: Int64(AudioStageSpan.mp3DecoderMemory(sampleRate: Int(sampleRate),
                                                            channels: Int(par.ch_layout.nb_channels)))
                   * outputRate / sampleRate,
               overlap: (Int64(AudioStageSpan.mp3OverlapFrames) * outputRate + sampleRate - 1) / sampleRate)
            : nil
        ringTicks = preEncoderMemory + outputRate
    }

    private init(sessionOf engine: AudioSegmentRuns) {
        shared = engine.shared
        isSession = true
        sourceTimeBase = engine.sourceTimeBase
        packetFrames = engine.packetFrames
        encoderMemory = engine.encoderMemory
        preEncoderMemory = engine.preEncoderMemory
        mp3DecoderMemory = engine.mp3DecoderMemory
        ringTicks = engine.ringTicks
    }

    /// A session of its own for a producer to feed; the engine's latest.
    func producerBridge() -> any AudioTranscodingBridge {
        let session = AudioSegmentRuns(sessionOf: self)
        shared.lock.withLock { shared.current = session }
        return session
    }

    /// The producer's pump is done: its runs go, whatever it left unread.
    func producerFinished() {
        lock.lock()
        defer { lock.unlock() }
        closeRuns()
    }

    /// How far before a segment's start its run reads the source: the encoder's memory on the packet
    /// grid, the packet the segment starts in, the stages ahead of the encoder, and a source packet.
    var preRollSeconds: Double {
        let outputRate = Double(template.encoderTimeBase.den) / Double(max(template.encoderTimeBase.num, 1))
        let leadPackets = (encoderMemory + packetFrames - 1) / packetFrames + 1
        return Double(leadPackets * packetFrames + preEncoderMemory) / outputRate + Self.longestSourcePacketSeconds
    }

    /// Longer than any packet of a bridged codec: Vorbis's longest block at 8 kHz is 0.5 s.
    private static let longestSourcePacketSeconds = 0.5

    // MARK: Template

    var encoderCodecpar: UnsafeMutablePointer<AVCodecParameters>? { template.encoderCodecpar }
    var encoderTimeBase: AVRational { template.encoderTimeBase }
    var soundSampleEntryOverride: Data? { template.soundSampleEntryOverride }
    var servedChannelCount: Int? { template.servedChannelCount }
    var peakOutputBitRate: Int64 { template.peakOutputBitRate }
    var runSpan: AudioStageSpan? { template.runSpan }
    var runEncoderMemory: Int { template.runEncoderMemory }
    var runPacketFrames: Int { template.runPacketFrames }
    var presentationDelay: Int64 { template.presentationDelay }

    // MARK: Runs

    func setRunPlan(_ plan: AudioRunPlan) {
        lock.lock()
        defer { lock.unlock() }
        closeRuns()
        self.plan = plan
        nextSegment = plan.start(ofSegment: plan.baseIndex) != nil ? plan.baseIndex : nil
    }

    func setSourceStart(_ pts: Int64?) {
        lock.lock()
        defer { lock.unlock() }
        sourceStart = pts
    }

    func setOutputOffset(seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        outputOffsetSeconds = seconds
    }

    /// Runs are started here, each on its own grid point.
    func startRun(atFrame frame: Int64, segment: Range<Int64>) {}

    func feed(packet: UnsafePointer<AVPacket>) throws -> [UnsafeMutablePointer<AVPacket>] {
        lock.lock()
        defer { lock.unlock() }
        guard let plan else {
            if !reportedMissingPlan {
                reportedMissingPlan = true
                EngineLog.emit("[AudioSegmentRuns] ERROR: fed before the producer gave its segments; audio dropped",
                               category: .session)
            }
            return []
        }
        guard let kept = av_packet_clone(packet) else { return [] }
        ring.append(kept)
        if let at = ticks(of: packet) {
            let end = at + max(av_rescale_q(packet.pointee.duration, sourceTimeBase, encoderTimeBase), 1)
            // Every run whose encoder starts by the end of this packet (on the output timeline, where
            // the offset puts it): what its stages need before that is in `ring`.
            while let n = nextSegment, let start = gridStart(of: n, plan: plan), end &+ plan.delayTicks > start {
                openRun(n, at: start, plan: plan)
                nextSegment = plan.start(ofSegment: n + 1) != nil ? n + 1 : nil
            }
            prune(before: at - ringTicks)
        }
        for run in runs where !run.finished {
            accept(feedRun(run, packet), into: run)
        }
        return release()
    }

    func settle() -> [UnsafeMutablePointer<AVPacket>] {
        lock.lock()
        defer { lock.unlock() }
        for run in runs where !run.finished { accept(run.bridge.settle(), into: run) }
        return release()
    }

    func flush() -> [UnsafeMutablePointer<AVPacket>] {
        lock.lock()
        defer { lock.unlock() }
        for run in runs where !run.finished {
            accept(run.bridge.flush(), into: run)
            run.finished = true
        }
        let out = release()
        freeRing()
        nextSegment = nil
        return out
    }

    /// A restart. The new producer feeds a session of its own, so the engine's has only the
    /// session-wide part of the template to restart (its level window).
    func startSegment() {
        if isSession {
            lock.lock()
            defer { lock.unlock() }
            closeRuns()
            plan = nil
            nextSegment = nil
        } else {
            template.startSegment()
        }
    }

    func noteTimelineJump(deltaSeconds: Double) {}

    func close() {
        lock.lock()
        closeRuns()
        lock.unlock()
        guard !isSession else { return }
        shared.lock.withLock { shared.current }?.producerFinished()
        template.close()
    }

    // MARK: Telemetry

    /// The engine's reports for the latest producer's session; a session for itself.
    private var reporting: AudioSegmentRuns? { isSession ? self : shared.lock.withLock { shared.current } }

    /// The session's whole: every retired run, and the reporting session's runs still going.
    var feedStats: AudioBridge.FeedStats {
        let retired = shared.lock.withLock { shared.retiredStats }
        guard let session = reporting else { return retired }
        session.lock.lock()
        defer { session.lock.unlock() }
        var total = session.runs.reduce(retired) { $0.adding($1.bridge.feedStats) }
        total.packetsFedSinceLastEnqueue = session.runs.last?.bridge.feedStats.packetsFedSinceLastEnqueue
            ?? retired.packetsFedSinceLastEnqueue
        return total
    }

    var liveBytes: AudioBridge.LiveBytes {
        let zero = AudioBridge.LiveBytes(fifoSamples: 0, fifoBytes: 0, swrDelaySamples: 0, swrDelayBytes: 0)
        guard let session = reporting else { return zero }
        session.lock.lock()
        defer { session.lock.unlock() }
        return session.runs.map(\.bridge.liveBytes).reduce(zero) {
            AudioBridge.LiveBytes(fifoSamples: $0.fifoSamples + $1.fifoSamples, fifoBytes: $0.fifoBytes + $1.fifoBytes,
                                  swrDelaySamples: $0.swrDelaySamples + $1.swrDelaySamples,
                                  swrDelayBytes: $0.swrDelayBytes + $1.swrDelayBytes)
        }
    }

    var fifoSampleCount: Int {
        guard let session = reporting else { return 0 }
        session.lock.lock()
        defer { session.lock.unlock() }
        return session.runs.reduce(0) { $0 + $1.bridge.fifoSampleCount }
    }

    var outputBytesLifetime: Int64 { shared.lock.withLock { shared.bytesOut } }

    var objectAudioActivity: ObjectAudioActivity? {
        guard let session = reporting else { return nil }
        session.lock.lock()
        defer { session.lock.unlock() }
        return session.runs.last?.bridge.objectAudioActivity
    }

    // MARK: Private (callers hold `lock`)

    /// Where `packet` starts on the routed axis, output ticks.
    private func ticks(of packet: UnsafePointer<AVPacket>) -> Int64? {
        let ts = packet.pointee.pts != Int64.min ? packet.pointee.pts : packet.pointee.dts
        return ts == Int64.min ? nil : av_rescale_q(ts, sourceTimeBase, encoderTimeBase)
    }

    /// Where segment `index`'s run starts its encoder on the output timeline: on the packet grid, the
    /// encoder's memory in whole packets before the segment's first packet, and never before the
    /// timeline's start, so the first segment's run begins with the encoder's own priming as a
    /// single run would.
    private func gridStart(of index: Int, plan: AudioRunPlan) -> Int64? {
        guard let start = plan.start(ofSegment: index) else { return nil }
        let first = Self.ceil(start &+ plan.delayTicks, packetFrames) * packetFrames
        let lead = Self.ceil(encoderMemory, packetFrames) * packetFrames
        return max(first - lead, 0)
    }

    private static func ceil(_ a: Int64, _ b: Int64) -> Int64 {
        a >= 0 ? (a + b - 1) / b : -((-a) / b)
    }

    private func openRun(_ index: Int, at gridStart: Int64, plan: AudioRunPlan) {
        let bridge: any AudioTranscodingBridge
        do {
            bridge = try shared.makeRun()
        } catch {
            EngineLog.emit("[AudioSegmentRuns] ERROR: segment \(index)'s run did not open (\(error)); its audio is missing",
                           category: .session)
            return
        }
        bridge.setSourceStart(sourceStart)
        bridge.setOutputOffset(seconds: outputOffsetSeconds)
        let run = Run(segment: index, start: plan.start(ofSegment: index) ?? gridStart,
                      end: plan.start(ofSegment: index + 1), bridge: bridge)
        bridge.startRun(atFrame: gridStart,
                        segment: (run.start &+ plan.delayTicks)..<(run.end.map { $0 &+ plan.delayTicks } ?? Int64.max))
        runs.append(run)
        // The packet being fed is in `ring` already and goes to every run after this.
        let available = ring.count - 1
        // Where the run starts, on the axis the source is fed on.
        let fedStart = gridStart &- plan.delayTicks
        let first = firstPacket(before: available, gridStart: fedStart)
        // Short: the source was read from later than the run needs, and not because the stream
        // itself starts there.
        let streamStart = sourceStart.map { av_rescale_q($0, sourceTimeBase, encoderTimeBase) }
        if first == 0, let earliest = ring.first.flatMap({ ticks(of: $0) }),
           earliest > fedStart - preEncoderMemory, earliest > (streamStart ?? Int64.min) {
            runsStartedShort += 1
            EngineLog.emit("[AudioSegmentRuns] segment \(index)'s run starts \(earliest - (fedStart - preEncoderMemory)) "
                           + "ticks short of its memory (\(runsStartedShort) so far): the source was not read from there",
                           category: .session)
        }
        for i in first..<available {
            accept(feedRun(run, ring[i]), into: run)
        }
    }

    /// The first `ring` packet (of those before `limit`) a run starting its encoder at `gridStart`
    /// is fed.
    private func firstPacket(before limit: Int, gridStart: Int64) -> Int {
        func lastStarting(atOrBefore target: Int64) -> Int {
            var index = 0
            for i in 0..<limit {
                guard let t = ticks(of: ring[i]) else { continue }
                if t <= target { index = i } else { break }
            }
            return index
        }
        let declared = lastStarting(atOrBefore: gridStart - preEncoderMemory)
        guard let mp3 = mp3DecoderMemory else { return declared }
        // The first frame whose output the run needs right (the one the synthesis window and the
        // IMDCT overlap reach back into), then the packet its main data begins in.
        let needed = lastStarting(atOrBefore: gridStart - (preEncoderMemory - mp3.bound) - mp3.overlap)
        let buffers = ring[0..<limit].map { UnsafeRawBufferPointer(start: $0.pointee.data, count: Int($0.pointee.size)) }
        return MP3MainData.firstPacket(feeding: needed, of: buffers) ?? declared
    }

    private func feedRun(_ run: Run, _ packet: UnsafePointer<AVPacket>) -> [UnsafeMutablePointer<AVPacket>] {
        do {
            return try run.bridge.feed(packet: packet)
        } catch {
            EngineLog.emit("[AudioSegmentRuns] segment \(run.segment)'s run: \(error)", category: .session)
            return []
        }
    }

    /// Keep what is the run's own segment; earlier output only settled its stages, and output of the
    /// next segment means the run is done.
    private func accept(_ packets: [UnsafeMutablePointer<AVPacket>], into run: Run) {
        for packet in packets {
            var p: UnsafeMutablePointer<AVPacket>? = packet
            let routed = packet.pointee.pts &- (plan?.delayTicks ?? 0)
            if routed < run.start {
                trackedPacketFree(&p)
            } else if let end = run.end, routed >= end {
                run.finished = true
                trackedPacketFree(&p)
            } else {
                run.held.append(packet)
            }
        }
    }

    /// What can be handed on, in order: a run's packets once every earlier run is done.
    private func release() -> [UnsafeMutablePointer<AVPacket>] {
        var out: [UnsafeMutablePointer<AVPacket>] = []
        while let run = runs.first {
            out += run.held
            let bytes = run.held.reduce(0) { $0 + Int64($1.pointee.size) }
            shared.lock.withLock { shared.bytesOut += bytes }
            run.held.removeAll()
            guard run.finished else { break }
            retire(run)
            runs.removeFirst()
        }
        return out
    }

    private func prune(before tick: Int64) {
        var drop = 0
        while drop < ring.count - 1, let t = ticks(of: ring[drop + 1]), t < tick { drop += 1 }
        for i in 0..<drop {
            var p: UnsafeMutablePointer<AVPacket>? = ring[i]
            av_packet_free(&p)
        }
        ring.removeFirst(drop)
    }

    private func freeRing() {
        for packet in ring {
            var p: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&p)
        }
        ring.removeAll()
    }

    private func closeRuns() {
        for run in runs {
            for packet in run.held {
                var p: UnsafeMutablePointer<AVPacket>? = packet
                trackedPacketFree(&p)
            }
            retire(run)
        }
        runs.removeAll()
        freeRing()
    }

    private func retire(_ run: Run) {
        let stats = run.bridge.feedStats
        shared.lock.withLock { shared.retiredStats = shared.retiredStats.adding(stats) }
        run.bridge.close()
    }
}
