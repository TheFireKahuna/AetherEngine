import Foundation
import AetherLibavutil

/// An MP4's own index of its subtitle samples and video keyframes: the sample tables in its `moov`,
/// as libavformat read them at open. Not parsed again here: the demuxer that opened the source
/// already built every stream's entries from `stts`, `stsz`, `stco` and `stsc` with the edit list
/// applied, and those entries are what `av_read_frame` reads its packets from, so a sample read where
/// an entry says is the packet the walk would get, with its time. The walk, which on an MP4 delivers
/// every video keyframe to pace itself, is then not needed for the subtitles, and an I-frame
/// rendition reads each keyframe without a demuxer of its own.
///
/// A subtitle track is trusted only where the entries are the whole track as libavformat delivers
/// it. They are by construction in a file that is not fragmented: `av_read_frame` reads from these
/// entries and nothing else, and only a fragmented file adds to them (its samples are listed in each
/// `moof`, read as the stream is). Not `AVStream.nb_frames`, which counts the `stts` samples, edited
/// out or not. A track with an entry the edit list marked to discard is left to the walk. A keyframe
/// needs no whole track: each entry is its sample wherever it came from, and the keyframes a segment
/// plan lists are entries the demuxer had when the plan was built.
struct MP4SampleIndex: SourceIndex {

    struct Track: Sendable {
        var timeBase: AVRational
        var blocks: [SourceIndexBlock]
        /// Listed, and none of it to be discarded.
        var isWhole: Bool
    }

    var subtitleTracks: [SourceIndexTrack]
    var tracks: [UInt64: Track]
    /// Per video track, each keyframe's sample: its position to its size.
    var keyframeSamples: [UInt64: [Int64: Int]] = [:]

    /// `AVINDEX_KEYFRAME` and `AVINDEX_DISCARD_FRAME`, macros Swift does not import.
    private static let keyframe: Int32 = 0x0001
    private static let discardFrame: Int32 = 0x0002

    /// mov_text's sample is its packet: libavformat reads it with `av_get_packet` and changes nothing.
    var packetCodecs: Set<String> { ["mov_text"] }

    /// Reads the index of the MP4 `demuxer` opened, whose subtitle streams are `streams` and video
    /// streams `videoTracks`. `source` is read only for the file's top-level boxes, to tell a
    /// fragmented file. Only `SourceIndexRegistry` can call this (it alone makes a `ParseToken`).
    static func read(demuxer: Demuxer, streams: [IndexedSubtitleStream], videoTracks: [IndexedVideoTrack],
                     source: RandomAccessByteSource, token: SourceIndexRegistry.ParseToken) throws -> MP4SampleIndex {
        let fragmented = try isFragmented(source)
        var keyframeSamples: [UInt64: [Int64: Int]] = [:]
        for video in videoTracks where video.trackID > 0 {
            guard let table = demuxer.sampleTable(streamIndex: video.streamIndex) else {
                throw SourceIndexError.malformed("stream \(video.streamIndex) closed during the read")
            }
            var samples: [Int64: Int] = [:]
            for entry in table.entries where entry.flags & keyframe != 0 && entry.flags & discardFrame == 0 && entry.size > 0 {
                samples[entry.pos] = entry.size
            }
            keyframeSamples[UInt64(video.trackID)] = samples
        }
        var subtitleTracks: [SourceIndexTrack] = []
        var tracks: [UInt64: Track] = [:]
        for stream in streams where stream.trackID > 0 {
            // Gone only when the demuxer closed under the read; not an answer to keep.
            guard let table = demuxer.sampleTable(streamIndex: stream.streamIndex) else {
                throw SourceIndexError.malformed("stream \(stream.streamIndex) closed during the read")
            }
            let number = UInt64(stream.trackID)
            subtitleTracks.append(SourceIndexTrack(number: number, codecName: stream.codecName,
                                                   language: stream.language))
            tracks[number] = Track(timeBase: stream.timeBase, blocks: blocks(of: table),
                                   isWhole: !fragmented && !table.entries.isEmpty
                                       && table.entries.allSatisfy { $0.flags & discardFrame == 0 })
        }
        return MP4SampleIndex(subtitleTracks: subtitleTracks, tracks: tracks, keyframeSamples: keyframeSamples)
    }

