import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// A VideoToolbox HEVC Main10 session that encodes every picture it is given as an intra frame, synchronously, with
/// one colour tagged in its VUI: the I-frame tiers' stills (`IFrameStillBuilder`) and the software overlay's
/// placeholder (`OverlayPlaceholder`). Not thread-safe: the owner serialises every call.
final class HEVCIntraEncoder {
    let width: Int
    let height: Int
    let colour: ColorAttachments.Tags
    /// The encoder's `hvcC`, from a warm-up encode of a black picture: what every init declares.
    let hvcC: Data
    /// That black picture's sample: length-prefixed (4-byte) NAL units of one IDR.
    let blackSample: Data
    let isHardware: Bool

    private let session: VTCompressionSession
    private var nextPTS: Int64 = 1

    /// nil when no HEVC Main10 encoder can be made or the warm-up encode yields no configuration record.
    init?(width: Int, height: Int, colour: ColorAttachments.Tags, quality: Double) {
        self.width = width
        self.height = height
        self.colour = colour
        var made: VTCompressionSession?
        guard VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &made) == noErr, let made else { return nil }
        session = made
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main10_AutoLevel)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 1 as CFNumber)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_Quality, value: quality as CFNumber)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_ColorPrimaries, value: colour.primaries)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_TransferFunction, value: colour.transfer)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_YCbCrMatrix, value: colour.matrix)
        VTCompressionSessionPrepareToEncodeFrames(made)
        var hardware: CFBoolean?
        VTSessionCopyProperty(made, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                              allocator: nil, valueOut: &hardware)
        isHardware = hardware == kCFBooleanTrue
        guard let black = Self.blackFrame(width: width, height: height, colour: colour),
              let warm = Self.encode(black, session: made, pts: 0) else {
            VTCompressionSessionInvalidate(made)
            return nil
        }
        hvcC = warm.hvcC
        blackSample = warm.data
    }

    deinit { VTCompressionSessionInvalidate(session) }

    /// One intra frame: the sample's length-prefixed NAL units.
    func encode(_ buffer: CVPixelBuffer) -> Data? {
        defer { nextPTS += 1 }
        return Self.encode(buffer, session: session, pts: nextPTS)?.data
    }

    private final class EncodeResult: @unchecked Sendable {
        var data: Data?
        var hvcC: Data?
    }

    private static func encode(_ buffer: CVPixelBuffer, session: VTCompressionSession,
                               pts: Int64) -> (data: Data, hvcC: Data)? {
        let result = EncodeResult()
        let properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: pts, timescale: 24),
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample),
                  let format = CMSampleBufferGetFormatDescription(sample) else { return }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            let copied = data.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
            }
            guard copied == kCMBlockBufferNoErr else { return }
            let atoms = CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
            result.data = data
            result.hvcC = atoms?["hvcC"] as? Data
        }
        guard status == noErr else { return nil }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard let data = result.data, !data.isEmpty, let hvcC = result.hvcC else { return nil }
        return (data, hvcC)
    }

    /// Black in 10-bit video range, tagged with `colour`.
    private static func blackFrame(width: Int, height: Int, colour: ColorAttachments.Tags) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                  attributes, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        for (plane, value) in [(0, UInt16(64 << 6)), (1, UInt16(512 << 6))] {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let count = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane) / 2
            base.assumingMemoryBound(to: UInt16.self).update(repeating: value, count: count)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, colour.primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, colour.transfer, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, colour.matrix, .shouldPropagate)
        return buffer
    }
}
