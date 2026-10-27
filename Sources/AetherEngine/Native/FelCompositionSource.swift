// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import CoreMedia
import CoreVideo
import Foundation
import os
import QuartzCore

/// The overlay picture of a Profile 7 FEL on the native route: AVPlayer's base-layer frame (bit-identical to a
/// VideoToolbox decode of the base layer, before any reshaping), paired by item time with its enhancement picture
/// and parameters from the session's ``FelEnhancementTap``, composed on the dual-layer composer. A frame whose
/// enhancement picture has not decoded waits for it while there is time, and is composed with its residual off
/// once there is not.
final class FelCompositionSource: OverlayFrameSource, @unchecked Sendable {

    let tap: FelEnhancementTap
    private let composer: DoviFelComposer
    private let requestedFormat: OSType
    /// Render-queue state.
    private var frameIndex: UInt32 = 0
    private var blankEnhancement: CVPixelBuffer?
    private let residualOffCount = OSAllocatedUnfairLock(initialState: 0)

    /// Frames composed with the residual off, their enhancement picture not decoded in time.
    var residualOff: Int { residualOffCount.withLock { $0 } }

    /// How long before its time a frame stops waiting for its enhancement picture: the composition (about 30 ms on
    /// the Apple TV) and the hop to the layer, with room to spare.
    static let enhancementWaitEndsSeconds = 0.1

    /// Nil when the composer cannot be built (no Metal device). `baseLayerFullRange` is the range the base layer's
    /// SPS states: asking for the matching format hands over its own codes, where the other would convert them.
    init?(tap: FelEnhancementTap, baseLayerFullRange: Bool) {
        guard let composer = DoviFelComposer() else { return nil }
        self.tap = tap
        self.composer = composer
        requestedFormat = HardwareVideoDecoder.pixelFormat(tenBit: true, fullRange: baseLayerFullRange)
    }

    var outputAttributes: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: requestedFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        ]
    }

    func followRenderer(_ attributes: [String: Any]) {
        composer.rendererRecommendedAttributesOverride = attributes
        EngineLog.emit("[SoftwareOverlay] output pool follows the renderer's recommendation \(attributes.keys.sorted()); "
                       + "the composer delivers \(SoftwareOverlayRenderer.fourCC(DoviFelComposer.outputMode.pixelFormat(fullRange: false))) "
                       + "(xf20 for a full-range picture)",
                       category: .swPlayback)
    }

    func advance(to itemSeconds: Double) { tap.advance(to: itemSeconds) }

    /// The base layer is half the picture, whatever the rate.
    func pacing(atRate rate: Double) -> OverlayPacing { .outputFrames }

    func frameInterval(after itemSeconds: Double) -> CMTimeRange? { tap.frameInterval(after: itemSeconds) }

    func pictures(after last: CMTime?, at itemSeconds: Double) -> [(picture: CVPixelBuffer, time: CMTime)] { [] }

    func makePicture(from base: CVPixelBuffer, at frameTime: CMTime,
                     done: @escaping @Sendable (CVPixelBuffer?) -> Void) -> Bool {
        let lookupStart = CACurrentMediaTime()
        let frame = tap.frame(at: frameTime.seconds)
        composer.stages.record("lookup", ms: (CACurrentMediaTime() - lookupStart) * 1000)
        guard let frame else { return false }
        var params = frame.params
        let enhancement: CVPixelBuffer
        if let el = frame.enhancement {
            enhancement = el
        } else if frameTime.seconds - tap.clockSeconds > Self.enhancementWaitEndsSeconds {
            return false
        } else if let blank = blankEnhancement(for: base) {
            params.flags.insert(.disableResidual)
            enhancement = blank
            residualOffCount.withLock { $0 += 1 }
        } else {
            done(nil)
            return true
        }
        frameIndex &+= 1
        composer.composeAsync(baseBuffer: base, enhancementBuffer: enhancement, params: params, frameIndex: frameIndex, completion: done)
        return true
    }

    func drainStageTimes() -> String? { composer.stages.drain() }

    func logSummary() -> String {
        let held = tap.held
        return "residual off \(residualOff), held \(held.accessUnits) units (\(held.bytes >> 20) MB on disk) / \(held.decoded) decoded"
    }

    /// An enhancement-sized picture the kernels can bind when the residual is off; its content is never read.
    private func blankEnhancement(for base: CVPixelBuffer) -> CVPixelBuffer? {
        if let blankEnhancement { return blankEnhancement }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(base) / 2, CVPixelBufferGetHeight(base) / 2,
                            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
                             kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
        blankEnhancement = buffer
        return buffer
    }
}
#endif
