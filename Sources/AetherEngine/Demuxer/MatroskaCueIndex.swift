import Compression
import Foundation

/// A Matroska file's own index of its subtitle blocks, read off the container instead of out of the
/// stream: the Cues element lists every block of a subtitle track with its exact position (cluster and
/// `CueRelativePosition`, which mkvmerge writes by default), so a track's whole content can be fetched
/// with a few hundred small range reads instead of reading the multi-gigabyte remux around it.
///
/// Trusted only where it is provably complete: a track whose cue entries number exactly its
/// `NUMBER_OF_FRAMES` statistic (mkvmerge's statistics tags), all of them with a relative position, and
/// whose frames are either uncompressed, zlib-compressed (the subtitle decoder inflates those itself) or
/// header-stripped. Anything else is left to the readers that walk the stream.
/// A Matroska source's own index, its Cues, read once per source (`SourceIndexRegistry`): where every
/// subtitle block and every video keyframe lies, by time. The subtitle consumers read blocks exactly
/// where it says; the video keyframes are what an I-frame rendition and a seek are built on.
struct MatroskaCueIndex: Sendable {

    /// One indexed block: its timestamp in segment ticks and where it lives.
    struct Block: Sendable, Equatable {
        var ticks: Int64
        /// Cluster position relative to the segment's data, as the Cues state it.
        var clusterPosition: Int64
        /// Position of the BlockGroup or SimpleBlock relative to the cluster's data.
        var relativePosition: Int64
        var durationTicks: Int64?
    }

    /// How a track's frames are stored (Matroska ContentEncoding).
    enum FrameEncoding: Sendable, Equatable {
        case none
        /// zlib; `readFrame` inflates it, as libavformat does.
        case zlib
        /// Header stripping: these bytes were removed from the front of every frame.
        case strippedHeader([UInt8])
        /// Anything this reader cannot undo (bzlib, lzo, encryption).
        case unsupported
    }

    let segmentDataStart: Int64
    /// Nanoseconds per tick (Info TimestampScale, 1 ms when absent).
    let timestampScale: Int64
    let blocksByTrack: [UInt64: [Block]]
    /// Tracks with at least one cue entry lacking a relative position: listed, not addressable.
    let tracksMissingRelativePosition: Set<UInt64>
    let encodingByTrack: [UInt64: FrameEncoding]
    /// The subtitle TrackEntries libavformat makes a stream of, in file order (it skips an entry with
    /// no CodecID or one whose CodecID does not start with S or D, `matroska_parse_tracks`).
    var subtitleTracks: [SubtitleTrack] = []
    /// mkvmerge's statistics tags per TrackNumber, read off the file's Tags.
    var statistics: [UInt64: TrackStatistics] = [:]

    struct SubtitleTrack: Sendable, Equatable {
        var number: UInt64
        var codecID: String
        var language: String?
    }

    /// A video TrackEntry, in file order.
    struct VideoTrack: Sendable, Equatable {
        var number: UInt64
        var codecID: String
    }

    /// A cue point of a video track: a keyframe, by its timestamp and where it lies. The Cues name the
    /// cluster always and the block within it only when the muxer wrote `CueRelativePosition`; a
    /// keyframe without it is still the cluster's first frame of that track, which is where muxers put
    /// it, so it is kept rather than dropped as the subtitle blocks are.
    struct Keyframe: Sendable, Equatable {
        var ticks: Int64
        /// Cluster position relative to the segment's data, as the Cues state it.
        var clusterPosition: Int64
        /// Position of the block relative to the cluster's data, when the Cues state it.
        var relativePosition: Int64?
    }

    /// The video TrackEntries.
    var videoTracks: [VideoTrack] = []
    /// Every video track's keyframes, in time order.
    var keyframesByTrack: [UInt64: [Keyframe]] = [:]

    /// `track`'s keyframes in time order; empty for a track the Cues do not list.
    func keyframes(track: UInt64) -> [Keyframe] { keyframesByTrack[track] ?? [] }

