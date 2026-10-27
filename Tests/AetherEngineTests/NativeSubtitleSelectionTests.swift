import Foundation
import Testing
@testable import AetherEngine

/// Who draws the selected track on the native route (`overlayDrawsNativeTrack`): AVKit for text, the
/// overlay for what AVKit cannot draw as authored, and the overlay for text while the viewer's subtitle
/// delay is not the one its rendition serves.
@MainActor
struct NativeSubtitleSelectionTests {

    private func engine(preserveASSMarkup: Bool = false) throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(preserveASSMarkup: preserveASSMarkup, prepareNativeSubtitles: true))
        engine.subtitleTracks = [
            TrackInfo(id: 2, name: "English", codec: "subrip", language: "eng", isDefault: false),
            TrackInfo(id: 3, name: "Signs", codec: "ass", language: "eng", isDefault: false),
            TrackInfo(id: 4, name: "English", codec: "hdmv_pgs_subtitle", language: "eng", isDefault: false),
        ]
        engine.nativeSubtitleTrackTable = [
            .init(sourceStreamIndex: 2, language: "eng"),
            .init(sourceStreamIndex: 3, language: "eng"),
            .init(sourceStreamIndex: 4, language: "eng", needsOCR: true),
        ]
        return engine
    }

    @Test("text is AVKit's, a bitmap track the overlay's, ASS the overlay's only when its styling is drawn")
    func whoDraws() throws {
        let plain = try engine()
        #expect(plain.overlayDrawsNativeTrack(ordinal: 0) == false)
        #expect(plain.overlayDrawsNativeTrack(ordinal: 1) == false)
        #expect(plain.overlayDrawsNativeTrack(ordinal: 2) == true)
        let styled = try engine(preserveASSMarkup: true)
        #expect(styled.overlayDrawsNativeTrack(ordinal: 0) == false)
        #expect(styled.overlayDrawsNativeTrack(ordinal: 1) == true)
    }

    @Test("a delay the rendition does not serve moves text to the overlay; the served one returns it")
    func delayHandsOver() throws {
        let engine = try engine()
        engine.setSubtitleDelay(0.5)
        #expect(engine.overlayDrawsNativeTrack(ordinal: 0) == true)
        engine.setSubtitleDelay(0)
        #expect(engine.overlayDrawsNativeTrack(ordinal: 0) == false)
        engine.servedSubtitleDelaySeconds = 0.5
        engine.setSubtitleDelay(0.5)
        #expect(engine.overlayDrawsNativeTrack(ordinal: 0) == false)
    }

    @Test("without an armed item a pick stays on the overlay's path")
    func unarmedPickIsTheOverlays() throws {
        let engine = try engine()
        #expect(!engine.nativeSubtitleSelectionArmed)
        #expect(!engine.selectNativeSubtitleOption(forTrack: 2, startAt: 0))
    }
}
