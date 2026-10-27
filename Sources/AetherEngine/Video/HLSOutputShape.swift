import Foundation

/// How a session's HLS output carries its audio (docs/demuxed-audio.md). Decided in `prepare()`, before the
/// first producer is built, and fixed for the session's life.
enum HLSOutputShape: String, Sendable, Equatable {
    /// Apple's shape for HLS audio: video in the variant's media playlist, audio a rendition of its own
    /// (`EXT-X-MEDIA:TYPE=AUDIO,URI=...`) with its own init and segments on the same indices. Served through the
    /// master; where the master is refused, the two are joined into one playlist that plays alone (`FMP4Join`).
    case demuxed
    /// Video and audio in one file per segment, written so by the producer: a session planned for the media
    /// playlist (an HDR source on a panel not in HDR, an HDR source with no frame rate), and one whose playlist
    /// waits on the settled panel (live, an unproven display the load may not attempt). It plays from either
    /// playlist.
    case muxed

    /// The shape for a load whose playlist is planned (`HLSVideoEngine.plannedServesMaster`): demuxed only when
    /// the master is what it will be served, and audio is what it carries.
    static func forPlan(servesMaster: Bool?, carriesAudio: Bool) -> HLSOutputShape {
        servesMaster == true && carriesAudio ? .demuxed : .muxed
    }
}
