import Foundation
import AVFoundation
import CoreVideo
import Testing
@testable import AetherEngine

/// The 27 SDKs move `AVPlayerItemVideoOutput` to typed attributes and a read-only read. What the engine asks for must
/// not change with it: IOSurface backing for the held picture and the frame sampler, the one pixel format a probe
/// reads its bytes in.
@Suite("ItemVideoOutput")
struct ItemVideoOutputTests {

    @Test("the typed attributes ask for what the dictionaries asked for")
    func attributes() throws {
        guard #available(macOS 26, iOS 26, tvOS 26, visionOS 26, *) else { return }
        let surface = ItemVideoOutput.attributes(.ioSurface).rawAttributes
        #expect(surface[kCVPixelBufferIOSurfacePropertiesKey as String] != nil)
        #expect(surface[kCVPixelBufferPixelFormatTypeKey as String] == nil, "the decoder's own format, unconverted")

        let bgra = ItemVideoOutput.attributes(.pixelFormat(kCVPixelFormatType_32BGRA)).rawAttributes
        let formats = try #require(bgra[kCVPixelBufferPixelFormatTypeKey as String] as? [NSNumber])
        #expect(formats.map(\.uint32Value) == [kCVPixelFormatType_32BGRA])
    }

    @Test("the read-only image hands over the buffer under it, not a copy")
    func unwrapsTheSameBuffer() throws {
        guard #available(macOS 26, iOS 26, tvOS 26, visionOS 26, *) else { return }
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &created)
        let buffer = try #require(created)
        let identity = ObjectIdentifier(buffer)
        let image = CVReadOnlyPixelBuffer(unsafeBuffer: buffer)
        #expect(ObjectIdentifier(ItemVideoOutput.unwrapped(image)) == identity)
    }

    @Test("an output on no item answers with no image")
    func nothingWithoutAnItem() {
        let read = ItemVideoOutput.frame(of: ItemVideoOutput.make(.ioSurface), at: .zero)
        #expect(read.pixelBuffer == nil)
    }
}
