import Foundation

/// Builds a WebVTT body from decoded cues on the AVPlayer timeline (#15). Text goes through
/// `cueText(_:)`: escaped, blank lines collapsed, italic/bold/underline kept, everything else of the
/// ASS markup stripped; a cue's placement rides as its cue settings. Served as a separate HLS
/// SUBTITLES rendition, which AVKit selects and draws; muxing timed text into the A/V fMP4 is
/// non-conformant for HLS (see #55).
enum WebVTTBuilder {
    /// One cue as served: its times, its text with the inline markup `cueText(_:)` reads (SRT tags or
    /// ASS overrides), and the cue settings that place it (`WebVTTCueSettings.settings(for:)`).
    struct Cue: Equatable, Sendable {
        var start: Double
        var end: Double
        var text: String
        var settings: String? = nil
    }

    /// `WEBVTT` header followed by one cue block per non-empty cue: `HH:MM:SS.mmm --> HH:MM:SS.mmm` + text.
    static func body(cues: [Cue]) -> String {
        var out = "WEBVTT\n\n"
        for cue in cues {
            let text = cueText(cue.text)
            if text.isEmpty { continue }
            out += "\(timing(cue.start, max(cue.start, cue.end), cue.settings))\n\(text)\n\n"
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
    static func segment(cues: [Cue],
                        segmentStart: Double = 0,
                        relativeToStart: Bool = false) -> String {
        var out = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n"
        let offset = relativeToStart ? segmentStart : 0
        for cue in cues {
            let text = cueText(cue.text)
            if text.isEmpty { continue }
            let s = max(0, cue.start - offset)
            let e = max(s, cue.end - offset)
            out += "\(timing(s, e, cue.settings))\n\(text)\n\n"
        }
        return out
    }

    /// A cue's timing line, its settings after the end time as the grammar places them.
    private static func timing(_ start: Double, _ end: Double, _ settings: String?) -> String {
        let line = "\(timestamp(start)) --> \(timestamp(end))"
        guard let settings, !settings.isEmpty else { return line }
        return line + " " + settings
    }

    /// Rich-text runs as the inline markup `cueText(_:)` reads: each run's italic, bold and underline as
    /// SRT tags around its text. Colour, font and size have no WebVTT form AVKit draws; the viewer's
    /// caption style and the host's text style rules decide them.
    static func markup(_ runs: [SubtitleTextRun]) -> String {
        runs.map { run in
            var text = run.text
            if run.isUnderlined { text = "<u>" + text + "</u>" }
            if run.isItalic { text = "<i>" + text + "</i>" }
            if run.isBold { text = "<b>" + text + "</b>" }
            return text
        }.joined()
    }

    /// Inline styles WebVTT and the cue sources share: `<i>`, `<b>`, `<u>`.
    private enum InlineStyle: Character {
        case italic = "i", bold = "b", underline = "u"
    }

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
    static func cueText(_ raw: String) -> String {
        let text = SubtitleRectText.capped(raw)
        var styled: [(char: Character, styles: [InlineStyle])] = []
        var active: [InlineStyle] = []   // in activation order, so `<b><i>` re-emits as written
        var drawing = false

        func set(_ style: InlineStyle, _ on: Bool) {
            active.removeAll { $0 == style }
            if on { active.append(style) }
        }

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "N" || n == "n" { styled.append(("\n", active)); i += 2; continue }
                if n == "h" { if !drawing { styled.append((" ", active)) }; i += 2; continue }
            }
            if c == "{", let close = chars[(i + 1)...].firstIndex(of: "}") {
                for tag in String(chars[(i + 1)..<close]).split(separator: "\\") {
                    if tag == "r" || (tag.hasPrefix("r") && !tag.hasPrefix("rnd")) {
                        active.removeAll()
                    } else if let v = assInt(tag, after: "b") {
                        set(.bold, v != 0)
                    } else if let v = assInt(tag, after: "i") {
                        set(.italic, v != 0)
                    } else if let v = assInt(tag, after: "u") {
                        set(.underline, v != 0)
                    } else if let v = assInt(tag, after: "p") {
                        drawing = v != 0
                    }
                }
                i = close + 1
                continue
            }
            if c == "<", let (style, opens, length) = srtTag(chars, at: i) {
                set(style, opens)
                i += length
                continue
            }
            if c == "<", let length = unrepresentableTagLength(chars, at: i) {
                i += length
                continue
            }
            if !drawing || c == "\n" { styled.append((c, active)) }
            i += 1
        }

        // Drop whitespace-only lines (blank lines end a WebVTT cue), which also trims the edges.
        var lines: [ArraySlice<(char: Character, styles: [InlineStyle])>] = []
        var lineStart = 0
        for index in 0...styled.count where index == styled.count || styled[index].char == "\n" {
            let line = styled[lineStart..<index]
            if !line.allSatisfy({ $0.char.isWhitespace }) { lines.append(line) }
            lineStart = index + 1
        }

        var out = ""
        var open: [InlineStyle] = []
        // Close down to the longest prefix of `open` that `styles` still wants.
        func close(keeping styles: [InlineStyle]) {
            var keep = 0
            while keep < open.count, styles.contains(open[keep]) { keep += 1 }
            for style in open[keep...].reversed() { out += "</\(style.rawValue)>" }
            open.removeSubrange(keep...)
        }
        for (number, line) in lines.enumerated() {
            if number > 0 {
                // Close what the next line drops before the break, not after it.
                close(keeping: line.first?.styles ?? [])
                out += "\n"
            }
            for (char, styles) in line {
                close(keeping: styles)
                for style in styles where !open.contains(style) {
                    out += "<\(style.rawValue)>"
                    open.append(style)
                }
                switch char {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                default: out.append(char)
                }
            }
        }
        close(keeping: [])
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
