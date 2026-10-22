import AVFoundation
import CoreVideo

/// An `AVPlayerItemVideoOutput`, built and read the way the running system wants it.
///
/// The 27 SDKs deprecate, for Swift, the dictionary `init(pixelBufferAttributes:)` and
/// `copyPixelBuffer(forItemTime:itemTimeForDisplay:)` in favour of `init(pixelBufferAttributes: CVPixelBufferAttributes)`
/// and `pixelBufferAndDisplayTime(forItemTime:)`, both there since 26. From 26 on the output is built and read through
/// those; before it through the old pair, as before.
///
/// The typed attributes are not the old dictionary spelled differently: they always state a backing (IOSurface unless
/// asked otherwise) and write the Metal, CGImage and bitmap-context compatibility keys out as false where the dictionary
/// left them absent. False there means "not required", which is what absent meant, and every consumer here shows the
/// frame on a sample-buffer layer or reads its bytes on the CPU, neither of which needs more than IOSurface.
///
/// `package` so the aetherctl probes read frames the same way without the helper becoming engine API.
package enum ItemVideoOutput {

    package enum Format: Equatable {
        /// IOSurface-backed, in whatever pixel format the decoder produces.
        case ioSurface
        /// One pixel format, converted to if the decoder produces another.
        case pixelFormat(OSType)
    }

    package static func make(_ format: Format) -> AVPlayerItemVideoOutput {
        if #available(macOS 26, iOS 26, tvOS 26, visionOS 26, *) {
            return AVPlayerItemVideoOutput(pixelBufferAttributes: attributes(format))
        }
        switch format {
        case .ioSurface:
            return AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
            ])
        case .pixelFormat(let type):
            return AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: type])
        }
    }

    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    static func attributes(_ format: Format) -> CVPixelBufferAttributes {
        switch format {
        case .ioSurface:
            var attributes = CVPixelBufferAttributes()
            attributes.backing = .ioSurface
            return attributes
        case .pixelFormat(let type):
            return CVPixelBufferAttributes(pixelFormatTypes: [CVPixelFormatType(rawValue: type)])
        }
    }

    /// The image for display at `itemTime`, marked acquired, and the time it is due on screen. A nil image means
    /// nothing new for that time (or nothing to show), as `copyPixelBuffer` always answered.
    package static func frame(of output: AVPlayerItemVideoOutput,
                              at itemTime: CMTime) -> (pixelBuffer: CVPixelBuffer?, displayTime: CMTime) {
        if #available(macOS 26, iOS 26, tvOS 26, visionOS 26, *) {
            let (image, displayTime) = output.pixelBufferAndDisplayTime(forItemTime: itemTime)
            return (image.map(unwrapped), displayTime)
        }
        var displayTime = CMTime.invalid
        let image = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime)
        return (image, displayTime)
    }

    /// The buffer under the read-only wrapper, for the consumers that take a `CVPixelBuffer` (the held picture's
    /// sample-buffer layer, the probes' CPU reads). The wrapper only lends it inside a closure whose result must be
    /// sendable, and a CF buffer is not; the box asserts what the wrapper itself promises, that nobody writes to it.
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    static func unwrapped(_ image: CVReadOnlyPixelBuffer) -> CVPixelBuffer {
        image.withUnsafeBuffer { HandedOver(buffer: $0) }.buffer
    }

    private struct HandedOver: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }
}
