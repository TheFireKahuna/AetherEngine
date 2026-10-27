import Foundation
import Testing
@testable import AetherEngine

/// The audio tap on a session whose loopback carries APAC (TrueHD Atmos or DTS:X through the spatial bridge).
/// libavcodec has no APAC decoder, so the tap decodes the track with AudioToolbox from the cookie its init carries,
/// and hands the bed to the same downmix and clock as every other codec.
@Suite("The audio tap on an APAC loopback")
struct AudioTapObjectAudioTests {

    private func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { be32(8 + payload.count) + Array(type.utf8) + payload }
    private func full(_ type: String, version: UInt8 = 0, flags: Int = 0, _ payload: [UInt8]) -> [UInt8] {
        box(type, [version, UInt8(flags >> 16 & 0xFF), UInt8(flags >> 8 & 0xFF), UInt8(flags & 0xFF)] + payload)
    }
    private var matrix: [UInt8] {
        be32(0x0001_0000) + be32(0) + be32(0) + be32(0) + be32(0x0001_0000) + be32(0) + be32(0) + be32(0) + be32(0x4000_0000)
    }

    /// An fMP4 init with one sound track at 48 kHz whose sample entry is `entry`, as the loopback serves it.
    private func initSegment(entry: Data) -> Data {
        let mvhd = full("mvhd", be32(0) + be32(0) + be32(1000) + be32(0) + be32(0x0001_0000) + be16(0x0100)
            + [UInt8](repeating: 0, count: 10) + matrix + [UInt8](repeating: 0, count: 24) + be32(2))
        let tkhd = full("tkhd", flags: 7, be32(0) + be32(0) + be32(1) + be32(0) + be32(0) + [UInt8](repeating: 0, count: 8)
            + be16(0) + be16(0) + be16(0x0100) + be16(0) + matrix + be32(0) + be32(0))
        let mdhd = full("mdhd", be32(0) + be32(0) + be32(48_000) + be32(0) + be16(0x55C4) + be16(0))
        let hdlr = full("hdlr", be32(0) + Array("soun".utf8) + [UInt8](repeating: 0, count: 12) + [0])
        let dinf = box("dinf", full("dref", be32(1) + full("url ", flags: 1, [])))
        let stbl = box("stbl", full("stsd", be32(1) + [UInt8](entry)) + full("stts", be32(0)) + full("stsc", be32(0))
            + full("stsz", be32(0) + be32(0)) + full("stco", be32(0)))
        let minf = box("minf", full("smhd", be16(0) + be16(0)) + dinf + stbl)
        let trak = box("trak", tkhd + box("mdia", mdhd + hdlr + minf))
        let mvex = box("mvex", full("trex", be32(1) + be32(1) + be32(1024) + be32(0) + be32(0)))
        return Data(box("ftyp", Array("iso5".utf8) + be32(1) + Array("iso5iso6mp41".utf8)) + box("moov", mvhd + trak + mvex))
    }

    /// One fragment of `packets`, 1024 frames each, the first at `baseTime` (48 kHz ticks).
    private func fragment(_ packets: [Data], baseTime: Int) -> Data {
        func moof(dataOffset: Int) -> [UInt8] {
            let trun = full("trun", flags: 0x000301, be32(packets.count) + be32(dataOffset)
                + packets.flatMap { be32(1024) + be32($0.count) })
            let traf = box("traf", full("tfhd", flags: 0x020000, be32(1))
                + full("tfdt", version: 1, be32(0) + be32(baseTime)) + trun)
            return box("moof", full("mfhd", be32(1)) + traf)
        }
        let size = moof(dataOffset: 0).count
        let payload = packets.reduce(into: [UInt8]()) { $0 += [UInt8]($1) }
        return Data(moof(dataOffset: size + 8) + box("mdat", payload))
    }

    @Test("the init's apac entry gives back the cookie it was written with; any other entry gives none")
    func cookieFromInit() throws {
        let cookie = Data(box("dapa", [UInt8](repeating: 7, count: 40)))
        let apac = initSegment(entry: APACSampleEntry.sampleEntry(magicCookie: cookie, sampleRate: 48_000))
        #expect(APACSampleEntry.magicCookie(inInit: apac) == cookie)
        let alac = initSegment(entry: Data(box("alac", [UInt8](repeating: 0, count: 28) + box("alac", [UInt8](repeating: 1, count: 28)))))
        #expect(APACSampleEntry.magicCookie(inInit: alac) == nil)
    }

    @Test("a loopback APAC segment is tapped: the bed's tone comes back in mono, timed from the fragment")
    func apacSegmentIsTapped() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let layout = SpatialSpeakerLayout.l714
        let encoder = try APACEncoder(layout: layout, bitRate: 3_840_000)
        let frames = 48_000
        let planes = (0..<layout.channelCount).map { c -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            // A 440 Hz tone on the centre, silence elsewhere.
            for i in 0..<frames { p[i] = layout.speakers[c] == .center ? 0.5 * sinf(Float(i) * 2 * .pi * 440 / 48_000) : 0 }
            return p
        }
        defer { planes.forEach { $0.deallocate() } }
        var packets = try encoder.encode(planes: planes.map { UnsafePointer($0) }, frameCount: frames)
        packets += try encoder.flush()
        let initData = initSegment(entry: APACSampleEntry.sampleEntry(magicCookie: encoder.magicCookie, sampleRate: 48_000))
        let baseTime = 10 * 48_000
        let segment = fragment(packets.map(\.data), baseTime: baseTime)

        let chunks = AudioTapSegmentDecoder().decode(initData: initData, segment: segment)
        let samples = chunks.reduce(0) { $0 + Int($1.buffer.frameLength) }
        #expect(samples == packets.count * 1024, "every packet's frames, none held back")
        #expect(chunks.first.map { abs($0.ptsSeconds - 10) < 0.001 } == true, "timed from the fragment: \(chunks.first?.ptsSeconds ?? -1)")
        var peak: Float = 0
        for chunk in chunks {
            let data = chunk.buffer.floatChannelData![0]
            for i in 0..<Int(chunk.buffer.frameLength) { peak = max(peak, abs(data[i])) }
        }
        #expect(peak > 0.1, "the centre's tone survives the downmix: \(peak)")
        // Chunks abut: each starts where the last ended.
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            #expect(abs(a.ptsSeconds + Double(a.buffer.frameLength) / 48_000 - b.ptsSeconds) < 1e-6)
        }
    }
}
