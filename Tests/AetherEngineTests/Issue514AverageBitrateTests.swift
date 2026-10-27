import Foundation
import Testing
@testable import AetherEngine

/// AE#514: both bitrate fields in `LiveTelemetry` were metered from the reader's transfer counter.
/// Round one fixed the divisor (a pause dragged the average toward zero); round two, from the
/// reporter's retest, fixes the numerator: transfer and playback part ways on every route that reads
/// ahead. VOD prefetch put a 20 Mbps stream at ~35 Mbps, and a paused live session kept draining the
/// origin into its DVR window while the divisor stood still, so its average climbed for as long as the
/// pause ran. Both fields now meter the bytes of the packets the playhead crossed over the media
/// seconds it crossed.
struct Issue514AverageBitrateTests {

    /// 20 Mbps split over a 25 fps video track and a ~47 Hz audio track, recorded as a pump would.
    private static let videoBytesPerSecond = 2_400_000
    private static let audioBytesPerSecond = 100_000
    private static let mbps = Double(videoBytesPerSecond + audioBytesPerSecond) * 8 / 1_000_000

    private static func feed(_ ledger: PlayedMediaLedger, from start: Double, to end: Double) {
        var pts = start
        while pts < end - 1e-9 {
            ledger.record(.video, pts: pts, bytes: videoBytesPerSecond / 25)
            pts += 1.0 / 25
        }
        pts = start
        while pts < end - 1e-9 {
            ledger.record(.audio, pts: pts, bytes: audioBytesPerSecond * 1024 / 48_000)
            pts += 1024.0 / 48_000
        }
    }

    private static func play(_ meter: inout PlayedBitrateMeter, _ ledger: PlayedMediaLedger,
                             from start: Double, seconds: Int) -> Double {
        var playhead = start
        for _ in 0..<seconds {
            playhead += 1
            meter.advance(to: playhead, wallSeconds: 1, ledger: ledger)
        }
        return playhead
    }