    /// Where `keyframe`'s cluster begins in the file: the byte a read of that keyframe starts at.
    func byteOffset(of keyframe: Keyframe) -> Int64 { segmentDataStart + keyframe.clusterPosition }

    struct TrackStatistics: Sendable, Equatable {
        var frames: Int?
        var bytes: Int64?
    }
    /// The length of the clusters' size field when the clusters sampled at load agree: tried first, and
    /// the other lengths after it, since a muxer can write a few clusters differently.
    var clusterSizeFieldLength: Int?

    func seconds(ticks: Int64) -> Double { Double(ticks) * Double(timestampScale) / 1e9 }

    /// Whether `track` can be read entirely from the index: every one of its `frameCount` frames has an
    /// addressable entry and its frames can be handed to the decoder.
    func isComplete(track: UInt64, frameCount: Int?) -> Bool {
        guard let frameCount, frameCount > 0, let blocks = blocksByTrack[track],
              !tracksMissingRelativePosition.contains(track) else { return false }
        if case .unsupported = encodingByTrack[track] ?? .none { return false }
        return blocks.count == frameCount
    }

    // MARK: - Reading

    enum ReadError: Error, Equatable {
        case notMatroska
        case noCues
        case malformed(String)
    }

    static let cuesSizeLimit = 64 * 1024 * 1024
    static let headProbeBytes = 64 * 1024

