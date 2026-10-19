import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Testing
@testable import AetherEngine

/// #8: every pixel format the software decoder can now hand the display layer is one CoreVideo and the
/// display layer take, with the bytes meaning what the decoder means by them. Two checks per format,
/// on buffers built the way the decoder builds them (its pool attributes, colour tags, a format
/// description made from the buffer):
/// - VideoToolbox reads it: a mid grey written in the format's own layout (MSB-aligned 10-bit words,
///   the 16-bit formats' video range of 4096...60160) converts to the same grey as 8-bit `420v` does.
///   A depth, alignment or range mistake moves the grey; a format CoreVideo does not know fails.
/// - The display layer's renderer takes it under a running timebase without failing. Headless, the
///   layer draws nothing (`displayedPixelBuffer()` stays nil for every format), so this only catches a
///   refusal at enqueue; what a tvOS panel does with the format is not observable from a test.
@Suite("Software decoder output formats are read correctly and accepted by the display layer (#8)")
struct SoftwareOutputFormatDisplayTests {

    typealias Format = SoftwareVideoDecoder.OutputFormat

    static let formats: [Format] = {
        var all: [Format] = []
        for chroma in [Format.Chroma.yuv420, .yuv422, .yuv444] {
            for depth in [Format.Depth.eight, .ten] {
                for full in [false, true] { all.append(Format(chroma: chroma, depth: depth, fullRange: full)) }
            }
        }
        all.append(Format(chroma: .yuv422, depth: .sixteen, fullRange: false))
        all.append(Format(chroma: .yuv444, depth: .sixteen, fullRange: false))
        return all
    }()

    private static func fourCC(_ code: OSType) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "\(code)"
    }

    private static func makeBuffer(_ format: Format) -> CVPixelBuffer? {
        var pool: CVPixelBufferPool?
        let pbAttrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: format.pixelFormatType,
            kCVPixelBufferWidthKey: 64,
            kCVPixelBufferHeightKey: 32,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        ]
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pbAttrs, &pool) == kCVReturnSuccess, let pool else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess, let buffer = pb else { return nil }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        // The same grey in every format: 8-bit luma 180 video range is 191 full range; chroma neutral.
        let luma8 = format.fullRange ? 191 : 180
        func word(_ code8: Int) -> UInt16 {
            switch format.depth {
            case .eight: UInt16(code8)
            case .ten: UInt16(code8 * 4) << 6
            case .sixteen: UInt16(code8) << 8
            }
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let samples = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
            let value = word(plane == 0 ? luma8 : 128)
            for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                let row = base.advanced(by: y * stride)
                for x in 0..<samples {
                    if format.depth == .eight {
                        row.storeBytes(of: UInt8(value), toByteOffset: x, as: UInt8.self)
                    } else {
                        row.storeBytes(of: value, toByteOffset: x * 2, as: UInt16.self)
                    }
                }
            }
        }
        return buffer
    }

    /// The grey VideoToolbox converts the buffer to, or nil when it cannot read the format.
    private static func bgraGrey(_ buffer: CVPixelBuffer) -> [UInt8]? {
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
              let session else { return nil }
        defer { VTPixelTransferSessionInvalidate(session) }
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32BGRA, nil, &out)
        guard let out, VTPixelTransferSessionTransferImage(session, from: buffer, to: out) == noErr else { return nil }
        CVPixelBufferLockBaseAddress(out, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        let px = CVPixelBufferGetBaseAddress(out)!.advanced(by: 16 * CVPixelBufferGetBytesPerRow(out) + 32 * 4)
            .assumingMemoryBound(to: UInt8.self)
        return [px[0], px[1], px[2]]
    }

    @Test("VideoToolbox reads the format's words as the grey they were written as", arguments: formats)
    func videoToolboxReadsTheLayout(_ format: Format) throws {
        let name = Self.fourCC(format.pixelFormatType)
        let nv12 = try #require(Self.makeBuffer(Format(tenBit: false, fullRange: false)))
        let reference = try #require(Self.bgraGrey(nv12))
        let buffer = try #require(Self.makeBuffer(format), "\(name) pool")
        let grey = try #require(Self.bgraGrey(buffer), "\(name): VideoToolbox could not convert it")
        for (got, want) in zip(grey, reference) {
            #expect(abs(Int(got) - Int(want)) <= 1, "\(name): \(grey) vs 420v \(reference)")
        }
    }

    @Test("the display layer's renderer takes the format without failing", arguments: formats)
    @MainActor
    func layerAcceptsFormat(_ format: Format) async throws {
        let name = Self.fourCC(format.pixelFormatType)
        let layer = AVSampleBufferDisplayLayer()
        let renderer = layer.sampleBufferRenderer
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(),
                                        timebaseOut: &timebase)
        let tb = try #require(timebase)
        CMTimebaseSetTime(tb, time: .zero)
        CMTimebaseSetRate(tb, rate: 1)
        layer.controlTimebase = tb

        for i in 0..<4 {
            let buffer = try #require(Self.makeBuffer(format), "\(name) pool")
            var desc: CMVideoFormatDescription?
            #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                                 formatDescriptionOut: &desc) == noErr, "\(name) description")
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                            presentationTimeStamp: CMTime(value: Int64(i), timescale: 30),
                                            decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                             formatDescription: try #require(desc), sampleTiming: &timing,
                                                             sampleBufferOut: &sample) == noErr)
            renderer.enqueue(try #require(sample))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(renderer.status != .failed, "\(name): \(renderer.error.map { "\($0)" } ?? "no error")")
        #expect(renderer.error == nil, "\(name)")
    }
}
