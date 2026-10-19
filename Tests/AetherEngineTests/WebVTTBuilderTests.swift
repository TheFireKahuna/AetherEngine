import Testing
@testable import AetherEngine

struct WebVTTBuilderTests {
    @Test("formats header, timestamps, and sanitized text")
    func formatsCues() {
        let vtt = WebVTTBuilder.body(cues: [
            (start: 0, end: 1.5, text: "Hello"),
            (start: 61.25, end: 3661.004, text: "{\\an8}World\\Nline2"),
        ])
        #expect(vtt.hasPrefix("WEBVTT\n"))
        #expect(vtt.contains("00:00:00.000 --> 00:00:01.500\nHello"))
        // 61.25s -> 00:01:01.250 ; 3661.004s -> 01:01:01.004 ; ASS block stripped, \N -> newline
        #expect(vtt.contains("00:01:01.250 --> 01:01:01.004\nWorld\nline2"))
    }

    @Test("empty cues still yields a valid WEBVTT header")
    func emptyIsValid() {
        #expect(WebVTTBuilder.body(cues: []) == "WEBVTT\n\n")
    }

    @Test("cue that sanitizes to empty is skipped")
    func skipsEmpty() {
        let vtt = WebVTTBuilder.body(cues: [(start: 0, end: 1, text: "{\\an8}")])
        #expect(vtt == "WEBVTT\n\n")
    }

    /// The text of the single cue `text` produces, or nil when it is skipped.
    private func cueText(_ text: String) -> String? {
        let vtt = WebVTTBuilder.body(cues: [(start: 0, end: 1, text: text)])
        guard let range = vtt.range(of: "00:00:00.000 --> 00:00:01.000\n") else { return nil }
        let rest = vtt[range.upperBound...]
        #expect(rest.hasSuffix("\n\n"))
        return String(rest.dropLast(2))
    }

    @Test("escapes the WebVTT markup characters in cue text")
    func escapesMarkupCharacters() {
        #expect(cueText("Tom & Jerry") == "Tom &amp; Jerry")
        #expect(cueText("<laughs> fine") == "&lt;laughs&gt; fine")
        #expect(cueText("a > b < c") == "a &gt; b &lt; c")
        #expect(cueText("&amp;") == "&amp;amp;")
    }

    @Test("cue text never contains the timing arrow")
    func noArrowInCueText() {
        let text = cueText("go --> there")
        #expect(text == "go --&gt; there")
        #expect(text?.contains("-->") == false)
    }

    @Test("a blank line inside a cue is collapsed so it cannot end the cue")
    func collapsesBlankLines() {
        #expect(cueText("First paragraph\n\nSecond paragraph") == "First paragraph\nSecond paragraph")
        #expect(cueText("one\\N\\Ntwo") == "one\ntwo")
        #expect(cueText("one\n   \n\ntwo") == "one\ntwo")
        #expect(cueText("\\Nline\\N") == "line")
    }

    @Test("SRT italic, bold and underline tags map to WebVTT tags")
    func mapsSRTTags() {
        #expect(cueText("<i>Hello</i> world") == "<i>Hello</i> world")
        #expect(cueText("<B>loud</B>") == "<b>loud</b>")
        #expect(cueText("<u>under</u>\\N<i>next</i>") == "<u>under</u>\n<i>next</i>")
    }

    @Test("ASS italic, bold and underline overrides map to WebVTT tags")
    func mapsASSOverrides() {
        #expect(cueText("{\\i1}Hello{\\i0} world") == "<i>Hello</i> world")
        #expect(cueText("{\\b1\\u1}both{\\b0} under{\\u0}") == "<b><u>both</u></b><u> under</u>")
        #expect(cueText("{\\b700}heavy") == "<b>heavy</b>")
        #expect(cueText("{\\i1\\b1}x{\\r}y") == "<i><b>x</b></i>y")
    }

    @Test("nested, crossed and unterminated tags still close properly")
    func closesTagsProperly() {
        #expect(cueText("<i>open") == "<i>open</i>")
        #expect(cueText("<i><b>x</i>y</b>") == "<i><b>x</b></i><b>y</b>")
        #expect(cueText("stray</i> close") == "stray close")
        #expect(cueText("<i></i>empty") == "empty")
    }

    @Test("other ASS override blocks and drawing commands are stripped")
    func stripsOtherOverridesAndDrawings() {
        #expect(cueText("{\\an8\\pos(10,20)\\c&H00FF00&}Top") == "Top")
        #expect(cueText("{\\bord2\\be1\\shad3}Plain") == "Plain")
        #expect(cueText("Text{\\p1}m 0 0 l 100 0 100 100 0 100{\\p0} after") == "Text after")
        #expect(cueText("{\\p1}m 0 0 l 10 10") == nil)
    }

    @Test("an unclosed brace stays literal text, as the plain sanitizer keeps it")
    func keepsUnclosedBrace() {
        #expect(cueText("a {b") == "a {b")
    }

    @Test("segment bodies get the same cue text treatment")
    func segmentEscapes() {
        let vtt = WebVTTBuilder.segment(cues: [(start: 0, end: 1, text: "{\\i1}Tom & Jerry")])
        #expect(vtt.contains("00:00:00.000 --> 00:00:01.000\n<i>Tom &amp; Jerry</i>\n\n"))
    }
}
