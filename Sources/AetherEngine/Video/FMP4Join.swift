import Foundation

/// A demuxed session's video and audio renditions joined into one file per segment, for the one playlist that plays
/// without a master (`HLSOutputShape`, docs/demuxed-audio.md): what AVPlayer is handed where it refuses the master.
/// The layout is the one a muxed segment has, Apple's segmenter's: one `moof` with a `traf` per track over one
/// `mdat`. Only boxes are rearranged; every sample keeps its bytes, decode time, duration and composition offset, and
/// each `traf` its own `tfdt` on its track's timescale, so the joined file is a pure function of the two cut files.
enum FMP4Join {
    /// The audio track's id in the joined file, after the video's 1.
    static let audioTrackID: UInt32 = 2

    // MARK: - Init

    /// The video init's `ftyp` and `moov`, with the audio init's `trak` and `trex` added as track 2.
    static func initSegment(video: Data, audio: Data) -> Data? {
        let v = [UInt8](video), a = [UInt8](audio)
        let vTop = boxes(v, 0..<v.count), aTop = boxes(a, 0..<a.count)
        guard let vMoov = vTop.first(where: { $0.type == "moov" }),
              let aMoov = aTop.first(where: { $0.type == "moov" }) else { return nil }
        let aChildren = boxes(a, aMoov.body)
        guard let aTrak = aChildren.first(where: { $0.type == "trak" }),
              let aMvex = aChildren.first(where: { $0.type == "mvex" }),
              let aTrex = boxes(a, aMvex.body).first(where: { $0.type == "trex" }) else { return nil }
        var audioTrak = Array(a[aTrak.range])
        guard renumberTrack(in: &audioTrak) else { return nil }
        var audioTrex = Array(a[aTrex.range])
        // trex: header (8), version/flags (4), track_ID.
        write32(&audioTrex, at: 12, audioTrackID)

        var moovBody: [UInt8] = []
        for child in boxes(v, vMoov.body) {
            switch child.type {
            case "mvhd":
                var mvhd = Array(v[child.range])
                // next_track_ID is the box's last field.
                write32(&mvhd, at: mvhd.count - 4, audioTrackID + 1)
                moovBody += mvhd
            case "mvex":
                moovBody += box("mvex", Array(v[child.body]) + audioTrex)
            case "trak":
                moovBody += Array(v[child.range])
                if !audioTrak.isEmpty {
                    moovBody += audioTrak
                    audioTrak = []
                }
            default:
                moovBody += Array(v[child.range])
            }
        }
        var out: [UInt8] = []
        for top in vTop {
            out += top.type == "moov" ? box("moov", moovBody) : Array(v[top.range])
        }
        return Data(out)
    }

    /// The media timescale of an init's first track (`mdhd`).
    static func timescale(ofInit data: Data) -> UInt32? {
        let d = [UInt8](data)
        guard let moov = boxes(d, 0..<d.count).first(where: { $0.type == "moov" }),
              let trak = boxes(d, moov.body).first(where: { $0.type == "trak" }),
              let mdia = boxes(d, trak.body).first(where: { $0.type == "mdia" }),
              let mdhd = boxes(d, mdia.body).first(where: { $0.type == "mdhd" }) else { return nil }
        let at = mdhd.body.lowerBound
        return read32(d, at + (d[at] == 1 ? 20 : 12))
    }

    /// The audio `trak` as track 2: `tkhd`'s track_ID.
    private static func renumberTrack(in trak: inout [UInt8]) -> Bool {
        guard let tkhd = boxes(trak, 8..<trak.count).first(where: { $0.type == "tkhd" }) else { return false }
        let version = trak[tkhd.body.lowerBound]
        write32(&trak, at: tkhd.body.lowerBound + (version == 1 ? 20 : 12), audioTrackID)
        return true
    }

    // MARK: - Segments

    /// The video segment's fragments, each carrying the audio fragments that start in its span, as one `moof` and one
    /// `mdat`. Boxes before the first fragment (the in-band clock's `emsg`) stay in front. An audio fragment with no
    /// sample adds nothing. nil when either file is not fragments this join reads.
    static func mediaSegment(video: Data, audio: Data, videoTimescale: UInt32, audioTimescale: UInt32) -> Data? {
        let v = [UInt8](video), a = [UInt8](audio)
        guard videoTimescale > 0, audioTimescale > 0,
              let vParts = fragments(v), let aParts = fragments(a) else { return nil }
        guard !vParts.fragments.isEmpty else { return nil }
        // Each audio fragment joins the last video fragment starting at or before it.
        let vStarts = vParts.fragments.map { Double($0.decodeTime) / Double(videoTimescale) }
        var audioFor = Array(repeating: [Fragment](), count: vParts.fragments.count)
        for fragment in aParts.fragments where fragment.hasSamples {
            let start = Double(fragment.decodeTime) / Double(audioTimescale)
            let slot = vStarts.lastIndex { $0 <= start } ?? 0
            audioFor[slot].append(fragment)
        }
        var out = vParts.prefix
        for (i, video) in vParts.fragments.enumerated() {
            out += merged(video: video, audio: audioFor[i])
        }
        return Data(out)
    }

