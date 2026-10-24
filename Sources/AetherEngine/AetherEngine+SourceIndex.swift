import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// What every consumer of a source's container index shares, so they read it the same way: the
/// reader its blocks are fetched through, and the subtitle streams its tracks map onto.
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
        HTTPDiscIOReader(url: url, extraHeaders: headers, baseChunkSize: 4096, maxChunkSize: 4 * 1024 * 1024,
                         maxRetries: maxRetries, requestTimeout: requestTimeout,
                         knownSize: SourceByteCache.shared.knownSize(SourceCacheKey(url: url, headers: headers)),
                         sourceCache: .shared, label: label)
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

    /// The forward subtitle prefetch's packets from the container's index (#151), or nil to walk the
    /// stream: a remote source whose index lists every stream the walk would harvest completely
    /// (`SubtitleForwardPrefetcher.IndexSource.plan`). A local file has no film to save and a custom
    /// source's reader is the host's. The reader comes back with the source because it is the
    /// session's to cancel and close.
    nonisolated func indexedForwardPrefetchSource(
        url: URL, headers: [String: String], headerStore: RequestHeaderStore?, demuxer: Demuxer,
        streams: Set<Int32>, assembly: Set<Int32>, startAt: Double
    ) async -> (source: SubtitleForwardPrefetcher.IndexSource, reader: HTTPDiscIOReader)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var requestHeaders = headers
        requestHeaders.merge(headerStore?.current ?? [:]) { _, new in new }
        guard let reader = Self.indexedSourceReader(url: url, headers: requestHeaders, label: "prefetch")
        else { return nil }
        guard let index = await SourceIndexRegistry.shared.index(
            of: url, headers: requestHeaders, demuxer: demuxer, through: reader).index
        else {
            reader.close()
            return nil
        }
        let plan = SubtitleForwardPrefetcher.IndexSource.plan(
            index: index, listed: Self.indexedSubtitleStreams(of: demuxer), streams: streams)
        guard plan.refused.isEmpty else {
            EngineLog.emit(
                "[AetherEngine] #151 forward prefetch: the index does not cover every stream "
                + "(\(plan.refused.joined(separator: ", "))); walking the stream",
                category: .engine)
            reader.close()
            return nil
        }
        let source = SubtitleForwardPrefetcher.IndexSource(
            index: index, bytes: IOReaderByteSource(reader, closesReader: false), streams: plan.streams,
            assemblyIndices: assembly, from: startAt)
        return (source, reader)
    }
}
