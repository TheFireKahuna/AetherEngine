import CoreGraphics
import Foundation
import Testing
@testable import AetherEngine

/// What a native rendition serves for a cue: its inline emphasis, its placement as cue settings, and the
/// subtitle delay the session serves, on the window where the cue now plays.
struct ServedSubtitleCueTests {

    private func cue(_ start: Double, _ end: Double, _ body: SubtitleCue.Body,
                     placement: SubtitleTextPlacement? = nil) -> SubtitleCue {
        SubtitleCue(id: 0, startTime: start, endTime: end, body: body, placement: placement)
    }

    @Test("a placement round-trips through the cue settings the parser reads")
    func settingsRoundTrip() throws {
        for alignment in 1...9 {
            let placement = SubtitleTextPlacement(alignment: alignment, position: nil)
            guard let settings = WebVTTCueSettings.settings(for: placement) else {
                #expect(alignment == 2, "only bottom centre needs no settings")
                continue
            }
            let parsed = try #require(WebVTTCueSettings.placement(fromSettings: settings))
            #expect(parsed.alignment == alignment, "\(alignment): \(settings)")
        }
        let anchored = SubtitleTextPlacement(alignment: 7, position: CGPoint(x: 0.25, y: 0.1))
        let settings = try #require(WebVTTCueSettings.settings(for: anchored))
        let parsed = try #require(WebVTTCueSettings.placement(fromSettings: settings))
        #expect(parsed.alignment == 7)
        #expect(abs((parsed.position?.x ?? 0) - 0.25) < 0.001 && abs((parsed.position?.y ?? 0) - 0.1) < 0.001)
    }

    @Test("rich text keeps its emphasis, and the placement rides on the timing line")
    func markupAndSettings() {
        let store = NativeSubtitleCueStore()
        store.appendCues([cue(1, 2, .richText([
            SubtitleTextRun(text: "Hi ", color: nil, isItalic: true),
            SubtitleTextRun(text: "there", color: nil, isBold: true),
        ]), placement: SubtitleTextPlacement(alignment: 8, position: nil))])
        let vtt = WebVTTBuilder.segment(cues: store.cuesInWindow(start: 0, end: 6))
        #expect(vtt.contains("00:00:01.000 --> 00:00:02.000 line:0 align:center\n<i>Hi </i><b>there</b>"))
    }

    @Test("the served delay moves every cue, and a cue is served in the window it now plays in")
    func servedDelay() {
        let store = NativeSubtitleCueStore()
        store.appendCues([cue(5.5, 5.9, .text("late"))])
        store.setServedDelaySeconds(1)
        #expect(store.cuesInWindow(start: 0, end: 6).isEmpty)
        let moved = store.cuesInWindow(start: 6, end: 12)
        #expect(moved.map(\.start) == [6.5])
        #expect(moved.map(\.end) == [6.9])
        // The reading stays on the source axis.
        store.noteRead(from: 0, through: 10)
        #expect(store.readThrough(at: 5) == 10)
    }

    @Test("an ASS event line keeps its overrides, so its emphasis reaches the rendition")
    func assEventText() throws {
        let text = try #require(SubtitleRectText.eventText(fromASSEventLine: "3,0,Default,,0,0,0,,{\\i1}Hey{\\i0}, you"))
        #expect(text == "{\\i1}Hey{\\i0}, you")
        #expect(WebVTTBuilder.cueText(text) == "<i>Hey</i>, you")
        #expect(SubtitleRectText.eventText(fromASSEventLine: "3,0,Default,,0,0,0,,   ") == nil)
    }
}