    private static func near(_ value: Double?, _ expected: Double, tolerance: Double = 0.05) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= tolerance * expected
    }

    // MARK: - The reporter's table

    /// VOD, playing: minutes of read-ahead sit in the ledger the moment they are fetched, and count
    /// only once the playhead crosses them.
    @Test("VOD read-ahead does not inflate either field")
    func vodReadAheadIsNotCounted() {
        let ledger = PlayedMediaLedger()
        Self.feed(ledger, from: 0, to: 240)
        var meter = PlayedBitrateMeter()
        meter.advance(to: 0, wallSeconds: 0, ledger: ledger)
        _ = Self.play(&meter, ledger, from: 0, seconds: 30)
        #expect(Self.near(meter.averageMbps, Self.mbps))
        #expect(Self.near(meter.instantMbps, Self.mbps))
    }

    /// VOD, paused: the reader keeps topping up the buffer, the playhead does not move.
    @Test("a VOD pause leaves both fields standing")
    func vodPauseFreezes() {
        let ledger = PlayedMediaLedger()
        Self.feed(ledger, from: 0, to: 60)
        var meter = PlayedBitrateMeter()
        meter.advance(to: 0, wallSeconds: 0, ledger: ledger)
        let playhead = Self.play(&meter, ledger, from: 0, seconds: 30)
        let average = meter.averageMbps, instant = meter.instantMbps
        Self.feed(ledger, from: 60, to: 120)
        for _ in 0..<180 { meter.advance(to: playhead, wallSeconds: 1, ledger: ledger) }
        #expect(meter.averageMbps == average)
        #expect(meter.instantMbps == instant)
    }

    /// Live, paused: the pump keeps draining the origin at the broadcast rate for the whole pause
    /// (AE#443). Nothing is played, so nothing may move; on resume the backlog counts as it plays.
    @Test("a live pause does not climb, and the backlog counts at its real rate once played")
    func livePauseDoesNotClimb() {
        let ledger = PlayedMediaLedger()
        var meter = PlayedBitrateMeter()
        var edge = 1_000.0
        Self.feed(ledger, from: edge, to: edge + 2)
        meter.advance(to: edge, wallSeconds: 0, ledger: ledger)
        var playhead = edge
        for _ in 0..<30 {
            edge += 1
            Self.feed(ledger, from: edge + 1, to: edge + 2)
            playhead += 1
            meter.advance(to: playhead, wallSeconds: 1, ledger: ledger)
        }
        let average = meter.averageMbps
        #expect(Self.near(average, Self.mbps))

        for _ in 0..<300 {
            edge += 1
            Self.feed(ledger, from: edge + 1, to: edge + 2)
            meter.advance(to: playhead, wallSeconds: 1, ledger: ledger)
        }
        #expect(meter.averageMbps == average, "five minutes of paused live must not move the average")

        _ = Self.play(&meter, ledger, from: playhead, seconds: 60)
        #expect(Self.near(meter.averageMbps, Self.mbps))
        #expect(Self.near(meter.instantMbps, Self.mbps))
    }

    /// Live, playing: this was right before by accident of the clock, and must stay right.
    @Test("live at the edge reads the broadcast rate")
    func livePlayingReadsTheRate() {
        let ledger = PlayedMediaLedger()
        var meter = PlayedBitrateMeter()
        Self.feed(ledger, from: 50, to: 53)
        meter.advance(to: 50, wallSeconds: 0, ledger: ledger)
        var playhead = 50.0
        for _ in 0..<60 {
            Self.feed(ledger, from: playhead + 3, to: playhead + 4)
            playhead += 1
            meter.advance(to: playhead, wallSeconds: 1, ledger: ledger)
        }
        #expect(Self.near(meter.averageMbps, Self.mbps))
        #expect(Self.near(meter.instantMbps, Self.mbps))
    }

    // MARK: - Seeks

    /// The span a seek jumps over was never played, and the buffer the seek discarded is fetched again:
    /// neither may land in the fields.
    @Test("a seek charges nothing for the jump, and a re-fetched range counts once")
    func seekAndRefetch() {
        let ledger = PlayedMediaLedger()
        Self.feed(ledger, from: 0, to: 120)
        var meter = PlayedBitrateMeter()
        meter.advance(to: 0, wallSeconds: 0, ledger: ledger)
        _ = Self.play(&meter, ledger, from: 0, seconds: 20)
        let secondsBefore = meter.lifetimeSeconds

        // Forward seek to 600: a new range is fetched from there.
        Self.feed(ledger, from: 600, to: 700)
        meter.advance(to: 600, wallSeconds: 1, ledger: ledger)
        #expect(meter.lifetimeSeconds == secondsBefore)
        _ = Self.play(&meter, ledger, from: 600, seconds: 10)

        // Back to 100: the reader delivers 100..200 again, over entries it already held.
        Self.feed(ledger, from: 100, to: 200)
        meter.advance(to: 100, wallSeconds: 1, ledger: ledger)
        _ = Self.play(&meter, ledger, from: 100, seconds: 30)

        #expect(abs(meter.lifetimeSeconds - 60) < 1e-6)
        #expect(Self.near(meter.averageMbps, Self.mbps))
    }

    /// A playhead the ledger holds nothing for (not fed there, or on another axis) is unmeasured.
    @Test("a playhead off the ledger's span publishes nil, never zero")
    func unmeasuredSpanIsNil() {
        let ledger = PlayedMediaLedger()
        Self.feed(ledger, from: 5_000, to: 5_100)
        var meter = PlayedBitrateMeter()
        meter.advance(to: 0, wallSeconds: 0, ledger: ledger)
        _ = Self.play(&meter, ledger, from: 0, seconds: 30)
        #expect(meter.averageMbps == nil)
        #expect(meter.instantMbps == nil)
    }

    // MARK: - The ledger

    @Test("the same packet delivered twice is held once")
    func duplicatePacketOverwrites() {
        let ledger = PlayedMediaLedger()
        ledger.record(.video, pts: 1.0, bytes: 100)
        ledger.record(.video, pts: 1.04, bytes: 100)
        ledger.record(.video, pts: 1.0, bytes: 100)
        #expect(ledger.entryCount == 2)
        #expect(ledger.consume(from: 0, to: 2) == 200)
    }

    @Test("B-frame reorder inserts in place, a re-read from far behind drops what lies ahead")
    func reorderAndReread() {
        let ledger = PlayedMediaLedger()
        for pts in [0.0, 0.12, 0.04, 0.08, 0.24, 0.16, 0.20] { ledger.record(.video, pts: pts, bytes: 10) }
        #expect(ledger.consume(from: 0.04, to: 0.20) == 40)
        ledger.record(.video, pts: 10, bytes: 10)
        ledger.record(.video, pts: 11, bytes: 10)
        ledger.record(.video, pts: 5, bytes: 10)
        #expect(ledger.consume(from: 5, to: 12) == 10, "10 and 11 lie ahead of the re-read and are gone")
    }

    @Test("consuming a span forgets everything before it")
    func consumePrunes() {
        let ledger = PlayedMediaLedger()
        Self.feed(ledger, from: 0, to: 10)
        _ = ledger.consume(from: 4, to: 5)
        #expect(ledger.consume(from: 0, to: 5) == 0)
        #expect(ledger.consume(from: 5, to: 10) > 0)
    }

    // MARK: - The playhead

    @Test("native folds AVPlayer's clock back with the producer's shift; routes without a pump read nil")
    func ledgerPlayheadPerBackend() {
        #expect(LiveTelemetrySampler.ledgerPlayhead(
            backend: .native, nativeClock: 12, playlistShift: 3_600) == 3_612)
        #expect(LiveTelemetrySampler.ledgerPlayhead(
            backend: .native, nativeClock: nil, playlistShift: 3_600) == nil)
        #expect(LiveTelemetrySampler.ledgerPlayhead(
            backend: .audio, nativeClock: 12, playlistShift: 0) == nil)
    }
}
