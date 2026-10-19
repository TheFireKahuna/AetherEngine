import CoreMedia
import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// End of stream on the software route used to lose the last pictures of every file. The host's
/// end-of-stream path calls `drainForEndOfStream()` then `flush()`, and `SoftwareVideoDecoder` took
/// the protocol's empty default, so nothing ever sent libavcodec its NULL packet or told the
/// deinterlacer's buffersrc the stream was over: `flush()` then threw away what both still held.
/// Frame threading keeps up to `thread_count` frames in flight plus the B-frame reorder delay, and
/// yadif/bwdif hold one frame of look-ahead, so the loss was several frames per file and one more
/// (two fields at field rate) on interlaced sources.
///
/// Each fixture is 48 MPEG-2 frames with B-frames, so the count after the drain must be exact.
struct SoftwareDecoderEndOfStreamDrainTests {

    @Test("the drain delivers every frame of a progressive B-frame stream")
    func progressiveDrainsEveryFrame() throws {
        let run = try Self.decode(Self.progressiveBase64)
        #expect(run.packets == 48)
        #expect(run.frames.count == 48)
        #expect(Set(run.frames).count == run.frames.count)
    }

    @Test("the drain flushes the deinterlacer's look-ahead at field rate")
    func fieldRateDrainsEveryField() throws {
        let run = try Self.decode(Self.interlacedBase64, config: DeinterlaceConfig(mode: .auto, fieldRate: .field))
        #expect(run.packets == 48)
        #expect(run.frames.count == 96)
        #expect(Set(run.frames).count == run.frames.count)
    }

    @Test("the drain flushes the software deinterlacer's look-ahead")
    func softwareDeinterlacerDrainsEveryFrame() throws {
        let run = try Self.decode(Self.interlacedBase64, config: DeinterlaceConfig(mode: .software, fieldRate: .frame))
        #expect(run.packets == 48)
        #expect(run.frames.count == 48)
        #expect(Set(run.frames).count == run.frames.count)
    }

    /// libavcodec refuses every packet after its NULL packet until `avcodec_flush_buffers`, and a
    /// buffersrc that saw EOF refuses every frame. A seek after the end (the viewer scrubbing back
    /// from the end screen) has to decode again, interlaced sources included.
    @Test("the decoder decodes again after a drain and a flush", arguments: [false, true])
    func decodesAgainAfterDrain(interlaced: Bool) throws {
        let fixture = interlaced ? Self.interlacedBase64 : Self.progressiveBase64
        let decoder = SoftwareVideoDecoder()
        decoder.deinterlaceConfig = DeinterlaceConfig(mode: .software, fieldRate: .frame)
        let collector = PTSCollector()
        let first = try Self.openFixture(fixture)
        defer { first.close() }
        try decoder.open(stream: try #require(first.stream(at: first.videoStreamIndex))) { _, pts, _ in
            collector.append(pts)
        }
        defer { decoder.close() }

        Self.feed(first, to: decoder)
        decoder.drainForEndOfStream()
        decoder.flush()
        #expect(collector.values.count == 48)

        let second = try Self.openFixture(fixture)
        defer { second.close() }
        Self.feed(second, to: decoder)
        decoder.drainForEndOfStream()
        #expect(collector.values.count == 96)
    }

    // MARK: - Harness

    private struct Run {
        var packets: Int
        var frames: [CMTime]
    }

    private static func decode(_ fixture: String, config: DeinterlaceConfig = DeinterlaceConfig()) throws -> Run {
        let demuxer = try openFixture(fixture)
        defer { demuxer.close() }
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        let collector = PTSCollector()
        let decoder = SoftwareVideoDecoder()
        decoder.deinterlaceConfig = config
        try decoder.open(stream: stream) { _, pts, _ in collector.append(pts) }
        defer { decoder.close() }

        let packets = feed(demuxer, to: decoder)
        decoder.drainForEndOfStream()
        return Run(packets: packets, frames: collector.values)
    }

    private static func openFixture(_ base64: String) throws -> Demuxer {
        let data = try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        return demuxer
    }

    @discardableResult
    private static func feed(_ demuxer: Demuxer, to decoder: SoftwareVideoDecoder) -> Int {
        let videoIndex = demuxer.videoStreamIndex
        var packets = 0
        while let pkt = try? demuxer.readPacket() {
            if pkt.pointee.stream_index == videoIndex {
                packets += 1
                decoder.decode(packet: pkt)
            }
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        return packets
    }

    private final class PTSCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CMTime] = []
        func append(_ pts: CMTime) {
            lock.lock()
            storage.append(pts)
            lock.unlock()
        }
        var values: [CMTime] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    // MARK: - Fixtures