    /// Parses the index. Only `SourceIndexRegistry` can call this (it alone makes a `ParseToken`):
    /// a source's index is parsed once and shared, never read again by the next consumer.
    static func read(from source: RandomAccessByteSource,
                     token: SourceIndexRegistry.ParseToken) throws -> MatroskaCueIndex {
        guard let head = source.read(at: 0, count: headProbeBytes), head.count > 16 else {
            throw ReadError.notMatroska
        }
        var cursor = 0
        guard let ebml = EBML.element(head, at: cursor), ebml.id == 0x1A45DFA3 else { throw ReadError.notMatroska }
        cursor = ebml.dataStart + Int(ebml.size)
        guard let segment = EBML.element(head, at: cursor), segment.id == 0x18538067 else {
            throw ReadError.notMatroska
        }
        let segmentDataStart = Int64(segment.dataStart)

        // Top-level elements before the first cluster, and the SeekHead's pointers to the rest.
        var positions: [UInt32: Int64] = [:]
        var inHead: [UInt32: EBML.Element] = [:]
        var offset = segment.dataStart
        while let element = EBML.element(head, at: offset), element.id != 0x1F43B675 {
            inHead[element.id] = element
            if element.id == 0x114D9B74 {
                for seek in EBML.children(head, of: element) where seek.id == 0x4DBB {
                    var id: UInt32?
                    var position: Int64?
                    for field in EBML.children(head, of: seek) {
                        if field.id == 0x53AB { id = UInt32(truncatingIfNeeded: EBML.uint(head, field)) }
                        if field.id == 0x53AC { position = Int64(EBML.uint(head, field)) }
                    }
                    if let id, let position, positions[id] == nil { positions[id] = segmentDataStart + position }
                }
            }
            guard !element.unknownSize, element.dataStart + Int(element.size) <= head.count else { break }
            offset = element.dataStart + Int(element.size)
        }

        func load(_ id: UInt32, limit: Int) throws -> ([UInt8], EBML.Element)? {
            if let element = inHead[id], element.dataStart + Int(element.size) <= head.count { return (head, element) }
            guard let position = positions[id] else { return nil }
            guard let header = source.read(at: position, count: 16),
                  let element = EBML.element(header, at: 0), element.id == id, !element.unknownSize else {
                throw ReadError.malformed("element \(String(id, radix: 16)) not where the SeekHead says")
            }
            let total = element.dataStart + Int(element.size)
            guard total <= limit else { throw ReadError.malformed("element \(String(id, radix: 16)) too large") }
            guard let bytes = source.read(at: position, count: total), bytes.count == total else {
                throw ReadError.malformed("element \(String(id, radix: 16)) short read")
            }
            return (bytes, element)
        }

        var timestampScale: Int64 = 1_000_000
        if let (bytes, info) = try load(0x1549A966, limit: 1 << 20) {
            for field in EBML.children(bytes, of: info) where field.id == 0x2AD7B1 {
                let value = Int64(EBML.uint(bytes, field))
                if value > 0 { timestampScale = value }
            }
        }

        var encodings: [UInt64: FrameEncoding] = [:]
        var subtitleTracks: [SubtitleTrack] = []
        var videoTracks: [VideoTrack] = []
        var numberByUID: [UInt64: UInt64] = [:]
        if let (bytes, tracks) = try load(0x1654AE6B, limit: 16 << 20) {
            for entry in EBML.children(bytes, of: tracks) where entry.id == 0xAE {
                var number: UInt64?
                var type: UInt64?
                var codec = ""
                var language: String? = "eng"   // the Matroska default
                var bcp47: String?
                var uid: UInt64?
                var encoding: FrameEncoding = .none
                for field in EBML.children(bytes, of: entry) {
                    switch field.id {
                    case 0xD7: number = EBML.uint(bytes, field)
                    case 0x73C5: uid = EBML.uint(bytes, field)
                    case 0x83: type = EBML.uint(bytes, field)
                    case 0x86: codec = EBML.string(bytes, field)
                    case 0x22B59C: language = EBML.string(bytes, field)
                    case 0x22B59D: bcp47 = EBML.string(bytes, field)
                    case 0x6D80: encoding = frameEncoding(bytes, encodings: field)
                    default: break
                    }
                }
                guard let number else { continue }
                encodings[number] = encoding
                if let uid { numberByUID[uid] = number }
                if type == 0x11, let first = codec.first, first == "S" || first == "D" {
                    subtitleTracks.append(SubtitleTrack(number: number, codecID: codec, language: bcp47 ?? language))
                }
                if type == 0x01 { videoTracks.append(VideoTrack(number: number, codecID: codec)) }
            }
        }

        var statistics: [UInt64: TrackStatistics] = [:]
        if let (bytes, tags) = try? load(0x1254C367, limit: 16 << 20) {
            for tag in EBML.children(bytes, of: tags) where tag.id == 0x7373 {
                var uids: [UInt64] = []
                var stats = TrackStatistics()
                for field in EBML.children(bytes, of: tag) {
                    if field.id == 0x63C0 {
                        for target in EBML.children(bytes, of: field) where target.id == 0x63C5 {
                            uids.append(EBML.uint(bytes, target))
                        }
                    }
                    guard field.id == 0x67C8 else { continue }
                    var name = ""
                    var value = ""
                    for part in EBML.children(bytes, of: field) {
                        if part.id == 0x45A3 { name = EBML.string(bytes, part) }
                        if part.id == 0x4487 { value = EBML.string(bytes, part) }
                    }
                    if name == "NUMBER_OF_FRAMES" { stats.frames = Int(value) }
                    if name == "NUMBER_OF_BYTES" { stats.bytes = Int64(value) }
                }
                guard stats.frames != nil || stats.bytes != nil else { continue }
                for uid in uids { if let number = numberByUID[uid] { statistics[number] = stats } }
            }
        }

        guard let (bytes, cues) = try load(0x1C53BB6B, limit: cuesSizeLimit) else { throw ReadError.noCues }
        var blocks: [UInt64: [Block]] = [:]
        var keyframes: [UInt64: [Keyframe]] = [:]
        let videoNumbers = Set(videoTracks.map(\.number))
        var missingRelative: Set<UInt64> = []
        for point in EBML.children(bytes, of: cues) where point.id == 0xBB {
            var ticks: Int64?
            var positionsAtTime: [(track: UInt64, cluster: Int64, relative: Int64?, block: Block?)] = []
            for field in EBML.children(bytes, of: point) {
                if field.id == 0xB3 { ticks = Int64(EBML.uint(bytes, field)) }
                guard field.id == 0xB7 else { continue }
                var track: UInt64?
                var cluster: Int64?
                var relative: Int64?
                var duration: Int64?
                for value in EBML.children(bytes, of: field) {
                    switch value.id {
                    case 0xF7: track = EBML.uint(bytes, value)
                    case 0xF1: cluster = Int64(EBML.uint(bytes, value))
                    case 0xF0: relative = Int64(EBML.uint(bytes, value))
                    case 0xB2: duration = Int64(EBML.uint(bytes, value))
                    default: break
                    }
                }
                guard let track, let cluster else { continue }
                positionsAtTime.append((track, cluster, relative, relative.map {
                    Block(ticks: 0, clusterPosition: cluster, relativePosition: $0, durationTicks: duration)
                }))
            }
            guard let ticks else { continue }
            for (track, cluster, relative, block) in positionsAtTime {
                if videoNumbers.contains(track) {
                    keyframes[track, default: []].append(
                        Keyframe(ticks: ticks, clusterPosition: cluster, relativePosition: relative))
                }
                guard var block else { missingRelative.insert(track); continue }
                block.ticks = ticks
                blocks[track, default: []].append(block)
            }
        }
        for track in blocks.keys { blocks[track]?.sort { $0.ticks < $1.ticks } }
        for track in keyframes.keys { keyframes[track]?.sort { $0.ticks < $1.ticks } }
        var index = MatroskaCueIndex(segmentDataStart: segmentDataStart, timestampScale: timestampScale,
                                          blocksByTrack: blocks, tracksMissingRelativePosition: missingRelative,
                                          encodingByTrack: encodings)
        index.subtitleTracks = subtitleTracks
        index.videoTracks = videoTracks
        index.keyframesByTrack = keyframes
        index.statistics = statistics
        index.clusterSizeFieldLength = sampledClusterSizeFieldLength(index, from: source)
        return index
    }

