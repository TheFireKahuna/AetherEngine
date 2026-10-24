import CoreGraphics
import CoreVideo
import VideoToolbox

/// The picture playback would show, as a still, on the GPU (docs/software-route-gpu.md Part 7): one
/// `VTPixelTransferSession` scales a display buffer (VideoToolbox's, or the finisher's from ``DisplayBufferWriter``) to
/// the still's size and maps its colour in the same pass. An HDR picture (PQ, HLG) maps to BT.709 SDR, Apple's own curve
/// (the one `AVAssetImageGenerator`'s force-SDR policy produces); an SDR picture keeps its primaries and transfer.
///
/// Not thread-safe: the owner serialises every call.
final class StillRenderer {
    static var sdr: ColorAttachments.Tags {
        ColorAttachments.Tags(primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                              transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
                              matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    }

    private var session: VTPixelTransferSession?
    private var pool: (width: Int, height: Int, format: OSType, pool: CVPixelBufferPool)?

    deinit {
        if let session { VTPixelTransferSessionInvalidate(session) }
    }

    /// Where a still of `source` lands: BT.709 SDR for an HDR picture or an untagged one, the picture's own primaries
    /// and transfer otherwise (a transfer given only as a gamma exponent goes to BT.709's).
    static func destination(for source: CVPixelBuffer) -> ColorAttachments.Tags {
        let attachment = { (key: CFString) in CVBufferCopyAttachment(source, key, nil).map { $0 as! CFString } }
        guard let primaries = attachment(kCVImageBufferColorPrimariesKey),
              let transfer = attachment(kCVImageBufferTransferFunctionKey) else { return sdr }
        let hdr = [kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, kCVImageBufferTransferFunction_ITU_R_2100_HLG]
        if hdr.contains(where: { CFEqual($0, transfer) }) { return sdr }
        let kept = CFEqual(transfer, kCVImageBufferTransferFunction_UseGamma) ? sdr.transfer : transfer
        return ColorAttachments.Tags(primaries: primaries, transfer: kept, matrix: sdr.matrix)
    }

    /// `source` at `width` x `height` in `pixelFormat`, mapped to `destination`, in a buffer of the renderer's own pool
    /// (the I-frame tier's encoder takes it and lets it go).
    func render(_ source: CVPixelBuffer, width: Int, height: Int, pixelFormat: OSType,
                destination: ColorAttachments.Tags) -> CVPixelBuffer? {
        guard let pool = bufferPool(width: width, height: height, format: pixelFormat) else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer,
              transfer(source, into: buffer, destination: destination) else { return nil }
        return buffer
    }

    /// The still as an image, in the colour space ``destination(for:)`` picks. A BGRA buffer of its own backs it: a
    /// pooled one would be repainted under an image the host is still showing.
    func image(_ source: CVPixelBuffer, width: Int, height: Int) -> CGImage? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer, transfer(source, into: buffer, destination: Self.destination(for: source)) else { return nil }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr else { return nil }
        return image
    }

    /// One pass: scale and colour. All three destination tags are set on the session and the buffer; leaving any
    /// unset gives a different, flat curve.
    private func transfer(_ source: CVPixelBuffer, into destination: CVPixelBuffer, destination tags: ColorAttachments.Tags) -> Bool {
        guard let session = transferSession() else { return false }
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries, value: tags.primaries)
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationTransferFunction, value: tags.transfer)
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: tags.matrix)
        CVBufferSetAttachment(destination, kCVImageBufferColorPrimariesKey, tags.primaries, .shouldPropagate)
        CVBufferSetAttachment(destination, kCVImageBufferTransferFunctionKey, tags.transfer, .shouldPropagate)
        CVBufferSetAttachment(destination, kCVImageBufferYCbCrMatrixKey, tags.matrix, .shouldPropagate)
        return VTPixelTransferSessionTransferImage(session, from: source, to: destination) == noErr
    }

    private func transferSession() -> VTPixelTransferSession? {
        if let session { return session }
        var made: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &made) == noErr, let made else { return nil }
        VTSessionSetProperty(made, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        VTSessionSetProperty(made, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanFalse)
        session = made
        return made
    }

    private func bufferPool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        if let pool, pool.width == width, pool.height == height, pool.format == format { return pool.pool }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var made: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &made) == kCVReturnSuccess, let made else { return nil }
        pool = (width, height, format, made)
        return made
    }
}