    /// The entries as packets: a sample lasts until the next one starts, which is its `stts` delta,
    /// and the last one until the track ends, as `mov_finalize_packet` times them.
    private static func blocks(of table: DemuxedSampleTable) -> [SourceIndexBlock] {
        let end: Int64? = table.duration == Int64.min ? nil
            : (table.startTime == Int64.min ? 0 : table.startTime) + table.duration
        return table.entries.indices.map { i in
            let entry = table.entries[i]
            let next = i + 1 < table.entries.count ? table.entries[i + 1].timestamp : end
            return SourceIndexBlock(ticks: entry.timestamp, durationTicks: next.map { max(0, $0 - entry.timestamp) },
                                    offset: entry.pos, size: entry.size)
        }
    }

    /// Whether the file's `moov` carries an `mvex`, the mark of a fragmented file.
    private static func isFragmented(_ source: RandomAccessByteSource) throws -> Bool {
        // The demuxer opened it, so a moov is there: not finding one is a read that went wrong.
        guard let moov = try box("moov", from: 0, to: nil, in: source) else {
            throw SourceIndexError.malformed("no moov among the top-level boxes")
        }
        return try box("mvex", from: moov.payload, to: moov.end, in: source) != nil
    }

    /// The first box of `type` among the boxes from `start` up to `end` (nil: the end of the source).
    private static func box(_ type: String, from start: Int64, to end: Int64?,
                            in source: RandomAccessByteSource) throws -> (payload: Int64, end: Int64)? {
        var offset = start
        while end.map({ offset + 8 <= $0 }) ?? true {
            guard let header = source.read(at: offset, count: 16) else {
                throw SourceIndexError.malformed("box header at \(offset) unreadable")
            }
            guard header.count >= 8 else { return nil }
            let size32 = header[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let name = String(decoding: header[4..<8], as: UTF8.self)
            var headerLength: Int64 = 8
            var size = Int64(size32)
            if size32 == 1 {
                guard header.count >= 16 else { return nil }
                size = Int64(bitPattern: header[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
                headerLength = 16
            }
            if name == type { return (offset + headerLength, size == 0 ? (end ?? .max) : offset + size) }
            guard size >= headerLength else { return nil }   // 0: the box runs to the end, and it is not this one
            offset += size
        }
        return nil
    }

    // MARK: - SourceIndex

    func blocks(track: UInt64) -> [SourceIndexBlock] { tracks[track]?.blocks ?? [] }

    func timeBase(track: UInt64) -> AVRational {
        guard let entry = tracks[track] else { preconditionFailure("time base asked for track \(track), which the index does not list") }
        return entry.timeBase
    }

    func isComplete(track: UInt64, frameCount: Int?) -> Bool {
        guard let entry = tracks[track], entry.isWhole else { return false }
        return frameCount.map { $0 == entry.blocks.count } ?? true
    }

    func coversKeyframes(track: UInt64) -> Bool { !(keyframeSamples[track] ?? [:]).isEmpty }

    /// The sample at `position`, which is the keyframe's packet: libavformat reads it with
    /// `av_get_packet` as it stands.
    func readKeyframe(track: UInt64, position: Int64, ticks: Int64, from source: RandomAccessByteSource) -> [UInt8]? {
        guard let size = keyframeSamples[track]?[position],
              let bytes = source.read(at: position, count: size), bytes.count == size else { return nil }
        return bytes
    }

    func readFrame(_ block: SourceIndexBlock, track: UInt64, from source: RandomAccessByteSource,
                   prefix: Int?) -> SourceIndexFrame? {
        guard let size = block.size else { return nil }
        let count = prefix.map { min($0, size) } ?? size
        guard let bytes = source.read(at: block.offset, count: count), bytes.count == count else { return nil }
        return SourceIndexFrame(ticks: block.ticks, durationTicks: block.durationTicks, payload: bytes,
                                webVTTSettings: nil, isPrefix: count < size)
    }
}

/// One stream's entries in libavformat's index, with the stream facts that time them.
struct DemuxedSampleTable: Sendable {
    struct Entry: Sendable {
        var timestamp: Int64
        var pos: Int64
        var size: Int
        var flags: Int32
    }

    var startTime: Int64
    var duration: Int64
    var entries: [Entry]
}
