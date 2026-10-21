import Foundation
import Testing
@testable import AetherEngine

/// The APAC track's fragments carry the `prol` pre-roll group (roll distance 1, every sample), as Apple's HLS
/// writer writes it, added to the moof movenc made with every size and data offset it moves corrected.
@Suite("APAC pre-roll sample group")
struct APACPreRollGroupTests {

    private func u32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private func box(_ type: String, _ body: [UInt8]) -> [UInt8] { u32(UInt32(8 + body.count)) + Array(type.utf8) + body }
    private func be32(_ d: [UInt8], _ at: Int) -> UInt32 { UInt32(d[at]) << 24 | UInt32(d[at+1]) << 16 | UInt32(d[at+2]) << 8 | UInt32(d[at+3]) }

    /// movenc's shape: default-base-is-moof, each traf's trun with a data offset into the mdat after the moof.
    private func traf(track: UInt32, samples: UInt32, dataOffset: UInt32) -> [UInt8] {
        let tfhd = box("tfhd", [0, 0x02, 0x00, 0x38] + u32(track) + u32(1024) + u32(100) + u32(0x0200_0000))
        let tfdt = box("tfdt", [1, 0, 0, 0] + [0, 0, 0, 0] + u32(48_000))
        let trun = box("trun", [0, 0, 0x02, 0x01] + u32(samples) + u32(dataOffset) + (0..<samples).flatMap { _ in u32(100) })
        return box("traf", tfhd + tfdt + trun)
    }

    private func moof(videoOffset: UInt32, audioOffset: UInt32) -> [UInt8] {
        box("moof", box("mfhd", [0, 0, 0, 0] + u32(7)) + traf(track: 1, samples: 2, dataOffset: videoOffset)
            + traf(track: 2, samples: 3, dataOffset: audioOffset))
    }

    @Test("the group lands in the APAC traf after tfdt, and every size and data offset moves with it")
    func rewritesTheAudioTraf() throws {
        let original = moof(videoOffset: 300, audioOffset: 500)
        let out = [UInt8](try #require(APACPreRollGroup.addingPreRoll(toMoof: Data(original), trackID: 2)))
        let n = APACPreRollGroup.insertedBytes
        #expect(out.count == original.count + n)
        #expect(be32(out, 0) == UInt32(out.count))
        let trafs = APACPreRollGroup.children(out, 8, out.count).filter { $0.type == "traf" }
        #expect(trafs.count == 2)
        let audio = APACPreRollGroup.children(out, trafs[1].body, trafs[1].end)
        #expect(audio.map(\.type) == ["tfhd", "tfdt", "sgpd", "sbgp", "trun"])
        // sgpd v1 'prol', default_length 2, one entry: roll distance 1.
        let sgpd = Array(out[audio[2].start..<audio[2].end])
        #expect(sgpd == u32(26) + Array("sgpd".utf8) + [1, 0, 0, 0] + Array("prol".utf8) + u32(2) + u32(1) + [0, 1])
        // sbgp: all three samples in the fragment's own entry 1.
        let sbgp = Array(out[audio[3].start..<audio[3].end])
        #expect(sbgp == u32(28) + Array("sbgp".utf8) + [0, 0, 0, 0] + Array("prol".utf8) + u32(1) + u32(3) + u32(0x0001_0001))
        // Both trafs' runs point n bytes further, where their data now is.
        let video = APACPreRollGroup.children(out, trafs[0].body, trafs[0].end)
        let videoTrun = try #require(video.first { $0.type == "trun" })
        #expect(be32(out, videoTrun.body + 8) == 300 + UInt32(n))
        #expect(be32(out, audio[4].body + 8) == 500 + UInt32(n))
        #expect(be32(out, trafs[0].start) == UInt32(trafs[0].end - trafs[0].start))
        #expect(be32(out, trafs[1].start) == UInt32(trafs[1].end - trafs[1].start))
    }

    @Test("a fragment already grouped, without the track, or with an absolute base offset is left alone")
    func leavesOtherFragmentsAlone() throws {
        let once = try #require(APACPreRollGroup.addingPreRoll(toMoof: Data(moof(videoOffset: 300, audioOffset: 500)), trackID: 2))
        #expect(APACPreRollGroup.addingPreRoll(toMoof: once, trackID: 2) == nil)
        #expect(APACPreRollGroup.addingPreRoll(toMoof: Data(moof(videoOffset: 300, audioOffset: 500)), trackID: 9) == nil)
        let absolute = box("moof", box("traf", box("tfhd", [0, 0, 0, 0x01] + u32(2) + [0, 0, 0, 0] + u32(0)) + box("trun", [0, 0, 0, 1] + u32(1) + u32(8))))
        #expect(APACPreRollGroup.addingPreRoll(toMoof: Data(absolute), trackID: 2) == nil)
    }

    @Test("the APAC track is found in the init by its sample entry")
    func findsTheAPACTrack() {
        func trak(_ id: UInt32, entry: String) -> [UInt8] {
            let tkhd = box("tkhd", [0, 0, 0, 3] + u32(0) + u32(0) + u32(id) + [UInt8](repeating: 0, count: 68))
            let stsd = box("stsd", [0, 0, 0, 0] + u32(1) + box(entry, [UInt8](repeating: 0, count: 28)))
            return box("trak", tkhd + box("mdia", box("minf", box("stbl", stsd))))
        }
        let initBytes = box("ftyp", Array("iso6".utf8) + u32(0)) + box("moov", trak(1, entry: "avc1") + trak(2, entry: "apac"))
        #expect(APACPreRollGroup.apacTrackID(inInit: Data(initBytes)) == 2)
        let noAPAC = box("moov", trak(1, entry: "avc1") + trak(2, entry: "fLaC"))
        #expect(APACPreRollGroup.apacTrackID(inInit: Data(noAPAC)) == nil)
    }
}
