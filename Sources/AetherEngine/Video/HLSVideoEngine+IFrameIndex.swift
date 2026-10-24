// Sources/AetherEngine/Video/HLSVideoEngine+IFrameIndex.swift
import Foundation

extension HLSVideoEngine {

    /// Whether the source's index places the session's video keyframes, for the I-frame rendition
    /// (`IFrameKeyframeReader.Resolution`). Asked of `SourceIndexRegistry`, so a source the subtitle
    /// fill or the prefetch already indexed is not parsed again. `custom` is a host source's own clone,
    /// which the caller closes; any other source is read through an exact reader opened here, with the
    /// shorter request budget a scrub thumbnail waits on.
    nonisolated static func iFrameKeyframeIndex(url: URL, headers: [String: String], demuxer: Demuxer,
                                                custom: IOReader?) async -> IFrameKeyframeReader.Resolution {
        guard let video = AetherEngine.indexedVideoTracks(of: demuxer)
                .first(where: { $0.streamIndex == demuxer.videoStreamIndex }),
              video.trackID > 0 else {
            return .notIndexed("the video stream names no track")
        }
        let track = UInt64(video.trackID)
        guard let reader = custom ?? AetherEngine.indexReader(url: url, headers: headers, label: "iframe",
                                                              requestTimeout: 8, maxRetries: 1) else {
            return .failed("the source could not be opened for exact reads")
        }
        let owned = custom == nil
        func release() { if owned { reader.close() } }
        switch await SourceIndexRegistry.shared.index(of: url, headers: headers, demuxer: demuxer, through: reader) {
        case .indexed(let index) where index.coversKeyframes(track: track):
            return .indexed(.init(index: index, track: track,
                                  bytes: IOReaderByteSource(reader, closesReader: owned),
                                  cancel: { reader.cancel() }))
        case .indexed:
            release()
            return .notIndexed("the index lists no keyframes of track \(track)")
        case .unavailable(.malformed(let why)):
            release()
            return .failed(why)
        case .unavailable(let error):
            release()
            return .notIndexed("\(demuxer.containerFormatName ?? "the container"): \(error)")
        }
    }
}
