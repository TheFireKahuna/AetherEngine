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
    /// costs no size probe of its own.
    nonisolated static func indexedSourceReader(url: URL, headers: [String: String], label: String)
        -> HTTPDiscIOReader?
    {
        HTTPDiscIOReader(url: url, extraHeaders: headers, baseChunkSize: 4096, maxChunkSize: 4 * 1024 * 1024,
                         knownSize: SourceByteCache.shared.knownSize(SourceCacheKey(url: url, headers: headers)),
                         sourceCache: .shared, label: label)
    }

    /// A subtitle stream as libavformat lists it, with what an index consumer needs beside it.
    struct IndexedSubtitleStream: Sendable {
        let stream: MatroskaCueIndex.SubtitleStream
        let frames: Int?
        let timeBase: AVRational
    }

    /// Every subtitle stream of `demuxer` in order (they map onto the TrackEntries by order).
    nonisolated static func matroskaSubtitleStreams(of demuxer: Demuxer) -> [IndexedSubtitleStream] {
        var out: [IndexedSubtitleStream] = []
        var index: Int32 = 0
        while let stream = demuxer.withStream(at: index, { st -> IndexedSubtitleStream? in
            guard st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { return nil }
            func tag(_ key: String) -> String? {
                av_dict_get(st.pointee.metadata, key, nil, AV_DICT_IGNORE_SUFFIX).map { String(cString: $0.pointee.value) }
            }
            let frames = tag("NUMBER_OF_FRAMES").flatMap { Int($0) }
            let subtitle = MatroskaCueIndex.SubtitleStream(
                streamIndex: index, trackID: st.pointee.id,
                codecName: String(cString: avcodec_get_name(st.pointee.codecpar.pointee.codec_id)),
                language: av_dict_get(st.pointee.metadata, "language", nil, 0).map { String(cString: $0.pointee.value) },
                frames: frames, bytes: tag("NUMBER_OF_BYTES").flatMap { Int64($0) })
            return IndexedSubtitleStream(stream: subtitle, frames: frames, timeBase: st.pointee.time_base)
        }) {
            if let stream { out.append(stream) }
            index += 1
        }
        return out
    }

    /// The forward subtitle prefetch's packets from the container's index (#151), or nil to walk the
    /// stream: remote Matroska whose index lists every stream the walk would harvest completely
    /// (`SubtitleForwardPrefetcher.IndexSource.plan`). A local file has no film to save and a custom
    /// source's reader is the host's. The reader comes back with the source because it is the
    /// session's to cancel and close.
    nonisolated func indexedForwardPrefetchSource(
        url: URL, headers: [String: String], headerStore: RequestHeaderStore?, demuxer: Demuxer,
        streams: Set<Int32>, assembly: Set<Int32>, startAt: Double
    ) async -> (source: SubtitleForwardPrefetcher.IndexSource, reader: HTTPDiscIOReader)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              demuxer.containerFormatName?.contains("matroska") == true else { return nil }
        var requestHeaders = headers
        requestHeaders.merge(headerStore?.current ?? [:]) { _, new in new }
        guard let reader = Self.indexedSourceReader(url: url, headers: requestHeaders, label: "prefetch")
        else { return nil }
        guard let index = await SourceIndexRegistry.shared.matroskaIndex(
            of: url, headers: requestHeaders, through: reader).index
        else {
            reader.close()
            return nil
        }
        let plan = SubtitleForwardPrefetcher.IndexSource.plan(
            index: index, listed: Self.matroskaSubtitleStreams(of: demuxer), streams: streams)
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