    /// 64x48 MPEG-2, 48 frames at 25 fps, two B-frames per GOP of 12, progressive. Regenerate:
    ///   ffmpeg -f lavfi -i "color=c=gray:s=64x48:r=25:d=1.92" -c:v mpeg2video -bf 2 -g 12 \
    ///     -q:v 20 -pix_fmt yuv420p prog.mp4
    ///   base64 -b 100 -i prog.mp4
    static let progressiveBase64 = """
        AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAIrG1kYXQAAAGzBAAwI///4BgAAAG1FIoAAQAAAAABuAAIAEAA
        AAEAAA//+AAAAbWP//NBgAAAAQGjWlKRFylKRFylKRFylKREAAABAqNaUpEXKUpEXKUpEXKUpEQAAAEDo1pSkRcpSkRcpSkRcpSk
        RAAAAQAA1//7gAAAAbWBH/NBgAAAAQGidHAAAAEConRwAAABA6J0cAAAAQAAX//7uAAAAbWBERNBgAAAAQGitLAAAAECorSwAAAB
        A6K0sAAAAQAAn//7uAAAAbWBERNBgAAAAQGitLAAAAECorSwAAABA6K0sAAAAQABl//7gAAAAbWBH/NBgAAAAQGidHAAAAEConRw
        AAABA6J0cAAAAQABH//7uAAAAbWBERNBgAAAAQGitLAAAAECorSwAAABA6K0sAAAAQABX//7uAAAAbWBERNBgAAAAQGitLAAAAEC
        orSwAAABA6K0sAAAAQACV//7gAAAAbWBH/NBgAAAAQGidHAAAAEConRwAAABA6J0cAAAAQAB3//7uAAAAbWBERNBgAAAAQGitLAA
        AAECorSwAAABA6K0sAAAAQACH//7uAAAAbWBERNBgAAAAQGitLAAAAECorSwAAABA6K0sAAAAbMEADAj///gGAAAAbUUigABAAAA
        AAG4AAgFAAAAAQAAj//4AAABtY//80GAAAABAaNaUpEXKUpEXKUpEXKUpEQAAAECo1pSkRcpSkRcpSkRcpSkRAAAAQOjWlKRFylK
        RFylKRFylKREAAABAAAf//u4AAABtYERE0GAAAABAaK0sAAAAQKitLAAAAEDorSwAAABAABf//u4AAABtYERE0GAAAABAaK0sAAA
        AQKitLAAAAEDorSwAAABAAFX//uAAAABtYEf80GAAAABAaJ0cAAAAQKidHAAAAEDonRwAAABAADf//u4AAABtYERE0GAAAABAaK0
        sAAAAQKitLAAAAEDorSwAAABAAEf//u4AAABtYERE0GAAAABAaK0sAAAAQKitLAAAAEDorSwAAABAAIX//uAAAABtYEf80GAAAAB
        AaJ0cAAAAQKidHAAAAEDonRwAAABAAGf//u4AAABtYERE0GAAAABAaK0sAAAAQKitLAAAAEDorSwAAABAAHf//u4AAABtYERE0GA
        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
        AAAAAAAAAAAAAAAAAABAADAASAAAAEgAAAAAAAAAARdMYXZjNjMuMS4xMDIgbXBlZzJ2aWRlbwAAAAAAAAAAABj//wAAACxlc2Rz
        AAAAAAOAgIAbAAEABICAgA1hEQAAAAADDUAAACQABoCAgAECAAAACmZpZWwBAAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAA
        Aw1AAAAkAAAAABhzdHRzAAAAAAAAAAEAAAAwAAACAAAAACRzdHNzAAAAAAAAAAUAAAABAAAACwAAABcAAAAjAAAALwAAARhjdHRz
        AAAAAAAAACEAAAABAAACAAAAAAEAAAYAAAAAAgAAAAAAAAABAAAGAAAAAAIAAAAAAAAAAQAABgAAAAACAAAAAAAAAAEAAAYAAAAA
        AgAAAAAAAAABAAAGAAAAAAIAAAAAAAAAAQAABgAAAAACAAAAAAAAAAEAAAYAAAAAAgAAAAAAAAABAAAGAAAAAAIAAAAAAAAAAQAA
        BgAAAAACAAAAAAAAAAEAAAYAAAAAAgAAAAAAAAABAAAGAAAAAAIAAAAAAAAAAQAABgAAAAACAAAAAAAAAAEAAAYAAAAAAgAAAAAA
        AAABAAAGAAAAAAIAAAAAAAAAAQAABgAAAAACAAAAAAAAAAEAAAQAAAAAAQAAAAAAAAAcc3RzYwAAAAAAAAABAAAAAQAAADAAAAAB
        AAAA1HN0c3oAAAAAAAAAAAAAADAAAABrAAAAJwAAACcAAAAnAAAAJwAAACcAAAAnAAAAJwAAACcAAAAnAAAAawAAACcAAAAnAAAA
        JwAAACcAAAAnAAAAJwAAACcAAAAnAAAAJwAAACcAAAAnAAAAawAAACcAAAAnAAAAJwAAACcAAAAnAAAAJwAAACcAAAAnAAAAJwAA
        ACcAAAAnAAAAawAAACcAAAAnAAAAJwAAACcAAAAnAAAAJwAAACcAAAAnAAAAJwAAACcAAAAnAAAAawAAACcAAAAUc3RjbwAAAAAA
        AAABAAAALAAAAGF1ZHRhAAAAWW1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALGlsc3QAAAAkqXRv
        bwAAABxkYXRhAAAAAQAAAABMYXZmNjMuMS4xMDI=
        """