    /// Reads the headers of a few clusters spread over the file: one size-field length for all of them
    /// is the muxer's, and every block read can then start exactly where its block does.
    private static func sampledClusterSizeFieldLength(_ index: MatroskaCueIndex,
                                                      from source: RandomAccessByteSource) -> Int? {
        let clusters = Set(index.blocksByTrack.values.flatMap { $0.map(\.clusterPosition) }).sorted()
        guard !clusters.isEmpty else { return nil }
        let picks = Set([0, clusters.count / 3, 2 * clusters.count / 3, clusters.count - 1]).map { clusters[$0] }
        var lengths: Set<Int> = []
        for position in picks {
            guard let header = source.read(at: index.segmentDataStart + position, count: 12),
                  let element = EBML.element(header, at: 0), element.id == 0x1F43B675 else { return nil }
            lengths.insert(element.dataStart - 4)
        }
        return lengths.count == 1 ? lengths.first : nil
    }

    /// ContentEncodings: compression the frames carry (scope 1). Several encodings, or encryption, is
    /// more than this reader undoes.
    private static func frameEncoding(_ bytes: [UInt8], encodings: EBML.Element) -> FrameEncoding {
        let list = EBML.children(bytes, of: encodings).filter { $0.id == 0x6240 }
        guard !list.isEmpty else { return .none }
        guard list.count == 1, let encoding = list.first else { return .unsupported }
        var scope: UInt64 = 1
        var result: FrameEncoding = .none
        for field in EBML.children(bytes, of: encoding) {
            switch field.id {
            case 0x5032: scope = EBML.uint(bytes, field)
            case 0x5035: return .unsupported
            case 0x5034:
                var algorithm: UInt64 = 0
                var settings: [UInt8] = []
                for value in EBML.children(bytes, of: field) {
                    if value.id == 0x4254 { algorithm = EBML.uint(bytes, value) }
                    if value.id == 0x4255 { settings = Array(bytes[value.dataStart..<value.dataStart + Int(value.size)]) }
                }
                switch algorithm {
                case 0: result = .zlib
                case 3: result = .strippedHeader(settings)
                default: return .unsupported
                }
            default: break
            }
        }
        return scope & 1 == 0 ? .none : result
    }

