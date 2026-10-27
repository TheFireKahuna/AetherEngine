import Foundation
import Testing
@testable import AetherEngine

/// The APAC track's fragments carry the `prol` pre-roll group (roll distance 1) on the samples that need the
/// packet before, as Apple's HLS writer writes it, and leave the sync samples (Audio Sync Packets) out; added
/// to the moof movenc made with every size and data offset it moves corrected.
@Suite("APAC pre-roll sample group")
struct APACPreRollGroupTests {

    private func u32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private func box(_ type: String, _ body: [UInt8]) -> [UInt8] { u32(UInt32(8 + body.count)) + Array(type.utf8) + body }
    private func be32(_ d: [UInt8], _ at: Int) -> UInt32 { UInt32(d[at]) << 24 | UInt32(d[at+1]) << 16 | UInt32(d[at+2]) << 8 | UInt32(d[at+3]) }

    /// movenc's sample flags: a sync sample depends on nothing; any other depends and is not sync.
    private let syncFlags: UInt32 = 0x0200_0000
    private let otherFlags: UInt32 = 0x0101_0000

    /// movenc's shape: default-base-is-moof, defaults in tfhd (duration, size, the second sample's flags),
    /// the first sample's flags in trun where they differ, and each trun with a data offset into the mdat.
    private func traf(track: UInt32, samples: UInt32, dataOffset: UInt32, defaultFlags: UInt32? = 0x0101_0000,
                      firstFlags: UInt32? = 0x0200_0000, perSample: [UInt32]? = nil) -> [UInt8] {
        let tfhd = defaultFlags.map { box("tfhd", [0, 0x02, 0x00, 0x38] + u32(track) + u32(1024) + u32(100) + u32($0)) }
            ?? box("tfhd", [0, 0x02, 0x00, 0x18] + u32(track) + u32(1024) + u32(100))
        let tfdt = box("tfdt", [1, 0, 0, 0] + [0, 0, 0, 0] + u32(48_000))
        let trun: [UInt8]
        if let perSample {
            trun = box("trun", [0, 0, 0x06, 0x01] + u32(UInt32(perSample.count)) + u32(dataOffset)
                       + perSample.flatMap { u32(100) + u32($0) })
        } else if let firstFlags {
            trun = box("trun", [0, 0, 0x02, 0x05] + u32(samples) + u32(dataOffset) + u32(firstFlags)
                       + (0..<samples).flatMap { _ in u32(100) })
        } else {
            trun = box("trun", [0, 0, 0x02, 0x01] + u32(samples) + u32(dataOffset) + (0..<samples).flatMap { _ in u32(100) })
        }
        return box("traf", tfhd + tfdt + trun)
    }

    private func moof(videoOffset: UInt32, audioOffset: UInt32, audio: [UInt8]? = nil) -> [UInt8] {
        box("moof", box("mfhd", [0, 0, 0, 0] + u32(7))
            + traf(track: 1, samples: 2, dataOffset: videoOffset, defaultFlags: syncFlags, firstFlags: nil)
            + (audio ?? traf(track: 2, samples: 3, dataOffset: audioOffset)))
    }

    private func sbgp(_ out: [UInt8], track index: Int) throws -> [UInt8] {
        let trafs = APACPreRollGroup.children(out, 8, out.count).filter { $0.type == "traf" }
        let group = try #require(APACPreRollGroup.children(out, trafs[index].body, trafs[index].end).first { $0.type == "sbgp" })
        return Array(out[group.start..<group.end])
    }

    @Test("the group lands in the APAC traf after tfdt, on the samples after the sync one, and every size and data offset moves")
    func rewritesTheAudioTraf() throws {
        let original = moof(videoOffset: 300, audioOffset: 500)
        let out = [UInt8](try #require(APACPreRollGroup.addingPreRoll(toMoof: Data(original), trackID: 2)))
        let n = APACPreRollGroup.insertedBytes(runs: 2)
        #expect(out.count == original.count + n)
        #expect(be32(out, 0) == UInt32(out.count))
        let trafs = APACPreRollGroup.children(out, 8, out.count).filter { $0.type == "traf" }
        #expect(trafs.count == 2)
        let audio = APACPreRollGroup.children(out, trafs[1].body, trafs[1].end)
        #expect(audio.map(\.type) == ["tfhd", "tfdt", "sgpd", "sbgp", "trun"])
        // sgpd v1 'prol', default_length 2, one entry: roll distance 1.
        let sgpd = Array(out[audio[2].start..<audio[2].end])
        #expect(sgpd == u32(26) + Array("sgpd".utf8) + [1, 0, 0, 0] + Array("prol".utf8) + u32(2) + u32(1) + [0, 1])
        // sbgp: the sync sample in no group, the two after it in the fragment's own entry 1.
        #expect(try sbgp(out, track: 1) == u32(36) + Array("sbgp".utf8) + [0, 0, 0, 0] + Array("prol".utf8)
                + u32(2) + u32(1) + u32(0) + u32(2) + u32(0x0001_0001))
        // Both trafs' runs point n bytes further, where their data now is.
        let video = APACPreRollGroup.children(out, trafs[0].body, trafs[0].end)
        let videoTrun = try #require(video.first { $0.type == "trun" })
        #expect(be32(out, videoTrun.body + 8) == 300 + UInt32(n))
        #expect(be32(out, audio[4].body + 8) == 500 + UInt32(n))
        #expect(be32(out, trafs[0].start) == UInt32(trafs[0].end - trafs[0].start))
        #expect(be32(out, trafs[1].start) == UInt32(trafs[1].end - trafs[1].start))
    }

    @Test("per-sample flags: each sync sample out of the group, each other one in it")
    func perSampleFlags() throws {
        let audio = traf(track: 2, samples: 0, dataOffset: 500,
                         perSample: [syncFlags, otherFlags, otherFlags, syncFlags, otherFlags])
        let out = [UInt8](try #require(APACPreRollGroup.addingPreRoll(toMoof: Data(moof(videoOffset: 300, audioOffset: 500, audio: audio)),
                                                                       trackID: 2)))
        #expect(try sbgp(out, track: 1) == u32(52) + Array("sbgp".utf8) + [0, 0, 0, 0] + Array("prol".utf8) + u32(4)
                + u32(1) + u32(0) + u32(2) + u32(0x0001_0001) + u32(1) + u32(0) + u32(1) + u32(0x0001_0001))
    }

    @Test("a fragment of sync samples only, already grouped, without the track, without default flags or with an absolute base offset is left alone")
    func leavesOtherFragmentsAlone() throws {
        let allSync = traf(track: 2, samples: 3, dataOffset: 500, defaultFlags: syncFlags, firstFlags: nil)
        #expect(APACPreRollGroup.addingPreRoll(toMoof: Data(moof(videoOffset: 300, audioOffset: 500, audio: allSync)), trackID: 2) == nil)
        let once = try #require(APACPreRollGroup.addingPreRoll(toMoof: Data(moof(videoOffset: 300, audioOffset: 500)), trackID: 2))
        #expect(APACPreRollGroup.addingPreRoll(toMoof: once, trackID: 2) == nil)
        #expect(APACPreRollGroup.addingPreRoll(toMoof: Data(moof(videoOffset: 300, audioOffset: 500)), trackID: 9) == nil)
        let noDefaults = traf(track: 2, samples: 3, dataOffset: 500, defaultFlags: nil)
        #expect(APACPreRollGroup.addingPreRoll(toMoof: Data(moof(videoOffset: 300, audioOffset: 500, audio: noDefaults)), trackID: 2) == nil)
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
