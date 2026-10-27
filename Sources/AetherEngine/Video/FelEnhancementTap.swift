// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation
import CoreMedia
import CoreVideo
import AetherLibavcodec
import AetherLibavutil

/// The enhancement half of a Profile 7 FEL whose base layer AVPlayer plays (`LoadOptions.felOverlay`),
/// taken from the session's own read of the source.
///
/// The segment producer already splits every video packet into its layers to serve the base layer
/// (`separateDualLayers`); with a tap it keeps the rest instead of dropping it: the compressed enhancement
/// layer and the composer parameters, in an ``OverlayPacketTap`` keyed by the packet's output presentation
/// time, which is AVPlayer's item time. The enhancement layer is decoded near the clock on VideoToolbox. A run's
/// first segment is held until the enhancement picture AVPlayer starts on is decoded (`awaitRunStart`), so a start
/// or a seek opens on the full picture; after it, a frame whose enhancement picture is not decoded in time is
/// composed with the residual off.
final class FelEnhancementTap: @unchecked Sendable {

    struct Frame: @unchecked Sendable {
        let enhancement: CVPixelBuffer?
        let params: DoviMetalParams
    }

    static let decodeAheadSeconds = 0.75

    private let units = OverlayPacketTap<DoviMetalParams>(decodeAheadSeconds: FelEnhancementTap.decodeAheadSeconds) {
        EnhancementLayerDecoder(deliver: $0)
    }
    /// Where the current run starts and whether the player has moved the clock since (`OverlayRunStart`).
    private let runStart = OverlayRunStart()

    // Producer side, only touched from `rewrite` (one producer feeds at a time).
    private var alignment = DualLayerVideoDecoder.makeAlignment()
    private var lastParams: DoviMetalParams?
    private var lastRpu: [UInt8]?
    private var borrowedRun = 0

    func close() { units.close() }

    /// Rewrites `packet` to its Profile 8.1 base layer and keeps the enhancement layer and parameters, named by
    /// `served`, the time AVPlayer is served the packet at (nil for one with no presentation time, which is rewritten
    /// and not kept). Packets come in decode order; `opensRun` for a producer's first.
    ///
    /// The TV applies the RPU in AVPlayer's stream to the overlay's picture, which is composed, so the packet's
    /// RPU is the composed form for every `el_type` (a residual-off or MEL-like RPU in mode 2 form would keep
    /// its curves and reshape the composed picture again). A packet whose own RPU is missing or failed to
    /// convert carries the last composed one, the RPU of the parameters it borrows. With
    /// `AetherEngine.felComposedRpuOverride` set, every packet cut from then on carries the override instead.
    func rewrite(_ packet: UnsafeMutablePointer<AVPacket>, opensRun: Bool, served: ServedVideoTime?,
                 framing: VideoNALFraming, chromaLocation: UInt32) -> Bool {
        let pts = served?.pts ?? Int64.min
        let dts = served.map { $0.dts == Int64.min ? $0.pts : $0.dts } ?? Int64.min
        let timeBase = served?.timeBase ?? AVRational(num: 1, den: 1)
        let isKey = packet.pointee.flags & AV_PKT_FLAG_KEY != 0
        // A new run is read for picture order afresh.
        if opensRun {
            units.beginRun()
            alignment = DualLayerVideoDecoder.makeAlignment()
        }
        // A run opens where AVPlayer is about to start (a load, a resume, a seek), so the decode works toward the
        // picture it starts on (`OverlayRunStart`), once the unit is kept.
        let seconds = Double(pts) * av_q2d(timeBase)
        let decodeTo = pts != Int64.min ? runStart.noteUnit(at: seconds, opensRun: opensRun) : nil
        defer { if let decodeTo { units.advance(to: decodeTo) } }
        var elPTS = pts
        if let data = packet.pointee.data, pts != Int64.min {
            elPTS = alignment.enhancementPTS(data, Int(packet.pointee.size), framing: framing, pts: pts)
        }
        let layers = DoviRpuConverter.separateDualLayers(packet, framing: framing, packetRpu: .composed(fallback: lastRpu, override: DoviComposedRpuOverride.current))

        // The resolution `DualLayerVideoDecoder.recordSideData` applies.
        var params = layers.rpuParams
        if params != nil {
            lastParams = params; lastRpu = layers.convertedRpu; borrowedRun = 0
        } else if var last = lastParams {
            if layers.usesPreviousMapping {
                if layers.disableResidual { last.flags.insert(.disableResidual) } else { last.flags.remove(.disableResidual) }
                params = last
            } else if borrowedRun < DualLayerVideoDecoder.maxBorrowedParamsRun {
                borrowedRun += 1
                params = last
            }
        }
        guard pts != Int64.min, var params else {
            var el = layers.elPacket; trackedPacketFree(&el)
            return layers.success
        }
        params.blChromaLocation = chromaLocation
        if let el = layers.elPacket {
            el.pointee.pts = elPTS
            el.pointee.dts = dts
            if isKey { el.pointee.flags |= AV_PKT_FLAG_KEY }
        }
        units.insert(pts: pts, timeBase: timeBase, isKey: isKey, info: params, packet: layers.elPacket)
        return layers.success
    }