    // MARK: - Streams to tracks

    /// A subtitle stream as libavformat lists it.
    struct SubtitleStream: Sendable {
        var streamIndex: Int32
        /// `AVStream.id`: the TrackNumber where libavformat carries it (FFmpegBuild's
        /// patch_ffmpeg_matroska_track_id), 0 where it does not.
        var trackID: Int32 = 0
        var codecName: String
        var language: String?
        /// The statistics libavformat copied onto the stream from the track's tags.
        var frames: Int? = nil
        var bytes: Int64? = nil
    }

    /// The track behind each subtitle stream. The stream's own TrackNumber when libavformat carries
    /// it; otherwise the k-th subtitle stream is the k-th subtitle TrackEntry libavformat makes a
    /// stream of. Either way every pair has to agree on codec, language and, where the file states
    /// them, its frame and byte statistics, which tell apart two tracks a stream count or an order
    /// cannot. A count or any pair that disagrees maps nothing: a wrong track would fill a rendition
    /// with another track's lines.
    func trackNumbers(for streams: [SubtitleStream]) -> [Int32: UInt64] {
        var pairs: [(SubtitleStream, SubtitleTrack)] = []
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
            if let family = Self.codecFamily[track.codecID], family != stream.codecName { return [:] }
            if let a = stream.language?.lowercased(), let b = track.language?.lowercased(),
               a != "und", b != "und", !AetherEngine.languageMatches(a, b) { return [:] }
            let stats = statistics[track.number]
            if let a = stream.frames, let b = stats?.frames, a != b { return [:] }
            if let a = stream.bytes, let b = stats?.bytes, a != b { return [:] }
            out[stream.streamIndex] = track.number
        }
        return out
    }

    /// Matroska codec IDs and the decoder libavformat gives their streams.
    static let codecFamily: [String: String] = [
        "S_HDMV/PGS": "hdmv_pgs_subtitle", "S_TEXT/UTF8": "subrip", "S_TEXT/ASCII": "subrip",
        "S_TEXT/ASS": "ass", "S_ASS": "ass", "S_TEXT/SSA": "ass", "S_SSA": "ass",
        "S_TEXT/WEBVTT": "webvtt", "S_VOBSUB": "dvd_subtitle", "S_DVBSUB": "dvb_subtitle",
    ]

    // MARK: - Blocks

    /// One subtitle frame read off the file.
    struct Frame: Sendable {
        var ticks: Int64
        var durationTicks: Int64?
        /// The frame as libavformat hands it over: header-stripped bytes restored, zlib inflated.
        var payload: [UInt8]
        /// True when only the first bytes were read (`readFrame(..., prefix:)`).
        var isPrefix: Bool
    }

    /// Whether `track` is a WebVTT subtitle track, whose blocks are split before they are a packet.
    func isWebVTT(track: UInt64) -> Bool {
        subtitleTracks.first(where: { $0.number == track }).flatMap { Self.codecFamily[$0.codecID] } == "webvtt"
    }

    /// A WebVTT block as libavformat hands it over (`matroska_parse_webvtt`): the payload is an
    /// identifier line, a settings line and the cue text, each line ended by CR, LF or CRLF; the packet
    /// is the text with its trailing line breaks stripped, and the settings ride as side data. Nil for
    /// a block libavformat would refuse (a missing line, an empty text), which it drops.
    static func webVTTCue(_ payload: [UInt8]) -> (text: [UInt8], settings: String)? {
        var p = 0
        func lineEnd(from start: Int) -> Int? {
            var i = start
            while i < payload.count {
                if payload[i] == 0x0D || payload[i] == 0x0A { return i }
                i += 1
            }
            return nil
        }
        func skipBreak(at end: Int) -> Int {
            if payload[end] == 0x0D, end + 1 < payload.count, payload[end + 1] == 0x0A { return end + 2 }
            return end + 1
        }
        guard let idEnd = lineEnd(from: p) else { return nil }
        p = skipBreak(at: idEnd)
        let settingsStart = p
        guard let settingsEnd = lineEnd(from: p) else { return nil }
        let settings = String(decoding: payload[settingsStart..<settingsEnd], as: UTF8.self)
        p = skipBreak(at: settingsEnd)
        var textEnd = payload.count
        while textEnd > p, payload[textEnd - 1] == 0x0D || payload[textEnd - 1] == 0x0A { textEnd -= 1 }
        guard textEnd > p else { return nil }
        return (Array(payload[p..<textEnd]), settings)
    }

    /// The bytes a block read needs beyond the payload: the element's header plus the cluster size field
    /// whose length is not known without reading the cluster's own header (1 to 8 bytes).
    static let blockHeaderSlack = 48

    /// Reads `block` of `track`. With `prefix`, at most that many payload bytes (enough for a PGS
    /// composition header) instead of the whole frame. Nil when the block is not where the index says.
    func readFrame(_ block: Block, track: UInt64, from source: RandomAccessByteSource,
                   prefix requestedPrefix: Int? = nil) -> Frame? {
        // A compressed frame has no readable prefix: it is read whole and inflated, and the prefix is
        // taken from what it inflates to.
        let compressed = encodingByTrack[track] == .zlib
        let prefix = compressed ? nil : requestedPrefix
        // The block starts at cluster + 4 (the cluster ID) + the size field (1...8) + relative position.
        let earliest = segmentDataStart + block.clusterPosition + 4 + 1 + block.relativePosition
        let want = (prefix ?? 512) + Self.blockHeaderSlack + 8
        guard let window = source.read(at: earliest, count: want), !window.isEmpty else { return nil }
        // The sampled length first; a muxer can still write a few clusters with another one.
        let candidates = clusterSizeFieldLength.map { known in [known] + (1...8).filter { $0 != known } } ?? Array(1...8)
        for sizeFieldLength in candidates {
            let at = sizeFieldLength - 1
            guard at < window.count,
                  let located = Self.locate(window, at: at, track: track) else { continue }
            var payload: [UInt8]
            let payloadEnd = located.payloadStart + located.payloadLength
            let isPrefix: Bool
            if let prefix, located.payloadLength > prefix {
                let end = min(window.count, located.payloadStart + prefix)
                payload = Array(window[located.payloadStart..<end])
                isPrefix = true
            } else if payloadEnd <= window.count {
                payload = Array(window[located.payloadStart..<payloadEnd])
                isPrefix = false
            } else {
                guard let full = source.read(at: earliest + Int64(located.payloadStart), count: located.payloadLength),
                      full.count == located.payloadLength else { return nil }
                payload = full
                isPrefix = false
            }
            if case .strippedHeader(let stripped) = encodingByTrack[track] ?? .none { payload = stripped + payload }
            var prefixed = isPrefix
            if compressed {
                guard let inflated = ZlibBlock.inflate(payload) else { return nil }
                payload = inflated
                if let requestedPrefix, payload.count > requestedPrefix {
                    payload = Array(payload.prefix(requestedPrefix))
                    prefixed = true
                }
            }
            return Frame(ticks: block.ticks, durationTicks: located.durationTicks ?? block.durationTicks,
                         payload: payload, isPrefix: prefixed)
        }
        return nil
    }

    /// A SimpleBlock or BlockGroup of `track` starting at `at`: where its frame lies and its duration.
    /// Checked down to the block's track number and lacing, so a wrong guess of the cluster's size field
    /// cannot pass for a block.
    static func locate(_ bytes: [UInt8], at: Int, track: UInt64)
        -> (payloadStart: Int, payloadLength: Int, durationTicks: Int64?)? {
        guard let element = EBML.element(bytes, at: at), !element.unknownSize else { return nil }
        let end = element.dataStart + Int(element.size)
        func block(_ start: Int, _ length: Int) -> (Int, Int)? {
            guard let number = EBML.vint(bytes, at: start), number.value == track else { return nil }
            let flagsAt = start + number.length + 2
            guard flagsAt < bytes.count, length > number.length + 3 else { return nil }
            guard bytes[flagsAt] & 0x06 == 0 else { return nil }   // laced: never a subtitle frame
            let payloadStart = flagsAt + 1
            return (payloadStart, length - (payloadStart - start))
        }
        switch element.id {
        case 0xA3:
            guard let (start, length) = block(element.dataStart, Int(element.size)) else { return nil }
            return (start, length, nil)
        case 0xA0:
            var found: (Int, Int)?
            var duration: Int64?
            var offset = element.dataStart
            while offset < min(end, bytes.count), let child = EBML.element(bytes, at: offset), !child.unknownSize {
                if child.id == 0xA1 { found = block(child.dataStart, Int(child.size)) }
                if child.id == 0x9B, child.dataStart + Int(child.size) <= bytes.count {
                    duration = Int64(EBML.uint(bytes, child))
                }
                offset = child.dataStart + Int(child.size)
            }
            guard let (start, length) = found else { return nil }
            return (start, length, duration)
        default:
            return nil
        }
    }
}

