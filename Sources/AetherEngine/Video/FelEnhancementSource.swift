// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation
import CoreMedia
import CoreVideo
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// The enhancement half of a Profile 7 FEL source, read beside an `AVPlayer` that plays its base layer.
///
/// The FEL overlay route lets AVPlayer decode the base layer (its frames come back through
/// `AVPlayerItemVideoOutput` bit-identical to our own VideoToolbox decode) and keeps only the rest here:
/// a second demuxer on the same source splits each access unit (`separateDualLayers`), decodes the 1080p
/// enhancement layer, and keeps the composer parameters and the composed-form Profile 8.1 RPU per frame.
/// Everything is keyed by source presentation time in milliseconds, so a frame pulled from AVPlayer finds
/// its partner by timestamp alone, whatever order either side produced them in.
///
/// The reader stays `readAheadSeconds` ahead of the clock the overlay reports and drops what fell
/// `keepBehindSeconds` behind it, so memory holds about a second of decoded 1080p enhancement frames.
/// A clock jump outside what is held repositions the demuxer at the nearest keyframe before the target.
final class FelEnhancementSource: @unchecked Sendable {

    struct Frame: @unchecked Sendable {
        /// The decoded enhancement picture, nil while it has not decoded yet (the frame can still be
        /// composed with its residual off).
        let enhancement: CVPixelBuffer?
        let params: DoviMetalParams
        /// The frame's RPU in Profile 8.1 with both curves set to no-op: the form that describes a picture
        /// the composer has already reshaped (`DoviRpuConverter.dualLayerUnspec62`, `composed`).
        let composedRpu: [UInt8]?
    }

    static let readAheadSeconds = 0.75
    static let keepBehindSeconds = 0.25

    private let url: URL
    private let headers: [String: String]
    /// Guards everything below and is what the reader waits on.
    private let state = NSCondition()
    private var sideData: [Int64: (params: DoviMetalParams, rpu: [UInt8]?)] = [:]
    private var enhancement: [Int64: CVPixelBuffer] = [:]
    private var clockMs: Int64 = 0
    private var newestReadMs = Int64.min
    private var repositionTarget: Double?
    private var reachedEnd = false
    private var closed = false
    private var reader: Task<Void, Never>?

