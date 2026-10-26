import Testing
@testable import AetherEngine

/// Placement by a stream's own clock (`StreamClockPlacement`), on TrueHD's numbers: a 2^16-frame wrap at
/// 48 kHz, and a clock that reads zero 17 104 frames before the stream's start (a library title's).
@Suite("Stream clock placement")
struct StreamClockPlacementTests {

    static let head: Int64 = -17_104
    static let wrap: Int64 = 1 << 16
    static let noise = SourceGrid.noise(tolerance: 49)

    /// The clock of the frame at `position` (48 kHz frames from a stream starting at 0), as the stream states it.
    static func clock(at position: Int64) -> Int64 { ((position - head) % wrap + wrap) % wrap }

    @Test("a frame lands at the stream's start plus the offset plus its clock, whatever its timestamp says")
    func placesByTheClock() {
        var placement = StreamClockPlacement(headOffset: Self.head)
        // An hour in, 1024-frame steps; the first timestamp 96 ms early, the rest up to 112 frames off.
        let start: Int64 = 3_600 * 48_000
        for i: Int64 in 0..<200 {
            let position = start + i * 1024
            let estimate = position + (i == 0 ? -96 * 48 : (i % 7) * 32 - 112)
            #expect(placement.place(clock: Self.clock(at: position), modulus: Self.wrap, scale: 1, origin: 0,
                                    estimate: estimate, noise: Self.noise) == .position(position))
        }
    }

    @Test("a run's first frame needs a timestamp, good to half the wrap, to choose its window")
    func firstFrameWindow() {
        var placement = StreamClockPlacement(headOffset: Self.head)
        let position: Int64 = 3_600 * 48_000
        #expect(placement.place(clock: Self.clock(at: position), modulus: Self.wrap, scale: 1, origin: 0,
                                estimate: nil, noise: Self.noise) == .unplaced)
        #expect(placement.place(clock: Self.clock(at: position), modulus: Self.wrap, scale: 1, origin: 0,
                                estimate: position + Self.wrap / 2 - 1, noise: Self.noise) == .position(position))
    }

    @Test("timestamps that leave the clock for good part it after a run of frames; one stray timestamp does not")
    func partsAtASplice() {
        var placement = StreamClockPlacement(headOffset: Self.head)
        let start: Int64 = 3_600 * 48_000
        var parted: Int64?
        for i: Int64 in 0..<30 {
            let position = start + i * 1024
            // One stray timestamp at frame 5, then the container jumps a second ahead from frame 10.
            let estimate = position + (i == 5 ? 4_800 : i >= 10 ? 48_000 : 0)
            switch placement.place(clock: Self.clock(at: position), modulus: Self.wrap, scale: 1, origin: 0,
                                   estimate: estimate, noise: Self.noise) {
            case .parted(let frames): parted = parted ?? (frames == 48_000 ? i : -1)
            case .position(let p): #expect(p == position)
            case .unplaced: Issue.record("frame \(i) unplaced")
            }
            if placement.parted { break }
        }
        #expect(parted == 10 + Int64(SourceGrid.phaseShiftTimestamps) - 1)
    }

    @Test("a decimated stream's clock and offset are counted at 48 kHz")
    func decimated() {
        // A 96 kHz stream: the clock wraps at 2^15 frames at 48 kHz and its offset halves.
        var placement = StreamClockPlacement(headOffset: 2 * Self.head)
        let position: Int64 = 3_600 * 48_000
        #expect(placement.place(clock: Self.clock(at: position) % (Self.wrap / 2), modulus: Self.wrap / 2, scale: 2,
                                origin: 0, estimate: position + 100, noise: Self.noise) == .position(position))
    }

    @Test("a clock difference is brought into the wrap's window around zero")
    func window() {
        let m = Self.wrap
        #expect(StreamClockPlacement.nearest(0, modulus: m) == 0)
        #expect(StreamClockPlacement.nearest(m + 5, modulus: m) == 5)
        #expect(StreamClockPlacement.nearest(-5, modulus: m) == -5)
        #expect(StreamClockPlacement.nearest(m / 2, modulus: m) == -m / 2)
        #expect(StreamClockPlacement.nearest(m / 2 - 1, modulus: m) == m / 2 - 1)
        #expect(StreamClockPlacement.nearest(-3 * m - 7, modulus: m) == -7)
    }
}
