import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import AetherEngine

/// The video renderer's queue goes through the synchronizer's receiver once joined on 27, and through the renderer's
/// own calls before joining, after leaving, and before 27.
@Suite("Video renderer I/O")
struct VideoRendererIOTests {

    private func frame(pts: Int64) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        let image = try #require(pixels)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMTime(value: pts, timescale: 30),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: try #require(format),
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return try #require(sample)
    }

    @MainActor
    private func makeIO() -> (VideoRendererIO, AVSampleBufferDisplayLayer) {
        let layer = AVSampleBufferDisplayLayer()
        return (VideoRendererIO(renderer: layer.sampleBufferRenderer), layer)
    }

    @MainActor
    @Test("joined through a receiver on 27 when asked, the renderer's own calls otherwise, and out again on leaving",
          arguments: audioOutputPaths)
    func joinsAndLeaves(throughReceiver: Bool) async throws {
        let (io, layer) = makeIO()
        let synchronizer = AVSampleBufferRenderSynchronizer()
        #expect(!io.usesReceiver, "outside a synchronizer the renderer is driven directly")
        io.join(synchronizer, throughReceiver: throughReceiver)
        #expect(io.usesReceiver == throughReceiver)
        #expect(synchronizer.renderers.contains { $0 === layer.sampleBufferRenderer })
        if case .failed(let error) = io.enqueue(try frame(pts: 0)) { Issue.record("refused: \(error)") }
        io.flush(removingDisplayedImage: true)
        io.leave(synchronizer)
        #expect(!io.usesReceiver)
        #expect(!synchronizer.renderers.contains { $0 === layer.sampleBufferRenderer })
    }

    @MainActor
    @Test("through the receiver, the first frame after a flush is unconfirmed and the next confirmed")
    func confirmation() async throws {
        guard #available(macOS 27, iOS 27, tvOS 27, visionOS 27, *) else { return }
        let (io, _) = makeIO()
        let synchronizer = AVSampleBufferRenderSynchronizer()
        io.join(synchronizer, throughReceiver: true)
        #expect(io.statusName == "unknown")
        #expect(io.enqueue(try frame(pts: 0)) == .enqueued(confirmed: false))
        #expect(io.enqueue(try frame(pts: 1)) == .enqueued(confirmed: true))
        #expect(io.statusName == "rendering")
        io.flush(removingDisplayedImage: false)
        #expect(io.statusName == "unknown")
        #expect(io.enqueue(try frame(pts: 2)) == .enqueued(confirmed: false))
        // The removing flush puts an empty-media marker in, which is neither a frame nor a failure.
        io.flush(removingDisplayedImage: true)
        #expect(io.statusName == "unknown")
        #expect(io.enqueue(try frame(pts: 3)) == .enqueued(confirmed: false))
        #expect(io.failureDescription == nil)
        io.leave(synchronizer)
    }

    @Test("the marker that removes the picture in order has no samples and asks for empty media")
    func emptyMediaMarker() throws {
        let marker = try #require(VideoRendererIO.emptyMediaMarker(at: CMTime(value: 5, timescale: 1)))
        #expect(CMSampleBufferGetNumSamples(marker) == 0)
        #expect(CMSampleBufferGetPresentationTimeStamp(marker) == CMTime(value: 5, timescale: 1))
        #expect(CMGetAttachment(marker, key: kCMSampleBufferAttachmentKey_EmptyMedia, attachmentModeOut: nil)
                as? Bool == true)
    }
}
