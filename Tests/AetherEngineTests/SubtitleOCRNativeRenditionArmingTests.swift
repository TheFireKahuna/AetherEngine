import AVFoundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// The OCR worker feeds a bitmap track's native rendition, which only AVKit draws, and only while the picture is off
/// the host's own view (PiP, AirPlay, an external display). Armed, it raises the subtitle read-ahead, so it follows
/// where the picture is rather than the selection alone.
@Suite("Subtitle OCR follows the native rendition", .timeLimit(.minutes(1)))
@MainActor
struct SubtitleOCRNativeRenditionArmingTests {

    private func engineWithSelectedBitmapTrack() throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.nativeSubtitleTrackTable = [.init(sourceStreamIndex: 3, language: "eng", needsOCR: true)]
        engine.testHookInstallNativeStores([NativeSubtitleCueStore()])
        engine.activeEmbeddedSubtitleStreamIndex = 3
        return engine
    }

    @Test("a selected bitmap track arms no worker while the host's overlay draws it")
    func fullscreenLeavesWorkerOff() throws {
        let engine = try engineWithSelectedBitmapTrack()
        engine.syncSubtitleOCRWithNativeRendition()
        #expect(engine.subtitleOCRArmedOrdinal == nil)
    }

    @Test("the worker arms when AVKit becomes the display and is released when the picture comes back (a0d7ee1a)")
    func followsNativeRendering() throws {
        let engine = try engineWithSelectedBitmapTrack()
        engine.setNativeSubtitleRendering(true)
        #expect(engine.subtitleOCRArmedOrdinal == 0)
        engine.setNativeSubtitleRendering(false)
        #expect(engine.subtitleOCRArmedOrdinal == nil)
        engine.cancelSubtitleOCRWorker()
    }

    @Test("a text track never arms the worker, wherever the picture is")
    func textTrackNeverArms() throws {
        let engine = try AetherEngine()
        engine.nativeSubtitleTrackTable = [.init(sourceStreamIndex: 3, language: "eng")]
        engine.testHookInstallNativeStores([NativeSubtitleCueStore()])
        engine.activeEmbeddedSubtitleStreamIndex = 3
        engine.setNativeSubtitleRendering(true)
        #expect(engine.subtitleOCRArmedOrdinal == nil)
    }

    @Test("a Picture in Picture window showing the software overlay keeps the worker off: its pictures carry the cues")
    func overlayPictureInPictureLeavesWorkerOff() throws {
        let engine = try engineWithSelectedBitmapTrack()
        let overlay = try OverlayRendererFixture()
        defer { overlay.close() }
        engine.softwareOverlay = overlay.renderer
        engine.setNativeSubtitleRendering(true)
        engine.pictureInPictureActive = true
        #expect(engine.subtitleOCRArmedOrdinal == nil)
        engine.pictureInPictureActive = false
        #expect(engine.subtitleOCRArmedOrdinal == 0)
        engine.cancelSubtitleOCRWorker()
        engine.softwareOverlay = nil
    }
}

/// A software overlay over an idle decode tap (an AV1 stream nothing feeds), closed by the caller.
final class OverlayRendererFixture {
    let renderer: SoftwareOverlayRenderer
    private let tap: OverlayDecodeTap
    private var parameters: UnsafeMutablePointer<AVCodecParameters>?

    init() throws {
        let par = try #require(avcodec_parameters_alloc())
        par.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        par.pointee.codec_id = AV_CODEC_ID_AV1
        parameters = par
        tap = OverlayDecodeTap(parameters: par, timeBase: AVRational(num: 1, den: 1000),
                               containerSAR: AVRational(num: 1, den: 1), deinterlace: DeinterlaceConfig()) { _, _ in }
        renderer = SoftwareOverlayRenderer(item: AVPlayerItem(url: URL(fileURLWithPath: "/dev/null")),
                                           source: DecodedPictureSource(tap: tap))
    }

    func close() {
        renderer.stop()
        tap.close()
        avcodec_parameters_free(&parameters)
    }
}