    /// One `moof` (the video's `mfhd`, its `traf`s, then the audio's as track 2) over one `mdat` (the video's samples,
    /// then the audio's), every run's data offset recomputed for where its samples now sit.
    private static func merged(video: Fragment, audio: [Fragment]) -> [UInt8] {
        let parts = [video] + audio
        // The new moof's size first: a traf keeps its size, only its fields change.
        let mfhd = video.mfhd
        let trafs = parts.flatMap { $0.trafs }
        let moofSize = 8 + mfhd.count + trafs.reduce(0) { $0 + $1.count }
        let payloadTotal = parts.reduce(0) { $0 + $1.payload.count }
        let mdatHeader = payloadTotal + 8 > Int(UInt32.max) ? 16 : 8
        var moofBody = mfhd
        var payloadStart = moofSize + mdatHeader
        for (n, part) in parts.enumerated() {
            for var traf in part.trafs {
                // Data offsets are from the moof's start (default-base-is-moof): a sample sat at
                // `old - oldPayloadStart` into its old mdat's payload, and its payload now starts at `payloadStart`.
                shiftRunOffsets(in: &traf, by: payloadStart - part.payloadStart)
                if n > 0 { setTrackID(in: &traf, audioTrackID) }
                moofBody += traf
            }
            payloadStart += part.payload.count
        }
        var out = box("moof", moofBody)
        if mdatHeader == 16 {
            out += [0, 0, 0, 1] + Array("mdat".utf8) + be64(UInt64(payloadTotal + 16))
        } else {
            out += be32(UInt32(payloadTotal + 8)) + Array("mdat".utf8)
        }
        for part in parts { out += part.payload }
        return out
    }

    private struct Fragment {
        let mfhd: [UInt8]
        let trafs: [[UInt8]]
        let payload: [UInt8]
        /// Where the payload started, from its own moof's start: the base its runs' data offsets count from.
        let payloadStart: Int
        let decodeTime: UInt64
        let hasSamples: Bool
    }

    /// The boxes before the first `moof`, and each `moof` with the `mdat` after it.
    private static func fragments(_ d: [UInt8]) -> (prefix: [UInt8], fragments: [Fragment])? {
        let top = boxes(d, 0..<d.count)
        var prefix: [UInt8] = []
        var out: [Fragment] = []
        var i = 0
        while i < top.count {
            let b = top[i]
            guard b.type == "moof" else {
                if out.isEmpty { prefix += Array(d[b.range]) }
                i += 1
                continue
            }
            guard i + 1 < top.count, top[i + 1].type == "mdat" else { return nil }
            let mdat = top[i + 1]
            let children = boxes(d, b.body)
            guard let mfhd = children.first(where: { $0.type == "mfhd" }) else { return nil }
            let trafs = children.filter { $0.type == "traf" }
            guard !trafs.isEmpty else { return nil }
            var decodeTime: UInt64?
            var hasSamples = false
            for traf in trafs {
                for child in boxes(d, traf.body) {
                    if child.type == "tfdt", decodeTime == nil {
                        let at = child.body.lowerBound
                        decodeTime = d[at] == 1 ? read64(d, at + 4) : UInt64(read32(d, at + 4))
                    }
                    if child.type == "trun", read32(d, child.body.lowerBound + 4) > 0 { hasSamples = true }
                }
            }
            guard let decodeTime else { return nil }
            out.append(Fragment(mfhd: Array(d[mfhd.range]), trafs: trafs.map { Array(d[$0.range]) },
                                payload: Array(d[mdat.body]), payloadStart: mdat.body.lowerBound - b.range.lowerBound,
                                decodeTime: decodeTime, hasSamples: hasSamples))
            i += 2
        }
        return (prefix, out)
    }

    /// Moves every run's data offset in a `traf` by `delta`.
    private static func shiftRunOffsets(in traf: inout [UInt8], by delta: Int) {
        for child in boxes(traf, 8..<traf.count) where child.type == "trun" {
            let at = child.body.lowerBound
            // trun flags 0x1: a data offset follows the sample count.
            guard read32(traf, at) & 0x1 != 0 else { continue }
            let offset = Int(Int32(bitPattern: read32(traf, at + 8)))
            write32(&traf, at: at + 8, UInt32(bitPattern: Int32(offset + delta)))
        }
    }

    private static func setTrackID(in traf: inout [UInt8], _ id: UInt32) {
        guard let tfhd = boxes(traf, 8..<traf.count).first(where: { $0.type == "tfhd" }) else { return }
        write32(&traf, at: tfhd.body.lowerBound + 4, id)
    }

    // MARK: - Boxes

    private struct Box {
        let type: String
        let range: Range<Int>
        let body: Range<Int>
    }

    private static func boxes(_ d: [UInt8], _ range: Range<Int>) -> [Box] {
        var out: [Box] = []
        var at = range.lowerBound
        while at + 8 <= range.upperBound {
            var size = Int(read32(d, at))
            var header = 8
            if size == 1, at + 16 <= range.upperBound {
                size = Int(read64(d, at + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - at
            }
            guard size >= header, at + size <= range.upperBound else { break }
            out.append(Box(type: String(decoding: d[at + 4..<at + 8], as: UTF8.self),
                           range: at..<at + size, body: at + header..<at + size))
            at += size
        }
        return out
    }

    private static func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        be32(UInt32(8 + body.count)) + Array(type.utf8) + body
    }

    private static func read32(_ d: [UInt8], _ at: Int) -> UInt32 {
        d[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func read64(_ d: [UInt8], _ at: Int) -> UInt64 {
        d[at..<at + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func write32(_ d: inout [UInt8], at: Int, _ value: UInt32) {
        for i in 0..<4 { d[at + i] = UInt8(truncatingIfNeeded: value >> (24 - 8 * i)) }
    }

    private static func be32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * $0)) } }
    private static func be64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (56 - 8 * $0)) } }
}
