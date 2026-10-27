import Foundation

/// Builds a WebVTT body from decoded cue tuples on the AVPlayer timeline (#15). Text is sanitized
/// separate HLS SUBTITLES rendition so AVKit renders subtitles in the PiP window (the on-frame overlay is not
/// in the PiP layer); muxing timed text into the A/V fMP4 is non-conformant for HLS (see #55).
/// `cueText(_:)`: escaped, blank lines collapsed, italic/bold/underline kept, everything else of the
enum WebVTTBuilder {
    /// `WEBVTT` header followed by one cue block per non-empty cue: `HH:MM:SS.mmm --> HH:MM:SS.mmm` + text.
    static func body(cues: [(start: Double, end: Double, text: String)]) -> String {
        var out = "WEBVTT\n\n"
        for cue in cues {
            let text = cueText(cue.text)
            if text.isEmpty { continue }
            out += "\(timestamp(cue.start)) --> \(timestamp(max(cue.start, cue.end)))\n\(text)\n\n"
        }
        return out
    }

    /// WebVTT *segment* body for an HLS SUBTITLES rendition (#15). Same cue formatting as `body(cues:)`
    /// plus the segment header AVPlayer needs to anchor cue times to the fMP4 media timeline.
    ///
    /// We emit an IDENTITY timestamp map (`X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000`) and write cues
    /// with ABSOLUTE media-timeline times (the values `cuesInWindow` returns are already on the
    /// AVPlayer/output timeline). This absolute + identity-map choice is the ONE thing to verify on-device:
    /// if PiP subtitles appear shifted by the segment's start offset, flip `relativeToStart` to true at the
    /// single provider call site (`VideoSegmentProvider.nativeSubtitleVTT(ordinal:segmentIndex:)`); that
    /// rebases every cue to LOCAL time relative to `segmentStart` while keeping MPEGTS:0.
    static func segment(cues: [(start: Double, end: Double, text: String)],
                        segmentStart: Double = 0,
                        relativeToStart: Bool = false) -> String {
        var out = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n"
        let offset = relativeToStart ? segmentStart : 0
        for cue in cues {
            let text = cueText(cue.text)
            if text.isEmpty { continue }
            let s = max(0, cue.start - offset)
            let e = max(s, cue.end - offset)
            out += "\(timestamp(s)) --> \(timestamp(e))\n\(text)\n\n"
        return out

    /// Inline styles WebVTT and the cue sources share: `<i>`, `<b>`, `<u>`.

    /// Cue text as a valid WebVTT cue payload.
    ///
    /// Cue text was the sanitized plain text pasted in verbatim, which broke the file three ways:
    /// a bare `&` or `<` is a parse error or an unknown tag (`<laughs>` vanished, "Tom & Jerry"
    /// is an invalid character reference), a blank line ENDS the cue so a two-paragraph cue lost
    /// its second paragraph and the parser read it as a cue identifier, and `-->` makes the line a
    /// timing line. Escaping `&`, `<` and `>` removes the first and last; dropping every
    /// whitespace-only line removes the middle one.
    ///
    /// Italic, bold and underline survive from both spellings a cue can carry: SRT tags (`<i>`,
    /// `<b>`, `<u>`, any case) and ASS overrides (`\i`, `\b` including weights, `\u`, `\r` resets).
    /// Tags are re-emitted lazily right before the text they cover and closed innermost first, so
    /// crossed, stray and unterminated tags still come out properly nested and empty spans vanish.
    /// Every other override block is dropped, as is the text of ASS drawings (`\p1` .. `\p0`),
    /// which is vector commands, not words. An unclosed `{` stays literal, as in
    /// `MovTextSampleBuilder.sanitize`. SRT/HTML tags WebVTT has no tag for (`<font ...>`, `<s>`,
    /// `<span ...>`) are dropped rather than escaped: escaping would print them on screen, where a
    /// WebVTT parser used to swallow them as unknown tags.
        }
        return out
    }

    /// `tag` as `prefix` followed by digits and nothing else, so `\b1` and `\b700` parse while
    /// `\bord2`, `\be1`, `\iclip(...)` and `\pbo` do not (same rule as `SubtitleRectText`).
    private static func assInt(_ tag: Substring, after prefix: String) -> Int? {
        guard tag.hasPrefix(prefix) else { return nil }
        let rest = tag.dropFirst(prefix.count)
        guard !rest.isEmpty, rest.allSatisfy(\.isNumber) else { return nil }
        return Int(rest)
    }

    /// An SRT `<i>`, `<b>`, `<u>` or closing tag (any case) starting at `index`: the style, whether
    /// it opens, and its length. Anything else is literal text and gets escaped.
    private static func srtTag(_ chars: [Character], at index: Int)
        -> (style: InlineStyle, opens: Bool, length: Int)? {
        var j = index + 1
        let closing = j < chars.count && chars[j] == "/"
        if closing { j += 1 }
        guard j + 1 < chars.count, chars[j + 1] == ">",
              let letter = chars[j].lowercased().first,
              let style = InlineStyle(rawValue: letter) else { return nil }
        return (style, !closing, j + 2 - index)
    }

    /// SRT/HTML formatting tags that carry nothing WebVTT can express.
    private static let unrepresentableTags: Set<String> = ["font", "s", "span"]

    /// Length of an opening or closing `unrepresentableTags` tag starting at `index` (any case,
    /// any attributes, on one line), or nil. The name must end at `>` or whitespace, so `<fonts>`
    /// and `<spanner>` stay literal text, as does a tag with no `>` before the line ends.
    private static func unrepresentableTagLength(_ chars: [Character], at index: Int) -> Int? {
        var j = index + 1
        if j < chars.count, chars[j] == "/" { j += 1 }
        var name = ""
        while j < chars.count, chars[j].isLetter { name.append(chars[j]); j += 1 }
        guard unrepresentableTags.contains(name.lowercased()), j < chars.count,
              chars[j] == ">" || (chars[j].isWhitespace && !chars[j].isNewline) else { return nil }
        while j < chars.count, chars[j] != ">" {
            if chars[j] == "<" || chars[j].isNewline { return nil }
            j += 1
        }
        return j < chars.count ? j + 1 - index : nil
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = max(0, SourceTimestampBounds.clampedSeconds(seconds))
        let whole = Int(total)
        let h = whole / 3600
        let m = (whole % 3600) / 60
        let s = whole % 60
        let ms = min(999, Int((total - Double(whole)) * 1000.0 + 0.5))
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}