/// Random access to a source's bytes, for reading a container's own structures.
protocol RandomAccessByteSource: AnyObject {
    /// Up to `count` bytes at `offset`; fewer at the end of the source, nil on an error.
    func read(at offset: Int64, count: Int) -> [UInt8]?
}

/// `RandomAccessByteSource` over an `IOReader` (an HTTP range reader, a file, a host's own reader).
///
/// A `RangeReadableIOReader` is asked for exactly the range, without the cursor or its lock, so any
/// number of callers can share one source. Any other reader goes through `seek` and `read`, one at a
/// time.
///
/// `@unchecked Sendable`: a range reader is read without shared state, and anything else only under
/// the lock, so the source can be handed to the parse that `SourceIndexRegistry` runs.
final class IOReaderByteSource: RandomAccessByteSource, @unchecked Sendable {
    private let reader: IOReader
    private let closesReader: Bool
    private let lock = NSLock()

    convenience init(_ reader: IOReader) { self.init(reader, closesReader: true) }

    /// `closesReader: false` for a source over a reader somebody else owns and closes.
    init(_ reader: IOReader, closesReader: Bool) {
        self.reader = reader
        self.closesReader = closesReader
    }

    /// Whether callers can share this source instead of each opening their own.
    var isConcurrent: Bool { reader is RangeReadableIOReader }

