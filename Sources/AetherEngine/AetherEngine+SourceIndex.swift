import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// What every consumer of a source's container index shares, so they read it the same way: the
/// reader its blocks are fetched through, and the streams its tracks map onto.
extension AetherEngine {

    /// The exact range reader a remote source's index and blocks are read through
    /// (`RangeReadableIOReader`): no read-ahead window, held bytes served from the source cache, one
    /// reader for any number of lanes. It opens against the size the session already learned, so it
    /// costs no size probe of its own. A consumer that answers a viewer as it waits (a scrub thumbnail)
    /// gives each request a shorter `requestTimeout` and fewer retries.
    nonisolated static func indexedSourceReader(url: URL, headers: [String: String], label: String,
                                                requestTimeout: TimeInterval = 30, maxRetries: Int = 3)
        -> HTTPDiscIOReader?
    {
    }

    /// What a source's index and frames are read through: the file itself, or the exact range reader
    /// over a remote source. A host's own source is read through its own clone, which its caller has.
    nonisolated static func indexReader(url: URL, headers: [String: String], label: String,
                                        requestTimeout: TimeInterval = 30, maxRetries: Int = 3) -> IOReader? {
        if url.isFileURL { return FileIOReader(url: url) }
        return indexedSourceReader(url: url, headers: headers, label: label,
                                   requestTimeout: requestTimeout, maxRetries: maxRetries)
    }

    /// Every video stream of `demuxer` with its track, as an index pairs keyframes with it.
    nonisolated static func indexedVideoTracks(of demuxer: Demuxer) -> [IndexedVideoTrack] {
        var out: [IndexedVideoTrack] = []
        var index: Int32 = 0
        while let track = demuxer.withStream(at: index, { st -> IndexedVideoTrack? in
            st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO
                ? IndexedVideoTrack(streamIndex: index, trackID: st.pointee.id) : nil
        }) {
            if let track { out.append(track) }
            index += 1
        }
        return out
    }

    /// Every subtitle stream of `demuxer` in order, as an index consumer pairs it with its track.
    nonisolated static func indexedSubtitleStreams(of demuxer: Demuxer) -> [IndexedSubtitleStream] {
        var out: [IndexedSubtitleStream] = []
        var index: Int32 = 0
        while let stream = demuxer.withStream(at: index, { st -> IndexedSubtitleStream? in
            guard st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { return nil }
            func tag(_ key: String) -> String? {
                av_dict_get(st.pointee.metadata, key, nil, AV_DICT_IGNORE_SUFFIX).map { String(cString: $0.pointee.value) }
            }
            return IndexedSubtitleStream(
                streamIndex: index, trackID: st.pointee.id,
                codecName: String(cString: avcodec_get_name(st.pointee.codecpar.pointee.codec_id)),
                language: av_dict_get(st.pointee.metadata, "language", nil, 0).map { String(cString: $0.pointee.value) },
                frames: tag("NUMBER_OF_FRAMES").flatMap { Int($0) }, bytes: tag("NUMBER_OF_BYTES").flatMap { Int64($0) },
                timeBase: st.pointee.time_base)
        }) {
            if let stream { out.append(stream) }
            index += 1
        }
        return out
    }
}
