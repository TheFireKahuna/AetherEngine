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
/// time, which is AVPlayer's item time. The enhancement layer is decoded near the clock on VideoToolbox. A run's
/// first segment is held until the enhancement picture at the run's start is decoded (`awaitRunStart`), so a start
/// or a seek opens on the full picture; after it, a frame whose enhancement picture is not decoded in time is
/// composed with the residual off.
final class FelEnhancementTap: @unchecked Sendable {

    struct Frame: @unchecked Sendable {
        let enhancement: CVPixelBuffer?
        let params: DoviMetalParams
    }

    static let decodeAheadSeconds = 0.75

    /// Where the current run starts and whether the player has moved the clock since (`OverlayRunStart`).
    private let runStart = OverlayRunStart()
    /// How far from a run's start the enhancement picture that opens it may be: the frame on screen at the start is
    /// the one at or before it.
    static let runStartToleranceSeconds = 0.1

    // Producer side, only touched from `rewrite` (one producer feeds at a time).
    private var alignment = DualLayerVideoDecoder.makeAlignment()
    private var lastParams: DoviMetalParams?
    private var lastRpu: [UInt8]?
    private var borrowedRun = 0


    /// Rewrites `packet` to its Profile 8.1 base layer and keeps the enhancement layer and parameters. `packet`
    /// carries output (item-axis) timestamps, in decode order.
    ///
    /// The TV applies the RPU in AVPlayer's stream to the overlay's picture, which is composed, so the packet's
    /// RPU is the composed form for every `el_type` (a residual-off or MEL-like RPU in mode 2 form would keep
    /// its curves and reshape the composed picture again). A packet whose own RPU is missing or failed to
    /// convert carries the last composed one, the RPU of the parameters it borrows. With
    /// `AetherEngine.felComposedRpuOverride` set, every packet cut from then on carries the override instead.
    func rewrite(_ packet: UnsafeMutablePointer<AVPacket>, framing: VideoNALFraming, timeBase: AVRational,
                 chromaLocation: UInt32) -> Bool {
        let pts = packet.pointee.pts
        let dts = packet.pointee.dts == Int64.min ? pts : packet.pointee.dts
        let isKey = packet.pointee.flags & AV_PKT_FLAG_KEY != 0
        let opensRun = units.beginsRun(dts: packet.pointee.dts)
        if opensRun { alignment = DualLayerVideoDecoder.makeAlignment() }
        // A run's first unit is where AVPlayer's clock is about to be (a load, a resume, a seek), so before the player
        // moves the clock itself the decode works toward it, once the unit is kept.
        let seconds = Double(pts) * av_q2d(timeBase)
        let decodesTowardRun = pts != Int64.min && runStart.noteUnit(at: seconds, opensRun: opensRun)
        defer { if decodesTowardRun { units.advance(to: seconds) } }
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
        return layers.success
    }

    /// The frame AVPlayer shows at `seconds` (item time), nil when the producer has not cut it.
    func frame(at seconds: Double) -> Frame? {
    }

    /// Where AVPlayer's clock is (item time): what the decoder works toward and what is kept around it.
    func advance(to seconds: Double) {
        runStart.notePlayerMoved()
        units.advance(to: seconds)
    }

    /// Blocks until the enhancement picture at the current run's start is decoded, when the clock is at or heading
    /// for the run's start: the segment holding it is what AVPlayer prerolls and starts its clock on. True when the
    /// picture is there or nothing needs to wait; false after `timeout`, once the decoder has stalled
    func awaitRunStart(timeout: TimeInterval, shouldStop: () -> Bool) -> Bool {
    }

}

#endif