    func read(at offset: Int64, count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        if let ranged = reader as? RangeReadableIOReader {
            return ranged.readRange(at: offset, count: count).map { [UInt8]($0) }
        }
        lock.lock(); defer { lock.unlock() }
        guard reader.seek(offset: offset, whence: SEEK_SET) == offset else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let got = bytes.withUnsafeMutableBufferPointer { buffer in
                reader.read(buffer.baseAddress! + filled, size: Int32(count - filled))
            }
            if got < 0 { return nil }
            if got == 0 { break }
            filled += Int(got)
        }
        return Array(bytes.prefix(filled))
    }

    func close() { if closesReader { reader.close() } }
}

/// The few EBML primitives the index needs.
enum EBML {
    struct Element {
        var id: UInt32
        var dataStart: Int
        var size: UInt64
        var unknownSize: Bool
    }

    /// A variable-length integer at `at`, marker bit removed.
    static func vint(_ bytes: [UInt8], at: Int) -> (value: UInt64, length: Int)? {
        guard at < bytes.count else { return nil }
        let first = bytes[at]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard at + length <= bytes.count else { return nil }
        var value = UInt64(first & (0xFF >> length))
        for k in 1..<length { value = (value << 8) | UInt64(bytes[at + k]) }
        return (value, length)
    }

