// Sources/AetherEngine/Subtitles/NativeSubtitleCueStore.swift
import Foundation

/// A native mov_text subtitle track exposed to hosts after load (#55). `ordinal` is the 0-based index into the muxer's text tracks and matches the `group.options` position in the AVPlayer legible group. `language` is the ISO 639 tag (nil when absent); `displayName` is the locale display name of `language`, or "Subtitle <n>" fallback.
public struct NativeSubtitleTrack: Sendable, Equatable {
    public let ordinal: Int
    public let language: String?
    public let displayName: String

    /// Count of tracks in `tracks[0..<ordinal]` sharing `tracks[ordinal]`'s language; used by `setNativeSubtitleSelected` to disambiguate same-language AVMediaSelectionOptions (e.g. eng "Full" vs eng "SDH"). Returns 0 when out of range or no language.
    public static func sameLanguageRank(of ordinal: Int, in tracks: [NativeSubtitleTrack]) -> Int {
        guard ordinal < tracks.count, let lang = tracks[ordinal].language else { return 0 }
        return tracks[0..<ordinal].filter { $0.language == lang }.count
    }
}

/// Sole owner of the decoded-cue array backing the native mov_text track (#55). Text `SubtitleCue`s only, never packet data, so footprint is bounded by cue count (leak guard). Producer drains `cuesInWindow` per segment cut to build mov_text samples on the AVPlayer axis.
final class NativeSubtitleCueStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cues: [SubtitleCue] = []
    private var shiftSeconds: Double = 0
    /// The subtitle delay the rendition serves (`LoadOptions.subtitleDelaySeconds`): positive shows every
    /// line later. Only the served times carry it; the reading and the cues stay on the source axis.
    private var servedDelaySeconds: Double = 0
    private var finished = false
    /// Sodalite#32: the pump tap and a side reader can feed the same store concurrently (and a producer
    /// restart re-reads a region), so appends dedup on (start, end, text) instead of trusting the source.
    private var seenKeys: Set<String> = []
    /// Highest cue end appended (source axis). `cues.last` stopped being the read head once two feeders
    /// with different positions share the store.
    private var maxCueEndSeconds: Double = 0
    /// The stretch of the source a feeder has READ for this track (source axis), contiguous from where it
    /// began. `maxCueEndSeconds` says how far the cues reach, which on a sparse track (a forced one, whose
    /// lines cover foreign dialogue only) can sit minutes behind the reading: there "no cue yet" and "no
    /// line here" read the same off the cues, and only this tells them apart.
    private var readSpan: (from: Double, through: Double)?
    /// When a feeder's reading of this track last moved forward.
    private var lastReadAdvance: DispatchTime?
    /// The furthest window end the player has asked this rendition for (AVPlayer axis): how far ahead it
    /// reads it, which is what a feeder has to be ahead of.
    private var furthestRequestedEnd: Double = 0
    /// Called the first time the player asks for this rendition (its media playlist), which is the
    /// moment AVKit selected it, whoever asked it to.
    private var renditionRequestedHandler: (@Sendable () -> Void)?

    init() {}

    /// What to do when the player asks for this rendition. Fires once per request; the handler makes
    /// repeated requests harmless.
    func onRenditionRequested(_ handler: (@Sendable () -> Void)?) {
        lock.lock(); renditionRequestedHandler = handler; lock.unlock()
    }

    /// The player fetched this rendition's media playlist.
    func noteRenditionRequested() {
        lock.lock(); let handler = renditionRequestedHandler; lock.unlock()
        handler?()
    }

    /// The player asked for this rendition's window ending at `end` (AVPlayer axis).
    func noteRequested(through end: Double) {
        guard end.isFinite else { return }
        lock.lock(); if end > furthestRequestedEnd { furthestRequestedEnd = end }; lock.unlock()
    }

    /// The furthest window end the player has asked for, on the source axis; nil before any request.
    func furthestRequestedSourceSeconds() -> Double? {
        lock.lock(); defer { lock.unlock() }
        return furthestRequestedEnd > 0 ? furthestRequestedEnd + shiftSeconds : nil
    }

    /// Whether a feeder's reading of this track moved forward within `seconds`: someone is filling it
    /// and getting closer to the windows still ahead. A feeder that has only started, or one that hands
    /// over its whole result at once (the container-index fill), is not: holding a request for either
    /// buys nothing.
    func isReadingAdvancing(within seconds: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let last = lastReadAdvance else { return false }
        return Double(DispatchTime.now().uptimeNanoseconds &- last.uptimeNanoseconds) / 1e9 <= seconds
    }

    private static func key(start: Double, end: Double, text: String) -> String {
        let start = SourceTimestampBounds.clampedSeconds(start), end = SourceTimestampBounds.clampedSeconds(end)
        return "\(Int((start * 1000).rounded()))|\(Int((end * 1000).rounded()))|\(text)"
    }

    func setShiftSeconds(_ s: Double) { lock.lock(); shiftSeconds = s; lock.unlock() }
    func setServedDelaySeconds(_ s: Double) { lock.lock(); servedDelaySeconds = s; lock.unlock() }

    /// Set once the reader has read the track to EOF, so a whole-program .vtt consumer knows every cue is present (Sodalite#32).
    func markFinished() { lock.lock(); finished = true; lock.unlock() }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    func replaceCues(_ newCues: [SubtitleCue]) {
        lock.lock(); defer { lock.unlock() }
        cues.removeAll(keepingCapacity: true)
        seenKeys.removeAll(keepingCapacity: true)
        maxCueEndSeconds = 0
        readSpan = nil
        appendLocked(newCues)
    }

    func appendCues(_ extra: [SubtitleCue]) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(extra)
    }

    private func appendLocked(_ extra: [SubtitleCue]) {
        for c in extra {
            guard let t = c.text else { continue }
            guard seenKeys.insert(Self.key(start: c.startTime, end: c.endTime, text: t)).inserted else { continue }
            cues.append(c)
            if c.endTime > maxCueEndSeconds { maxCueEndSeconds = c.endTime }
        }
    }

    func clear() {
        lock.lock()
        cues.removeAll(keepingCapacity: false)
        seenKeys.removeAll(keepingCapacity: false)
        maxCueEndSeconds = 0
        readSpan = nil
        finished = false
        lock.unlock()
    }

    /// A feeder has read the source from `from` through `through` (source axis) and every cue in it has
    /// been appended. A span that continues the one held extends it; one that does not (a reader that
    /// re-anchored after a seek) replaces it, because what was read before is no longer contiguous with
    /// what is read now.
    func noteRead(from: Double, through: Double) {
        guard from.isFinite, through.isFinite, through >= from else { return }
        lock.lock(); defer { lock.unlock() }
        if let span = readSpan, from >= span.from, from <= span.through + Self.readSeamSeconds {
            if through > span.through { lastReadAdvance = .now() }
            readSpan = (span.from, max(span.through, through))
        } else {
            lastReadAdvance = .now()
            readSpan = (from, through)
        }
    }

    /// Two notes that meet within this are one reading: a reader's next packet never lines up to the sample
    /// with the last one it reported.
    static let readSeamSeconds: Double = 0.25

    /// How far this track is known to have been read past `position` (AVPlayer axis): the reading span's
    /// end when the span holds `position`, and never less than the furthest cue end. A track whose readers
    /// do not report reads exactly as `readMaxCueEnd()`.
    func readThrough(at position: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        let cueEnd = cues.isEmpty ? 0 : maxCueEndSeconds - shiftSeconds
        guard let span = readSpan else { return cueEnd }
        let from = span.from - shiftSeconds, through = span.through - shiftSeconds
        guard position >= from - Self.readSeamSeconds, position <= through else { return cueEnd }
        return max(cueEnd, through)
    }

    /// The reading span on the axis `readThrough(at:)` answers on; nil before any feeder reported one.
    var readingSpan: (from: Double, through: Double)? {
        lock.lock(); defer { lock.unlock() }
        return readSpan.map { ($0.from - shiftSeconds, $0.through - shiftSeconds) }
    }

    var cueCount: Int { lock.lock(); defer { lock.unlock() }; return cues.count }

    /// Snapshot of all text cues sorted by start, source axis (the overlay backfill on selection,
    /// Sodalite#32 Phase 2: the tap has already harvested the produced region when the user enables
    /// subtitles, so the overlay starts fully populated instead of waiting on a side demuxer).
    func snapshotCues() -> [SubtitleCue] {
        lock.lock(); defer { lock.unlock() }
        return cues.sorted { $0.startTime < $1.startTime }
    }

    /// Cues served in `[start, end)` in AVPlayer-axis seconds, the served delay applied, so a cue the
    /// delay moves across a window's edge is served in the window where it now plays. Text only, sorted
    /// by start, each with its inline markup and the cue settings its placement asks for.
    func cuesInWindow(start: Double, end: Double) -> [WebVTTBuilder.Cue] {
        lock.lock()
        let snapshot = cues
        let offset = servedDelaySeconds - shiftSeconds
        lock.unlock()
        var out: [WebVTTBuilder.Cue] = []
        for c in snapshot {
            let text: String
            switch c.body {
            case .text(let t): text = t
            case .richText(let runs): text = WebVTTBuilder.markup(runs)
            case .image: continue
            }
            let s = c.startTime + offset
            let e = c.endTime + offset
            if e > start && s < end {
                out.append(.init(start: max(0, s), end: max(0, e), text: text,
                                 settings: c.placement.flatMap(WebVTTCueSettings.settings(for:))))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// All text cues as served, sorted by start (a whole-program .vtt). #15.
    func allCues() -> [WebVTTBuilder.Cue] {
        cuesInWindow(start: 0, end: .greatestFiniteMagnitude)
    }

    /// Highest cue end seen (shift-applied AVPlayer seconds), or 0 if empty. Marks how far ANY feeder
    /// (pump tap or side reader) has covered; the .vtt handler waits on this so AVPlayer gets cues
    /// instead of an empty segment when it fetches ahead of the coverage (#15).
    func readMaxCueEnd() -> Double {
        lock.lock(); defer { lock.unlock() }
        guard !cues.isEmpty else { return 0 }
        return maxCueEndSeconds - shiftSeconds
    }
}
