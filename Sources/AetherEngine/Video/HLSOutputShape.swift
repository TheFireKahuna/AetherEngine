import Foundation

/// How a session's HLS output carries its audio (docs/demuxed-audio.md). Decided in `prepare()`, before the
/// first producer is built, and fixed for the session's life.
enum HLSOutputShape: String, Sendable, Equatable {
    /// The HLS Authoring Specification's shape (9.5, 9.6): video in the variant's media playlist, audio a
    /// rendition of its own (`EXT-X-MEDIA:TYPE=AUDIO,URI=...`) with its own init and segments on the same
    /// indices. Served through the master.
    case demuxed
    /// Video and audio in one file per segment. A media playlist cannot name a rendition, so a session that may
    /// be played from the bare media playlist carries its audio this way: one whose master the panel or a
    /// receiver refuses (#98, #130, AirPlay to an SDR receiver), and one whose playlist waits on the settled
    /// panel. It plays from either playlist.
    case muxed

    /// The shape for a load whose playlist is planned (`HLSVideoEngine.plannedServesMaster`): demuxed only when
    /// the master is what it will be served, and audio is what it carries.
    static func forPlan(servesMaster: Bool?, carriesAudio: Bool) -> HLSOutputShape {
        servesMaster == true && carriesAudio ? .demuxed : .muxed
    }
}