    static func element(_ bytes: [UInt8], at: Int) -> Element? {
        guard at < bytes.count else { return nil }
        let first = bytes[at]
        guard first != 0 else { return nil }
        let idLength = first.leadingZeroBitCount + 1
        guard idLength <= 4, at + idLength <= bytes.count else { return nil }
        var id: UInt32 = 0
        for k in 0..<idLength { id = (id << 8) | UInt32(bytes[at + k]) }
        guard let size = vint(bytes, at: at + idLength) else { return nil }
        let allOnes = size.length < 8 ? (UInt64(1) << UInt64(7 * size.length)) - 1 : UInt64.max >> 8
        return Element(id: id, dataStart: at + idLength + size.length, size: size.value,
                       unknownSize: size.value == allOnes)
    }

    /// The children of `parent` that lie inside `bytes`.
    static func children(_ bytes: [UInt8], of parent: Element) -> [Element] {
        var out: [Element] = []
        let end = min(bytes.count, parent.dataStart + Int(min(parent.size, UInt64(Int.max / 2))))
        var offset = parent.dataStart
        while offset < end, let child = element(bytes, at: offset), !child.unknownSize {
            out.append(child)
            offset = child.dataStart + Int(child.size)
        }
        return out
    }

    static func string(_ bytes: [UInt8], _ element: Element) -> String {
        let end = min(bytes.count, element.dataStart + Int(element.size))
        return String(decoding: bytes[element.dataStart..<end].prefix { $0 != 0 }, as: UTF8.self)
    }

    static func uint(_ bytes: [UInt8], _ element: Element) -> UInt64 {
        var value: UInt64 = 0
        let end = min(bytes.count, element.dataStart + Int(min(element.size, 8)))
        for k in element.dataStart..<end { value = (value << 8) | UInt64(bytes[k]) }
        return value
    }
}

/// The part of a PGS display set the index needs without decoding it: its Presentation Composition.
struct PGSCompositionHeader: Equatable {
    /// 0x00 normal, 0x40 acquisition point, 0x80 epoch start.
    var state: UInt8
    var objectCount: Int
    /// Any composition object carries the forced flag (0x40): the line shows with subtitles off.
    var isForced: Bool

    /// A display set that does not depend on earlier ones: decoding can start here.
    var isSelfContained: Bool { state & 0xC0 != 0 }

    /// Parses the composition segment a display set starts with. `payload` may be zlib-wrapped, in
    /// which case only its first bytes are inflated.
    static func parse(_ payload: [UInt8]) -> PGSCompositionHeader? {
        var bytes = payload
        if bytes.count > 2, bytes[0] == 0x78, [0x01, 0x5E, 0x9C, 0xDA].contains(bytes[1]) {
            guard let inflated = inflatePrefix(Array(bytes.dropFirst(2)), want: 256) else { return nil }
            bytes = inflated
        }
        if bytes.count > 10, bytes[0] == 0x50, bytes[1] == 0x47 { bytes.removeFirst(10) }   // "PG" stream header
        guard bytes.count >= 3 + 11, bytes[0] == 0x16 else { return nil }
        let pcs = 3
        let state = bytes[pcs + 7]
        let count = Int(bytes[pcs + 10])
        var forced = false
        var object = pcs + 11
        for _ in 0..<count {
            guard object + 8 <= bytes.count else { break }
            let flags = bytes[object + 3]
            if flags & 0x40 != 0 { forced = true }
            object += 8 + (flags & 0x80 != 0 ? 8 : 0)
        }
        return PGSCompositionHeader(state: state, objectCount: count, isForced: forced)
    }

    /// The first bytes of a raw deflate stream, from as much of it as is at hand.
    static func inflatePrefix(_ deflated: [UInt8], want: Int) -> [UInt8]? {
        guard !deflated.isEmpty else { return nil }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(stream) }
        var out = [UInt8](repeating: 0, count: want)
        let produced: Int = deflated.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { output in
                stream.pointee.src_ptr = input.baseAddress!
                stream.pointee.src_size = input.count
                stream.pointee.dst_ptr = output.baseAddress!
                stream.pointee.dst_size = want
                _ = compression_stream_process(stream, 0)
                return want - stream.pointee.dst_size
            }
        }
        return produced > 0 ? Array(out.prefix(produced)) : nil
    }
}
