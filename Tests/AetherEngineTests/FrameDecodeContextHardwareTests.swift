import Foundation
import CoreGraphics
import Testing
@testable import AetherEngine

/// Cache-backed stills are the one extraction path allowed to ask for VideoToolbox: native
/// playback is already on the hardware path, so issue #27's software-playback starvation does
/// not apply. A codec VideoToolbox declines must remain a successful software still, not a miss.
struct FrameDecodeContextHardwareTests {
    @Test("cancelled resident request never opens or decodes a source")
    func cancelledResidentRequest() async {
        let extractor = FrameExtractor(reader: DataIOReader(data: Data()), formatHint: "mp4")
        #expect(await extractor.residentPreview(rawTarget: 1, refined: true, maxWidth: 320, isCancelled: { true }) == nil)
        await extractor.shutdown()
    }
    @Test("resident refinement reports actual PTS and cannot invent a target frame past EOF")
    func residentActualPTSAndMissingTarget() throws {
        let data = try #require(Data(base64Encoded: Self.mpeg4FixtureBase64, options: .ignoreUnknownCharacters))
        let context = FrameDecodeContext(reader: DataIOReader(data: data), formatHint: "mp4", allowsHardwareDecode: false)
        defer { context.close() }
        try context.ensureOpen()
        var actual: Double?
        var refined = false
        let image = context.decodeFrame(at: 0, mode: .snapshot, targetWidth: 64,
            maxSize: CGSize(width: 64, height: 64), isCancelled: { false }, residentTarget: 0,
            reportResidentTime: { actual = $0; refined = $1 })
        #expect(image != nil)
        #expect(actual == 0)
        #expect(refined)
        actual = nil
        let missing = context.decodeFrame(at: 0, mode: .snapshot, targetWidth: 64,
            maxSize: CGSize(width: 64, height: 64), isCancelled: { false }, residentTarget: 0.9,
            reportResidentTime: { actual = $0; refined = $1 })
        #expect(missing == nil)
        #expect(actual == nil)
        #expect(context.decodeFrame(at: 0, mode: .thumbnail, targetWidth: 64, maxSize: nil,
            isCancelled: { true }, residentTarget: 0) == nil)
    }

    @Test("hardware-allowed still falls back for an MPEG-4 Part 2 fixture")
    func declinedCodecStillDecodes() throws {
        let data = try #require(Data(
            base64Encoded: Self.mpeg4FixtureBase64,
            options: .ignoreUnknownCharacters))
        let context = FrameDecodeContext(
            reader: DataIOReader(data: data),
            formatHint: "mp4",
            allowsHardwareDecode: true)
        defer { context.close() }

        try context.ensureOpen()
        let image = context.decodeFrame(
            at: 0,
            mode: .thumbnail,
            targetWidth: 64,
            maxSize: nil,
            isCancelled: { false })

        #expect(image != nil)
        #expect(context.hardwareDecoderName == "none")
    }

    @Test("a still decodes on VideoToolbox where the context allows it and it has not failed")
    func hardwareRule() {
        #expect(FrameDecodeContext.stillUsesHardware(allows: true, disabled: false))
        #expect(!FrameDecodeContext.stillUsesHardware(allows: true, disabled: true))
        #expect(!FrameDecodeContext.stillUsesHardware(allows: false, disabled: false))
    }

    @Test("accurate previews decode past the keyframe and match downscaled snapshots")
    func accuratePreview() throws {
        let data = try #require(Data(base64Encoded: Self.previewFixtureBase64, options: .ignoreUnknownCharacters))
        let context = FrameDecodeContext(reader: DataIOReader(data: data), formatHint: "mp4", allowsHardwareDecode: false)
        defer { context.close() }
        try context.ensureOpen()
        var actual: Double?
        let thumbnail = context.decodeFrame(at: 0.75, mode: .thumbnail, targetWidth: 16, maxSize: nil,
            isCancelled: { false }, reportDecodedTime: { actual = $0 })
        #expect(thumbnail != nil)
        #expect(actual == 0)
        let preview = try #require(context.decodeFrame(at: 0.75, mode: .preview, targetWidth: 16, maxSize: nil,
            isCancelled: { false }, reportDecodedTime: { actual = $0 }))
        #expect(actual == 0.75)
        #expect(preview.width == 16 && preview.height == 16)
        let snapshot = try #require(context.decodeFrame(at: 0.75, mode: .snapshot, targetWidth: 0,
            maxSize: CGSize(width: 16, height: 16), isCancelled: { false }))
        let previewData = try #require(preview.dataProvider?.data)
        let snapshotData = try #require(snapshot.dataProvider?.data)
        #expect(previewData as Data == snapshotData as Data)
        #expect(context.decodeFrame(at: 0.75, mode: .preview, targetWidth: 16, maxSize: nil,
            isCancelled: { true }) == nil)
    }

    @Test("preview API respects dimensions, starvation and shutdown")
    func previewLifecycle() async throws {
        let data = try #require(Data(base64Encoded: Self.previewFixtureBase64, options: .ignoreUnknownCharacters))
        let extractor = FrameExtractor(reader: DataIOReader(data: data), formatHint: "mp4")
        let small = try #require(await extractor.preview(at: 0.75, maxWidth: 8))
        let large = try #require(await extractor.preview(at: 0.75, maxWidth: 16))
        #expect(small.width == 8 && large.width == 16)
        #expect(await extractor.preview(at: 0.75, maxWidth: 16) === large)
        await extractor.shutdown()
        #expect(await extractor.preview(at: 0.75, maxWidth: 16) == nil)

        let starved = FrameExtractor(reader: DataIOReader(data: data), formatHint: "mp4", yieldWhile: { true })
        #expect(await starved.preview(at: 0.75, maxWidth: 16) == nil)
        #expect(await starved.snapshot(at: 0.75, maxSize: CGSize(width: 16, height: 16)) != nil)
        await starved.shutdown()
    }

    /// Eight 32x32 MPEG-4 Part 2 frames at 4 fps; only the first is a keyframe.
    /// ffmpeg -f lavfi -i testsrc2=size=32x32:rate=4:duration=2 -c:v mpeg4 -g 100
    ///   -sc_threshold 1000000000 -q:v 12 -pix_fmt yuv420p -movflags +faststart preview.mp4
    private static let previewFixtureBase64 = """
        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
        """

    /// One 64x64 MPEG-4 Part 2 frame. VideoToolbox does not offer that legacy codec, while
    /// FFmpeg's software decoder does; this is the deterministic decline/fallback witness.
    /// Regenerate with:
    /// `ffmpeg -f lavfi -i color=c=red:s=64x64:r=1:d=1 -c:v mpeg4 -q:v 5 -pix_fmt yuv420p -movflags +faststart vt-decline.mp4`
    private static let mpeg4FixtureBase64 = """
        AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAA0Ftb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAD6AABAAABAAAA
        AAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC
        AAACa3RyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAD6AAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAA
        AAEAAAAAAAAAAAAAAAAAAEAAAAAAQAAAAEAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAA+gAAAAAAAEAAAAAAeNtZGlh
        AAAAIG1kaGQAAAAAAAAAAAAAAAAAAEAAAABAAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFu
        ZGxlcgAAAAGObWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAB
        TnN0YmwAAADqc3RzZAAAAAAAAAABAAAA2m1wNHYAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAQABAAEgAAABIAAAAAAAAAAET
        TGF2YzYyLjI4LjEwMCBtcGVnNAAAAAAAAAAAAAAAAAAY//8AAABgZXNkcwAAAAADgICATwABAASAgIBBIBEAAAAAAw1AAAAC
        qAWAgIAvAAABsAEAAAG1iRMAAAEAAAABIADEjYgADQIECBRDAAABskxhdmM2Mi4yOC4xMDAGgICAAQIAAAAQcGFzcAAAAAEA
        AAABAAAAFGJ0cnQAAAAAAAMNQAAAAqgAAAAYc3R0cwAAAAAAAAABAAAAAQAAQAAAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAEA
        AAABAAAAFHN0c3oAAAAAAAAAVQAAAAEAAAAUc3RjbwAAAAAAAAABAAADbQAAAGJ1ZHRhAAAAWm1ldGEAAAAAAAAAIWhkbHIA
        AAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAAAQAAAABMYXZmNjIuMTIuMTAwAAAA
        CGZyZWUAAABdbWRhdAAAAbMAEAcAAAG2FgsYWm2C6Bxxtt/G238bbfsAAKFRhabYLoHHG238bbfxtt+/AADBUYWm2C6Bxxtt
        /G238bbfvwAA4VGFptgugccbbfxtt/G2378=
        """
}