    /// The same stream coded interlaced, top field first (every picture carries
    /// `AV_FRAME_FLAG_INTERLACED`). Regenerate:
    ///   ffmpeg -f lavfi -i "color=c=gray:s=64x48:r=25:d=1.92,setfield=tff" -c:v mpeg2video -bf 2 \
    ///     -g 12 -q:v 20 -flags +ildct+ilme -field_order tt -pix_fmt yuv420p intl.mp4
    ///   base64 -b 100 -i intl.mp4
    static let interlacedBase64 = """
        AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAKjW1kYXQAAAGzBAAwI///4BgAAAG1FIIAAQAAAAABuAAIAEAA
        AAEAAA//+AAAAbWP//OAAAAAAQGjLSlIi0pSkRaUpSItKUpEQAAAAQKjLSlIi0pSkRaUpSItKUpEQAAAAQOjLSlIi0pSkRaUpSIt
        KUpEQAAAAQSjLSlIi0pSkRaUpSItKUpEQAAAAQAA1//7gAAAAbWBH/OAAAAAAQGibRsAAAECom0bAAABA6JtGwAAAQSiMtKUiKNK
        UpEUaUpSIo0pSkRAAAABAABf//u4AAABtYERE4AAAAABAaKtKwAAAQKirSsAAAEDoq0rAAABBKKtKwAAAQAAn//7uAAAAbWBEROA
        AAAAAQGirSsAAAECoq0rAAABA6KtKwAAAQSirSsAAAEAAZf/+4AAAAG1gR/zgAAAAAEBom0bAAABAqJtGwAAAQOibRsAAAEEom0M
        tKUiIAAAAQABH//7uAAAAbWBEROAAAAAAQGirSsAAAECoq0rAAABA6KtKwAAAQSirSsAAAEAAV//+7gAAAG1gRETgAAAAAEBoq0r
        AAABAqKtKwAAAQOirSsAAAEEoq0rAAABAAJX//uAAAABtYEf84AAAAABAaJtGwAAAQKibRsAAAEDom0bAAABBKJtDLSlIiAAAAEA
        Ad//+7gAAAG1gRETgAAAAAEBoq0rAAABAqKtKwAAAQOirSsAAAEEoq0rAAABAAIf//u4AAABtYERE4AAAAABAaKtKwAAAQKirSsA
        AAEDoq0rAAABBKKtKwAAAbMEADAj///gGAAAAbUUggABAAAAAAG4AAgFAAAAAQAAj//4AAABtY//84AAAAABAaMtKUiLSlKRFpSl
        Ii0pSkRAAAABAqMtKUiLSlKRFpSlIi0pSkRAAAABA6MtKUiLSlKRFpSlIi0pSkRAAAABBKMtKUiLSlKRFpSlIi0pSkRAAAABAAAf
        //u4AAABtYERE4AAAAABAaKtKwAAAQKirSsAAAEDoq0rAAABBKKtKwAAAQAAX//7uAAAAbWBEROAAAAAAQGirSsAAAECoq0rAAAB
        A6KtKwAAAQSirSsAAAEAAVf/+4AAAAG1gR/zgAAAAAEBom0bAAABAqJtGwAAAQOibRsAAAEEom0MtKUiIAAAAQAA3//7uAAAAbWB
        EROAAAAAAQGirSsAAAECoq0rAAABA6KtKwAAAQSirSsAAAEAAR//+7gAAAG1gRETgAAAAAEBoq0rAAABAqKtKwAAAQOirSsAAAEE
        oq0rAAABAAIX//uAAAABtYEf84AAAAABAaJtGwAAAQKibRsAAAEDom0bAAABBKJtDLSlIiAAAAEAAZ//+7gAAAG1gRETgAAAAAEB
        oq0rAAABAqKtKwAAAQOirSsAAAEEoq0rAAABAAHf//u4AAABtYERE4AAAAABAaKtKwAAAQKirSsAAAEDoq0rAAABBKKtKwAAAQAC
        1//7gAAAAbWBH/OAAAAAAQGibRsAAAECom0bAAABA6JtGwAAAQSibQy0pSIgAAABAAJf//u4AAABtYERE4AAAAABAaKtKwAAAQKi
        rSsAAAEDoq0rAAABBKKtKwAAAQACn//7uAAAAbWBEROAAAAAAQGirSsAAAECoq0rAAABA6KtKwAAAQSirSsAAAGzBAAwI///4BgA
        AAG1FIIAAQAAAAABuAAICwAAAAEAAI//+AAAAbWP//OAAAAAAQGjLSlIi0pSkRaUpSItKUpEQAAAAQKjLSlIi0pSkRaUpSItKUpE
        QAAAAQOjLSlIi0pSkRaUpSItKUpEQAAAAQSjLSlIi0pSkRaUpSItKUpEQAAAAQAAH//7uAAAAbWBEROAAAAAAQGirSsAAAECoq0r
        AAABA6KtKwAAAQSirSsAAAEAAF//+7gAAAG1gRETgAAAAAEBoq0rAAABAqKtKwAAAQOirSsAAAEEoq0rAAABAAFX//uAAAABtYEf
        84AAAAABAaJtGwAAAQKibRsAAAEDom0bAAABBKJtDLSlIiAAAAEAAN//+7gAAAG1gRETgAAAAAEBoq0rAAABAqKtKwAAAQOirSsA
        AAEEoq0rAAABAAEf//u4AAABtYERE4AAAAABAaKtKwAAAQKirSsAAAEDoq0rAAABBKKtKwAAAQACF//7gAAAAbWBH/OAAAAAAQGi
        bRsAAAECom0bAAABA6JtGwAAAQSibQy0pSIgAAABAAGf//u4AAABtYERE4AAAAABAaKtKwAAAQKirSsAAAEDoq0rAAABBKKtKwAA
        AQAB3//7uAAAAbWBEROAAAAAAQGirSsAAAECoq0rAAABA6KtKwAAAQSirSsAAAEAAtf/+4AAAAG1gR/zgAAAAAEBom0bAAABAqJt
        GwAAAQOibRsAAAEEom0MtKUiIAAAAQACX//7uAAAAbWBEROAAAAAAQGirSsAAAECoq0rAAABA6KtKwAAAQSirSsAAAEAAp//+7gA
        AAG1gRETgAAAAAEBoq0rAAABAqKtKwAAAQOirSsAAAEEoq0rAAABswQAMCP//+AYAAABtRSCAAEAAAAAAbgACCSAAAABAACP//gA
        AAG1j//zgAAAAAEBoy0pSItKUpEWlKUiLSlKREAAAAECoy0pSItKUpEWlKUiLSlKREAAAAEDoy0pSItKUpEWlKUiLSlKREAAAAEE
        oy0pSItKUpEWlKUiLSlKREAAAAEAAB//+7gAAAG1gRETgAAAAAEBoq0rAAABAqKtKwAAAQOirSsAAAEEoq0rAAABAABf//u4AAAB
        tYERE4AAAAABAaKtKwAAAQKirSsAAAEDoq0rAAABBKKtKwAAAQABV//7gAAAAbWBH/OAAAAAAQGibRsAAAECom0bAAABA6JtGwAA
        AQSibQy0pSIgAAABAADf//u4AAABtYERE4AAAAABAaKtKwAAAQKirSsAAAEDoq0rAAABBKKtKwAAAQABH//7uAAAAbWBEROAAAAA
        AQGirSsAAAECoq0rAAABA6KtKwAAAQSirSsAAAEAAhf/+4AAAAG1gR/zgAAAAAEBom0bAAABAqJtGwAAAQOibRsAAAEEom0MtKUi
        IAAAAQABn//7uAAAAbWBEROAAAAAAQGirSsAAAECoq0rAAABA6KtKwAAAQSirSsAAAEAAd//+7gAAAG1gRETgAAAAAEBoq0rAAAB
        AqKtKwAAAQOirSsAAAEEoq0rAAABAALX//uAAAABtYEf84AAAAABAaJtGwAAAQKibRsAAAEDom0bAAABBKJtDLSlIiAAAAEAAl//
        +7gAAAG1gRETgAAAAAEBoq0rAAABAqKtKwAAAQOirSsAAAEEoq0rAAABAAKf//u4AAABtYERE4AAAAABAaKtKwAAAQKirSsAAAED
        oq0rAAABBKKtKwAAAbMEADAj///gGAAAAbUUggABAAAAAAG4AAgqgAAAAQAAT//4AAABtY//84AAAAABAaMtKUiLSlKRFpSlIi0p
        SkRAAAABAqMtKUiLSlKRFpSlIi0pSkRAAAABA6MtKUiLSlKRFpSlIi0pSkRAAAABBKMtKUiLSlKRFpSlIi0pSkRAAAABAAAf//u4
        AAABtYERE4AAAAABAaKtKwAAAQKirSsAAAEDoq0rAAABBKKtKwAABRJtb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAHgAAB
        AAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAACAAAEPXRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAHgAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAA
        AAEAAAAAAAAAAAAAAAAAAEAAAAAAQAAAADAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAB4AAAAIAAAEAAAAAA7VtZGlhAAAA
        IG1kaGQAAAAAAAAAAAAAAAAAADIAAABgAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAA
        AANgbWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAADIHN0YmwAAADA
        c3RzZAAAAAAAAAABAAAAsG1wNHYAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAQAAwAEgAAABIAAAAAAAAAAEXTGF2YzYzLjEuMTAy
        IG1wZWcydmlkZW8AAAAAAAAAAAAY//8AAAAsZXNkcwAAAAADgICAGwABAASAgIANYREAAAAAAw1AAAAr1AaAgIABAgAAAApmaWVs
        AgkAAAAQcGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAAMNQAAAK9QAAAAYc3R0cwAAAAAAAAABAAAAMAAAAgAAAAAkc3RzcwAAAAAA
        AAAFAAAAAQAAAAsAAAAXAAAAIwAAAC8AAAEYY3R0cwAAAAAAAAAhAAAAAQAAAgAAAAABAAAGAAAAAAIAAAAAAAAAAQAABgAAAAAC
        AAAAAAAAAAEAAAYAAAAAAgAAAAAAAAABAAAGAAAAAAIAAAAAAAAAAQAABgAAAAACAAAAAAAAAAEAAAYAAAAAAgAAAAAAAAABAAAG
        AAAAAAIAAAAAAAAAAQAABgAAAAACAAAAAAAAAAEAAAYAAAAAAgAAAAAAAAABAAAGAAAAAAIAAAAAAAAAAQAABgAAAAACAAAAAAAA
        AAEAAAYAAAAAAgAAAAAAAAABAAAGAAAAAAIAAAAAAAAAAQAABgAAAAACAAAAAAAAAAEAAAYAAAAAAgAAAAAAAAABAAAEAAAAAAEA
        AAAAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAwAAAAAQAAANRzdHN6AAAAAAAAAAAAAAAwAAAAgwAAAD4AAAAuAAAALgAAADIAAAAu
        AAAALgAAADIAAAAuAAAALgAAAIMAAAAuAAAALgAAADIAAAAuAAAALgAAADIAAAAuAAAALgAAADIAAAAuAAAALgAAAIMAAAAuAAAA
        LgAAADIAAAAuAAAALgAAADIAAAAuAAAALgAAADIAAAAuAAAALgAAAIMAAAAuAAAALgAAADIAAAAuAAAALgAAADIAAAAuAAAALgAA
        ADIAAAAuAAAALgAAAIMAAAAuAAAAFHN0Y28AAAAAAAAAAQAAACwAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABt
        ZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYzLjEuMTAy
        """
}