    init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }

    deinit { close() }

    static func key(_ seconds: Double) -> Int64 { Int64((seconds * 1000).rounded()) }

    /// Starts reading at `seconds` (source time).
    func start(at seconds: Double) {
        state.lock()
        clockMs = Self.key(seconds)
        repositionTarget = seconds > 0.5 ? seconds : nil
        state.unlock()
        reader = BlockingWork.detached(priority: .userInitiated) { [self] in readLoop() }
    }

    func close() {
        state.lock()
        closed = true
        state.broadcast()
        state.unlock()
    }

    /// The overlay's clock moved on: trim what is behind it and let the reader run further ahead.
    func advance(to seconds: Double) {
        let ms = Self.key(seconds)
        state.lock()
        clockMs = ms
        let floor = ms - Self.key(Self.keepBehindSeconds)
        sideData = sideData.filter { $0.key >= floor }
        enhancement = enhancement.filter { $0.key >= floor }
        state.broadcast()
        state.unlock()
    }

    /// A seek: kept frames are reused when the target lies inside them, otherwise the reader starts over at
    /// the keyframe before it.
    func reposition(to seconds: Double) {
        let ms = Self.key(seconds)
        state.lock()
        defer { state.broadcast(); state.unlock() }
        clockMs = ms
        if let oldest = sideData.keys.min(), ms >= oldest, ms <= newestReadMs { return }
        repositionTarget = seconds
        sideData.removeAll()
        enhancement.removeAll()
        newestReadMs = .min
        reachedEnd = false
    }

    /// The frame presented at `seconds` (source time), nil when its access unit has not been read yet.
    func frame(at seconds: Double) -> Frame? {
        let ms = Self.key(seconds)
        state.lock()
        defer { state.unlock() }
        // Millisecond keys from two time bases can round one apart.
        for k in [ms, ms - 1, ms + 1] {
            if let side = sideData[k] {
                return Frame(enhancement: enhancement[k], params: side.params, composedRpu: side.rpu)
            }
        }
        return nil
    }

    var heldFrames: (side: Int, enhancement: Int) {
        state.lock(); defer { state.unlock() }
        return (sideData.count, enhancement.count)
    }

    // MARK: - Reader

    private func readLoop() {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        do {
            try demuxer.open(url: url, extraHeaders: headers)
        } catch {
            EngineLog.emit("[FelEnhancementSource] open failed: \(error)", category: .swPlayback)
            return
        }
        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) else {
            EngineLog.emit("[FelEnhancementSource] no video stream", category: .swPlayback)
            return
        }
        let timeBase = stream.pointee.time_base
        let chromaLocation = UInt32(max(0, stream.pointee.codecpar.pointee.chroma_location.rawValue))
        var decoder: HardwareVideoDecoder?
        defer { decoder?.close() }
        var alignment = DualLayerVideoDecoder.makeAlignment()
        var lastParams: DoviMetalParams?
        var lastRpu: [UInt8]?
        var borrowedRun = 0

        while true {
            state.lock()
            while !closed, repositionTarget == nil,
                  reachedEnd || newestReadMs > clockMs + Self.key(Self.readAheadSeconds) {
                state.wait(until: Date().addingTimeInterval(0.1))
            }
            if closed { state.unlock(); return }
            let target = repositionTarget
            repositionTarget = nil
            state.unlock()

            if let target {
                if !demuxer.seek(to: target) {
                    EngineLog.emit("[FelEnhancementSource] seek to \(target) refused", category: .swPlayback)
                }
                decoder?.flush()
                alignment = DualLayerVideoDecoder.makeAlignment()
                lastParams = nil
                lastRpu = nil
                borrowedRun = 0
                continue
            }

            let packet: UnsafeMutablePointer<AVPacket>?
            do { packet = try demuxer.readPacket() } catch { packet = nil }
            guard let packet else {
                decoder?.flush()
                state.lock(); reachedEnd = true; state.unlock()
                continue
            }
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { av_packet_unref(packet); trackedPacketFree(&owned) }
            guard packet.pointee.stream_index == videoIdx, packet.pointee.pts != Int64.min,
                  let data = packet.pointee.data else { continue }

            let ms = Self.key(Double(packet.pointee.pts) * av_q2d(timeBase))
            let elPTS = alignment.enhancementPTS(data, Int(packet.pointee.size), framing: .lengthPrefixed(size: 4),
                                                 pts: packet.pointee.pts)
            let layers = DoviRpuConverter.separateDualLayers(packet, extractEL: true, useCustomBlockSource: true)

            // The same resolution `DualLayerVideoDecoder.recordSideData` applies.
            var params = layers.rpuParams
            var rpu = layers.convertedRpu
            if params != nil {
                lastParams = params
                lastRpu = rpu
                borrowedRun = 0
            } else if var last = lastParams {
                if layers.usesPreviousMapping {
                    if layers.disableResidual { last.flags.insert(.disableResidual) } else { last.flags.remove(.disableResidual) }
                    params = last
                    rpu = rpu ?? lastRpu
                } else if borrowedRun < DualLayerVideoDecoder.maxBorrowedParamsRun {
                    borrowedRun += 1
                    params = last
                    rpu = rpu ?? lastRpu
                }
            }
            if var params {
                params.blChromaLocation = chromaLocation
                state.lock()
                sideData[ms] = (params, rpu)
                newestReadMs = max(newestReadMs, ms)
                state.unlock()
            }

            guard let el = layers.elPacket else { continue }
            var elOwned: UnsafeMutablePointer<AVPacket>? = el
            defer { trackedPacketFree(&elOwned) }
            if decoder == nil, let sets = Self.parameterSets(el) {
                let d = HardwareVideoDecoder()
                do {
                    try d.open(parameterSets: sets, timeBase: timeBase) { [weak self] buffer, pts, _ in
                        self?.storeEnhancement(buffer, key: Self.key(pts.seconds))
                    }
                    decoder = d
                } catch {
                    EngineLog.emit("[FelEnhancementSource] enhancement decoder failed to open: \(error)", category: .swPlayback)
                }
            }
            el.pointee.pts = elPTS
            el.pointee.dts = packet.pointee.dts
            decoder?.decode(packet: el)
        }
    }

    private func storeEnhancement(_ buffer: CVPixelBuffer, key: Int64) {
        state.lock()
        if key >= clockMs - Self.key(Self.keepBehindSeconds) { enhancement[key] = buffer }
        state.unlock()
    }

    /// VPS, SPS and PPS from an enhancement-layer access unit, nil until a keyframe carries all three.
    private static func parameterSets(_ el: UnsafeMutablePointer<AVPacket>) -> [[UInt8]]? {
        guard let data = el.pointee.data else { return nil }
        var vps: [UInt8]?, sps: [UInt8]?, pps: [UInt8]?
        A53SEIParser.forEachNAL(data, Int(el.pointee.size), .lengthPrefixed(size: 4)) { nal, len in
            let bytes = [UInt8](UnsafeBufferPointer(start: nal, count: len))
            switch (nal[0] >> 1) & 0x3F {
            case 32: vps = bytes
            case 33: sps = bytes
            case 34: pps = bytes
            default: break
            }
        }
        guard let vps, let sps, let pps else { return nil }
        return [vps, sps, pps]
    }
}
#endif
