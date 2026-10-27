import Testing
import Foundation
import CoreMedia
import CoreVideo
import AetherLibavutil
@testable import AetherEngine

/// #177 issue 3: anamorphic content on the software path rendered at coded dimensions (a thin
/// strip) because the renderer's cached CMVideoFormatDescription was created from whatever the
/// FIRST pixel buffer carried and the cache key omitted PAR, freezing a PAR-less description
/// for the whole stream. Aggravators: AVCodecContext.sample_aspect_ratio can be garbage
/// (1088:1) or oscillate per-field on interlaced content, and no upper-bound sanity gate
/// existed. The decoder now resolves SAR frame -> codec ctx -> stream (first sane wins),
/// latches the first non-square SAR per stream, and the renderer keys its format-description
/// cache on PAR as well.
@Suite("Software-path SAR resolution, latch, and PAR-keyed format cache (#177)")
struct Issue177SARLatchTests {

    private func rational(_ num: Int32, _ den: Int32) -> AVRational {
        AVRational(num: num, den: den)
    }

    // MARK: - Sanity gate

    @Test("garbage codec-context SAR (1088:1) is rejected by the sanity gate")
    func garbageSARRejected() {
        #expect(PixelAspectPolicy.saneSAR(rational(1088, 1)) == nil)
        #expect(PixelAspectPolicy.saneSAR(rational(1, 1088)) == nil)
        #expect(PixelAspectPolicy.saneSAR(rational(0, 1)) == nil)
        #expect(PixelAspectPolicy.saneSAR(rational(-4, 3)) == nil)
        #expect(PixelAspectPolicy.saneSAR(rational(4, 0)) == nil)
    }

    @Test("legit anamorphic SARs pass the gate")
    func legitSARsPass() {
        for sar in [rational(64, 45), rational(8, 9), rational(32, 27), rational(16, 11), rational(1, 1)] {
            let sane = PixelAspectPolicy.saneSAR(sar)
            #expect(sane?.num == sar.num)
            #expect(sane?.den == sar.den)
        }
    }

    @Test("precise and unreduced pixel ratios keep their declared components")
    func largeComponentsPreserveRatios() {
        for sar in [rational(759, 712), rational(1280, 900), rational(.max, .max - 1)] {
            let sane = PixelAspectPolicy.saneSAR(sar)
            #expect(sane?.num == sar.num)
            #expect(sane?.den == sar.den)
        }
        let resolved = SoftwareVideoDecoder.resolveSAR(
            frame: rational(0, 1), codecCtx: rational(0, 1), stream: rational(759, 712),
            width: 712, height: 574)
        #expect(resolved?.num == 759)
        #expect(resolved?.den == 712)
        #expect(PixelAspectPolicy.displayAspect(
            sar: rational(759, 712), width: 712, height: 574) == 759.0 / 574.0)
    }

    @Test("magnitude bounds apply independently of rational representation")
    func magnitudeBoundsAreScaleInvariant() {
        for sar in [rational(256, 1), rational(512, 2), rational(1, 256), rational(2, 512)] {
            #expect(PixelAspectPolicy.saneSAR(sar) != nil)
        }
        for sar in [rational(257, 1), rational(514, 2), rational(1, 257), rational(2, 514),
                    rational(.max, 1), rational(1, .max)] {
            #expect(PixelAspectPolicy.saneSAR(sar) == nil)
        }
    }

    @Test("large components still obey the display aspect gate")
    func preciseRatiosKeepDisplayBounds() {
        #expect(PixelAspectPolicy.saneSAR(rational(2000, 1000), width: 1920, height: 1080) == nil)
        #expect(PixelAspectPolicy.saneSAR(rational(2000, 1000), width: 960, height: 1080) != nil)
        #expect(PixelAspectPolicy.saneSAR(rational(.max, .max), width: 5120, height: 1440) != nil)
    }

    // MARK: - Resolution order

    @Test("frame SAR wins over codec context and stream")
    func frameWins() {
        let resolved = SoftwareVideoDecoder.resolveSAR(
            frame: rational(16, 11), codecCtx: rational(4, 3), stream: rational(1, 1),
            width: 720, height: 576)
        #expect(resolved?.num == 16)
        #expect(resolved?.den == 11)
    }

    @Test("garbage frame and ctx fall through to the stream SAR")
    func fallsThroughToStream() {
        let resolved = SoftwareVideoDecoder.resolveSAR(
            frame: rational(0, 1), codecCtx: rational(1088, 1), stream: rational(64, 45),
            width: 720, height: 576)
        #expect(resolved?.num == 64)
        #expect(resolved?.den == 45)
    }

    @Test("codec context SAR is consulted between frame and stream")
    func ctxBetweenFrameAndStream() {
        let resolved = SoftwareVideoDecoder.resolveSAR(
            frame: rational(0, 0), codecCtx: rational(8, 9), stream: rational(1, 1),
            width: 720, height: 480)
        #expect(resolved?.num == 8)
        #expect(resolved?.den == 9)
    }

    @Test("nothing sane anywhere resolves to nil")
    func nothingSaneIsNil() {
        #expect(SoftwareVideoDecoder.resolveSAR(
            frame: rational(0, 1), codecCtx: rational(1088, 1), stream: rational(0, 0),
            width: 720, height: 576) == nil)
    }

    // MARK: - Per-stream latch

    @Test("first non-square SAR latches and suppresses later oscillation")
    func latchSuppressesOscillation() {
        // Frame 1: anamorphic 64:45 -> attach and latch.
        let first = SoftwareVideoDecoder.sarForAttachment(
            resolved: rational(64, 45), latched: nil)
        #expect(first.attach?.num == 64)
        #expect(first.latch?.num == 64)

        // Frame 2 (other field) reports 1:1 -> the latch wins, no flicker.
        let second = SoftwareVideoDecoder.sarForAttachment(
            resolved: rational(1, 1), latched: first.latch)
        #expect(second.attach?.num == 64)
        #expect(second.attach?.den == 45)

        // Frame 3 reports a different non-square value -> the latch still wins.
        let third = SoftwareVideoDecoder.sarForAttachment(
            resolved: rational(32, 27), latched: first.latch)
        #expect(third.attach?.num == 64)
    }

    @Test("square or unknown SAR before any latch attaches nothing")
    func squareBeforeLatchAttachesNothing() {
        let square = SoftwareVideoDecoder.sarForAttachment(
            resolved: rational(1, 1), latched: nil)
        #expect(square.attach == nil)
        #expect(square.latch == nil)

        let unknown = SoftwareVideoDecoder.sarForAttachment(resolved: nil, latched: nil)
        #expect(unknown.attach == nil)
        #expect(unknown.latch == nil)
    }

    @Test("late-appearing anamorphic SAR still latches after square frames")
    func lateSARLatches() {
        let square = SoftwareVideoDecoder.sarForAttachment(resolved: rational(1, 1), latched: nil)
        let late = SoftwareVideoDecoder.sarForAttachment(
            resolved: rational(64, 45), latched: square.latch)
        #expect(late.attach?.num == 64)
        #expect(late.latch?.num == 64)
    }
}