    /// The frame AVPlayer shows at `seconds` (item time), nil when the producer has not cut it.
    func frame(at seconds: Double) -> Frame? {
        units.unit(at: seconds).map { Frame(enhancement: $0.picture, params: $0.info) }
    }

    /// The served interval of the frame after the one AVPlayer shows at `seconds` (item time), exact; nil while the
    /// producer has not cut it (``OverlayPacketTap/frameInterval(after:)``).
    func frameInterval(after seconds: Double) -> CMTimeRange? { units.frameInterval(after: seconds) }

    /// Where AVPlayer's clock is (item time): what the decoder works toward and what is kept around it. Its staging
    /// while an item gets ready is not followed.
    func advance(to seconds: Double) {
        guard runStart.notePlayerMoved(to: seconds) else { return }
        units.advance(to: seconds)
    }

    /// Where AVPlayer will start, before the player has a clock (a resume's start position, item time).
    func noteStart(at seconds: Double) {
        runStart.noteStart(at: seconds)
    }

    /// Reads where AVPlayer reports it is (item time, a pending seek's target included); nil once its item is gone.
    func follow(reportedTime read: (@Sendable () -> Double?)?) {
        runStart.follow(reportedTime: read)
    }

    /// Blocks until the enhancement picture AVPlayer starts the current run on is decoded (`OverlayRunStart`): the
    /// segment holding it is what AVPlayer prerolls and starts its clock on. True when the picture is there or nothing
    /// needs to wait; false after `timeout`, once the decoder has stalled (`OverlayRunStart.stalledDecodeSeconds`), or
    /// once `shouldStop` says so.
    func awaitRunStart(timeout: TimeInterval, shouldStop: () -> Bool) -> Bool {
        runStart.awaitPicture(decodeClock: { units.clockSeconds }, decodeTo: { units.advance(to: $0) },
                              timeout: timeout, progress: { units.unitsDecoded },
                              hasPicture: { units.hasPictureShown(at: $0) }, shouldStop: shouldStop)
    }

    /// Where the decode works toward, in item seconds.
    var clockSeconds: Double { units.clockSeconds }

    var held: (accessUnits: Int, decoded: Int, bytes: Int) {
        let held = units.held
        return (held.units, held.decoded, held.bytes)
    }

    /// Whether the producer may cut another unit (``OverlayPacketTap/hasRoomAhead``).
    var hasRoomAhead: Bool { units.hasRoomAhead }
}

/// A FEL unit's composer parameters, kept on disk with its enhancement-layer packet.
extension DoviMetalParams: OverlayUnitInfo {
    func unitRecord() -> Data { record() }
    init?(unitRecord: Data) { self.init(record: unitRecord) }
}

/// The enhancement layer's VideoToolbox decoder, opened from the parameter sets of the first unit it is given.
private final class EnhancementLayerDecoder: OverlayTapDecoder {
    private let deliver: @Sendable (CVPixelBuffer, CMTime) -> Void
    private var decoder: HardwareVideoDecoder?

    init(deliver: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) { self.deliver = deliver }

    func decode(_ packet: UnsafeMutablePointer<AVPacket>, restarting: Bool, clock: Double, timeBase: AVRational) {
        if restarting { decoder?.flush() }
        if decoder == nil { open(from: packet, timeBase: timeBase) }
        decoder?.decode(packet: packet)
    }

    func close() { decoder?.close() }

    private func open(from packet: UnsafeMutablePointer<AVPacket>, timeBase: AVRational) {
        guard let data = packet.pointee.data else { return }
        var vps: [UInt8]?, sps: [UInt8]?, pps: [UInt8]?
        A53SEIParser.forEachNAL(data, Int(packet.pointee.size), .lengthPrefixed(size: 4)) { nal, len in
            let bytes = [UInt8](UnsafeBufferPointer(start: nal, count: len))
            switch (nal[0] >> 1) & 0x3F {
            case 32: vps = bytes
            case 33: sps = bytes
            case 34: pps = bytes
            default: break
            }
        }
        guard let vps, let sps, let pps else { return }
        let d = HardwareVideoDecoder()
        let deliver = deliver
        do {
            try d.open(parameterSets: [vps, sps, pps], timeBase: timeBase) { buffer, pts, _ in deliver(buffer, pts) }
            decoder = d
        } catch {
            EngineLog.emit("[FelEnhancementTap] enhancement decoder failed to open: \(error)", category: .swPlayback)
        }
    }
}
#endif
