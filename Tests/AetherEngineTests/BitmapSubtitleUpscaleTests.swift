import CoreGraphics
import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
@testable import AetherEngine

/// The overlay drain's bitmap upscale (`bitmapSubtitlePixelSize`, trait `MLSubtitleUpscale`): the drain ticks of the
/// production path on synthetic PGS display sets, and the rules that pick a cue's size and which cues can show.
struct BitmapSubtitleUpscaleTests {

    private static func image(width: Int, height: Int, canvas: CGSize) -> SubtitleImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return SubtitleImage(cgImage: context.makeImage()!, position: CGRect(x: 0.1, y: 0.8, width: 0.4, height: 0.05),
                             canvasSize: canvas)
    }

    @Test("a cue is drawn at its canvas scaled to cover the host's picture, and not upscaled below 1.2x")
    func outputSize() {
        let pgs = Self.image(width: 900, height: 80, canvas: CGSize(width: 1920, height: 1080))
        #expect(BitmapSubtitleUpscaling.outputSize(pgs, pixelSize: CGSize(width: 3840, height: 2160)) == CGSize(width: 1800, height: 160))
        #expect(BitmapSubtitleUpscaling.outputSize(pgs, pixelSize: CGSize(width: 1920, height: 1080)) == nil)
        let dvd = Self.image(width: 360, height: 40, canvas: CGSize(width: 720, height: 480))
        #expect(BitmapSubtitleUpscaling.outputSize(dvd, pixelSize: CGSize(width: 3840, height: 2160)) == CGSize(width: 1920, height: 213))
        // A 4:3 picture on a 2160p panel: the 16:9 canvas covers it by height.
        #expect(BitmapSubtitleUpscaling.outputSize(pgs, pixelSize: CGSize(width: 2880, height: 2160)) == CGSize(width: 1800, height: 160))
        // A scope picture: by width.
        #expect(BitmapSubtitleUpscaling.outputSize(pgs, pixelSize: CGSize(width: 3840, height: 1607)) == CGSize(width: 1800, height: 160))
        let unknown = Self.image(width: 360, height: 40, canvas: .zero)
        #expect(BitmapSubtitleUpscaling.outputSize(unknown, pixelSize: CGSize(width: 3840, height: 2160)) == nil)
    }

    @Test("the cues that can still show are the last set at or before the playhead and everything after it")
    func firstShowable() {
        func event(_ start: Double?) -> EmbeddedSubtitleDecoder.SubtitleEvent {
            let cues = start.map { [SubtitleCue(id: 0, startTime: $0, endTime: $0 + 4, body: .text("x"))] } ?? []
            return .init(cues: cues, isPGS: true, pgsTrimAt: start)
        }
        #expect(BitmapSubtitleUpscaling.firstShowable([event(10), event(nil), event(16), event(30)], playhead: 17) == 2)
        #expect(BitmapSubtitleUpscaling.firstShowable([event(10), event(16), event(nil), event(30)], playhead: 20) == 1)
        #expect(BitmapSubtitleUpscaling.firstShowable([event(30), event(40)], playhead: 17) == 0)
        #expect(BitmapSubtitleUpscaling.firstShowable([nil, event(nil)], playhead: 17) == 0)
    }

    // MARK: - Drain ticks

    /// A PGS segment: [type:1][len:2 BE][body].
    private static func segment(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        [type, UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)] + body
    }

    /// A self-contained (Epoch Start) display set on a 1920x1080 canvas: one 8x8 opaque white object at (100, 900).
    private static let displaySet: Data = {
        let pcs = segment(0x16, [0x07, 0x80, 0x04, 0x38, 0x10, 0x00, 0x01, 0x80, 0x00, 0x00, 0x01,
                                 0x00, 0x00, 0x00, 0x00, 0x00, 0x64, 0x03, 0x84])
        let wds = segment(0x17, [0x01, 0x00, 0x00, 0x64, 0x03, 0x84, 0x00, 0x08, 0x00, 0x08])
        let pds = segment(0x14, [0x00, 0x00, 0x00, 0x10, 0x80, 0x80, 0x00, 0x01, 0xEB, 0x80, 0x80, 0xFF])
        let rle = Array(repeating: [0x00, 0x88, 0x01, 0x00, 0x00] as [UInt8], count: 8).flatMap { $0 }
        let ods = segment(0x15, [0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x2C, 0x00, 0x08, 0x00, 0x08] + rle)
        return Data(pcs + wds + pds + ods + segment(0x80, []))
    }()

    /// A PGS stream for the decoders, held by a format context the test frees.
    private final class PGSStream {
        var format: UnsafeMutablePointer<AVFormatContext>?
        let stream: UnsafeMutablePointer<AVStream>
        init() throws {
            format = avformat_alloc_context()
            stream = try #require(avformat_new_stream(format, nil))
            stream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
            stream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_HDMV_PGS_SUBTITLE
            stream.pointee.time_base = AVRational(num: 1, den: 1000)
        }
        deinit { avformat_free_context(format) }
    }

    private static let streamIndex: Int32 = 3

    /// An engine drawing at 3840x2160, playhead 17, with display sets at 10, 16, 30 and 60 s stored.
    @MainActor
    private func engine(pixelSize: CGSize?) throws -> (AetherEngine, PGSStream) {
        let pgs = try PGSStream()
        let store = SubtitlePacketStore()
        for start in [10.0, 16, 30, 60] {
            store.append(streamIndex: Self.streamIndex, ptsSeconds: start, durationSeconds: 0, flags: 1,
                         payload: Self.displaySet)
        }
        // The harvest read the whole stretch, so a set behind the playhead may claim the landing (#416).
        store.noteHarvestAnchor(at: 0)
        store.noteHarvestReach(through: 70)
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://s/movie.mkv")!
        engine.softwareSubtitlePacketStore = store
        engine.isSubtitleActive = true
        engine.bitmapSubtitlePixelSize = pixelSize
        engine.subtitleDrainTargets[.primary] = Self.streamIndex
        engine.subtitleDrainDecoderFactoryForTesting = { _ in
            EmbeddedSubtitleDecoder(stream: pgs.stream, sourceVideoWidth: 1920, sourceVideoHeight: 1080)
        }
        engine.clock.sourceTime = 17
        return (engine, pgs)
    }

    private static func sizes(_ cues: [SubtitleCue]) -> [Double: Int] {
        Dictionary(uniqueKeysWithValues: cues.compactMap { cue in
            if case .image(let image) = cue.body { (cue.startTime, image.cgImage.width) } else { nil }
        })
    }

    @MainActor
    @Test("without a pixel size the landing decodes its whole window in one tick and cues publish as decoded")
    func noPixelSize() async throws {
        let (engine, pgs) = try engine(pixelSize: nil)
        engine.requestSubtitleDrainTick()
        await engine.subtitleDrainTickInFlight?.value
        #expect(Self.sizes(engine.subtitleCues) == [16: 8, 30: 8, 60: 8])
        #expect(engine.subtitleDrainTickInFlight == nil)
        withExtendedLifetime(pgs) {}
    }

    #if MLSubtitleUpscale
    @MainActor
    @Test("an upscaling landing publishes the line on screen and its successor upscaled, and the lead follows in the next tick, upscaled")
    func landingThenLead() async throws {
        let (engine, pgs) = try engine(pixelSize: CGSize(width: 3840, height: 2160))
        engine.requestSubtitleDrainTick()
        await engine.subtitleDrainTickInFlight?.value
        // The landing: decoded through the composition that ends the reconstruction pass (30), both lines 2x.
        #expect(Self.sizes(engine.subtitleCues) == [16: 16, 30: 16])
        // Asked for at once, the next tick brings the rest of the lead, each set upscaled before it publishes.
        let next = try #require(engine.subtitleDrainTickInFlight)
        await next.value
        #expect(Self.sizes(engine.subtitleCues) == [16: 16, 30: 16, 60: 16])
        withExtendedLifetime(pgs) {}
    }

    @MainActor
    @Test("cues that published as decoded are re-landed on the return to the foreground and replaced by their upscales")
    func owedCuesAreRelanded() async throws {
        let (engine, pgs) = try engine(pixelSize: nil)
        engine.requestSubtitleDrainTick()
        await engine.subtitleDrainTickInFlight?.value
        #expect(Self.sizes(engine.subtitleCues) == [16: 8, 30: 8, 60: 8])
        // As a background tick leaves it: the pixel size stands, the channel's cues are owed.
        engine.bitmapSubtitlePixelSize = CGSize(width: 3840, height: 2160)
        engine.bitmapSubtitleUpscaleOwed = [.primary]
        engine.resumeBitmapSubtitleUpscale()
        await engine.subtitleDrainTickInFlight?.value
        #expect(Self.sizes(engine.subtitleCues) == [16: 16, 30: 16, 60: 8])
        await engine.subtitleDrainTickInFlight?.value
        #expect(Self.sizes(engine.subtitleCues) == [16: 16, 30: 16, 60: 16])
        #expect(engine.bitmapSubtitleUpscaleOwed.isEmpty)
        withExtendedLifetime(pgs) {}
    }
    #endif
}
