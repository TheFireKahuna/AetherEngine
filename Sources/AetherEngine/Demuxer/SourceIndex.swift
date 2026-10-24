import Foundation
import AetherLibavutil

/// A source's container index, whichever container it is: where each subtitle frame lies and when it
/// plays, read once per source (`SourceIndexRegistry`) and shared by every consumer. A Matroska file's
/// Cues (`MatroskaCueIndex`) and an MP4's sample tables (`MP4SampleIndex`) both say it, and the
/// consumers (the indexed subtitle fill, the forward prefetch) read it through this one shape, so a
/// container the registry can index is a container every consumer can use.
///
/// A frame read here is the packet libavformat would hand over for the same frame: the same bytes, the
/// same time, the same duration. That is what lets a consumer read the index instead of walking the
/// stream without anything downstream telling the two apart.
protocol SourceIndex: Sendable {
    /// The subtitle tracks libavformat makes a stream of, in file order.
    var subtitleTracks: [SourceIndexTrack] { get }

    /// Codecs whose frame, read here, is the packet libavformat hands over for this container. A stream
    /// of any other codec is left to the walk.
    var packetCodecs: Set<String> { get }

    /// `track`'s frames in time order; empty for a track the index does not list.
    func blocks(track: UInt64) -> [SourceIndexBlock]

    /// The time base of `track`'s ticks. Asked only for a track `subtitleTracks` lists, which is how
    /// every consumer reaches one (`trackNumbers`).
    func timeBase(track: UInt64) -> AVRational

    /// Whether `track` can be read entirely from the index: every frame of it is listed and can be
    /// handed over as libavformat would. `frameCount` is the stream's own statistic where the file
    /// states one.
    func isComplete(track: UInt64, frameCount: Int?) -> Bool

    /// Reads `block` of `track`. With `prefix`, at most that many payload bytes (enough for a PGS
    /// composition header) instead of the whole frame. Nil when the block is not where the index says
    /// or could not be read.
    func readFrame(_ block: SourceIndexBlock, track: UInt64, from source: RandomAccessByteSource,
                   prefix: Int?) -> SourceIndexFrame?

    /// Whether the keyframes of video `track` can be read here (`readKeyframe`).
    func coversKeyframes(track: UInt64) -> Bool

    /// The keyframe of video `track` that libavformat's index places at `position` (the entry the
    /// session's segment plan was built from, `Demuxer.indexedKeyframeEntries`), as the packet
    /// libavformat hands over for it: an MP4 sample's own bytes; on Matroska the block of the cluster
    /// at `position` whose time is nearest `ticks` (on `timeBase(track:)`). Nil when the index does not
    /// list it or it could not be read.
    func readKeyframe(track: UInt64, position: Int64, ticks: Int64, from source: RandomAccessByteSource) -> [UInt8]?
}

/// Why a source has no index.
enum SourceIndexError: Error, Equatable {
    /// A container no index reader covers.
    case unsupportedContainer
    /// The container could carry an index and this file does not (a Matroska file without Cues, a
    /// fragmented MP4 whose samples are listed fragment by fragment).
    case noIndex
    /// The read broke off or found the structure where it should not be. Not remembered: an origin
    /// dropping a range produces it as readily as a corrupt file.
    case malformed(String)
}

/// One indexed frame: its time on its track's time base and where it starts.
struct SourceIndexBlock: Sendable, Equatable {
    var ticks: Int64
    var durationTicks: Int64?
    /// The byte the frame's read starts at. For Matroska, the earliest byte its block can start at
    /// (the cluster's size field has a length the Cues do not state); for MP4, the sample itself.
    var offset: Int64
    /// The frame's length where the index states it (MP4); nil where the read finds it (Matroska).
    var size: Int?
}

/// One frame as libavformat hands it over.
struct SourceIndexFrame: Sendable {
    var ticks: Int64
    var durationTicks: Int64?
    /// The packet's bytes: for Matroska header-stripped bytes restored, zlib inflated, and a WebVTT
    /// block reduced to its cue text. Empty for a block libavformat would drop.
    var payload: [UInt8]
    /// WebVTT cue settings, which libavformat attaches as side data.
    var webVTTSettings: String?
    /// True when only the first bytes were read (`readFrame(..., prefix:)`).
    var isPrefix: Bool
}

/// A subtitle track as the index lists it.
struct SourceIndexTrack: Sendable, Equatable {
    var number: UInt64
    /// The libavcodec name of its codec; nil where the index cannot say.
    var codecName: String?
    var language: String?
    /// Frame and byte statistics where the file states them (mkvmerge's tags).
    var frames: Int? = nil
    var bytes: Int64? = nil
}

/// A video stream as libavformat lists it, and the track behind it.
struct IndexedVideoTrack: Sendable, Equatable {
    var streamIndex: Int32
    /// `AVStream.id`, as for `IndexedSubtitleStream.trackID`.
    var trackID: Int32
}

/// A subtitle stream as libavformat lists it, with what an index consumer needs of it.
struct IndexedSubtitleStream: Sendable {
    var streamIndex: Int32
    /// `AVStream.id`: the track's number where libavformat carries it (an MP4's track ID; Matroska's
    /// TrackNumber with FFmpegBuild's patch_ffmpeg_matroska_track_id), 0 where it does not.
    var trackID: Int32 = 0
    var codecName: String
    var language: String?
    /// The statistics libavformat copied onto the stream from the track's tags.
    var frames: Int? = nil
    var bytes: Int64? = nil
    var timeBase: AVRational
}

extension SourceIndex {
    func seconds(ticks: Int64, track: UInt64) -> Double {
        let base = timeBase(track: track)
        return Double(ticks) * Double(base.num) / Double(base.den)
    }

    /// The track behind each subtitle stream. The stream's own track number when libavformat carries
    /// it; otherwise the k-th subtitle stream is the k-th subtitle track. Either way every pair has to
    /// agree on codec, language and, where the file states them, its frame and byte statistics, which
    /// tell apart two tracks a stream count or an order cannot. A count or any pair that disagrees maps
    /// nothing: a wrong track would fill a rendition with another track's lines.
    func trackNumbers(for streams: [IndexedSubtitleStream]) -> [Int32: UInt64] {
        var pairs: [(IndexedSubtitleStream, SourceIndexTrack)] = []
        if !streams.isEmpty, streams.allSatisfy({ $0.trackID > 0 }) {
            for stream in streams {
                guard let track = subtitleTracks.first(where: { $0.number == UInt64(stream.trackID) }) else { return [:] }
                pairs.append((stream, track))
            }
        } else {
            guard streams.count == subtitleTracks.count else { return [:] }
            pairs = Array(zip(streams, subtitleTracks))
        }
        var out: [Int32: UInt64] = [:]
        for (stream, track) in pairs {
            if let codec = track.codecName, codec != stream.codecName { return [:] }
            if let a = stream.language?.lowercased(), let b = track.language?.lowercased(),
               a != "und", b != "und", !AetherEngine.languageMatches(a, b) { return [:] }
            if let a = stream.frames, let b = track.frames, a != b { return [:] }
            if let a = stream.bytes, let b = track.bytes, a != b { return [:] }
            out[stream.streamIndex] = track.number
        }
        return out
    }
}

extension SourceIndex {
    /// The whole frame of `block`.
    func readFrame(_ block: SourceIndexBlock, track: UInt64, from source: RandomAccessByteSource) -> SourceIndexFrame? {
        readFrame(block, track: track, from: source, prefix: nil)
    }
}
