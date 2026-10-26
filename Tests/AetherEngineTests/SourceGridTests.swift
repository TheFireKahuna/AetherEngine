import Testing
@testable import AetherEngine

/// A run of decoded audio sits on the grid continuous playback puts the stream on, whatever the
/// container rounded and wherever the run began (`SourceGrid`).
@Suite("Source grid")
struct SourceGridTests {

    /// Matroska: a timestamp good to the millisecond, 48 frames at 48 kHz either way.
    static let matroska: Int64 = 49

    @Test("nothing is placed before the run's first timestamp")
    func unplacedWithoutTimestamp() {
        var grid = SourceGrid(origin: 0, step: 512, tolerance: Self.matroska)
        #expect(grid.place(relative: 0, estimate: nil).0 == .unplaced)
        #expect(!grid.isPlacing)
    }

    @Test("an exact timestamp places the run exactly")
    func exact() {
        var grid = SourceGrid(origin: 1_000, step: 40, tolerance: 2)
        #expect(grid.place(relative: 120, estimate: 1_000 + 40 * 777).0 == .position(1_000 + 40 * 777))
        #expect(grid.isResolved)
        #expect(grid.place(relative: 160, estimate: nil).0 == .position(1_000 + 40 * 778))
    }

    @Test("a rounded timestamp lands on the exact DTS frame", arguments: [-24, -16, 0, 9, 24])
    func dtsFrame(rounding: Int64) {
        // Frame 1845 of a stream starting at 74 ms: what a seek into DTSX Emulator.mkv read.
        let origin: Int64 = 74 * 48, frame: Int64 = 1845
        var grid = SourceGrid(origin: origin, step: 512, tolerance: Self.matroska)
        #expect(grid.place(relative: 0, estimate: origin + frame * 512 + rounding).0 == .position(origin + frame * 512))
        #expect(grid.isResolved)
    }

    @Test("the start the lattice is laid from is rounded too, so a timestamp may sit a whole tick off its point",
          arguments: [-96, -48, -16, 0, 32, 48, 96])
    func originRounding(error: Int64) {
        // DTSX Emulator.mkv: start_time 53 ms, its timestamps up to a tick either side of their frames.
        let origin: Int64 = 53 * 48
        var grid = SourceGrid(origin: origin, step: 512, tolerance: Self.matroska)
        _ = grid.place(relative: 0, estimate: origin + 2 * 512 - 16)
        let (placement, restarted) = grid.place(relative: 512, estimate: origin + 3 * 512 + error)
        #expect(!restarted)
        #expect(placement == .position(origin + 3 * 512))
    }

    @Test("TrueHD's 40-frame access unit is pinned by the timestamps that between them rule out its neighbours")
    func trueHDNeedsTwo() {
        var grid = SourceGrid(origin: 0, step: 40, tolerance: Self.matroska)
        // 24 frames past access unit 100: within a timestamp's and the origin's rounding (96) of 99 to 103.
        _ = grid.place(relative: 0, estimate: 100 * 40 + 24)
        #expect(!grid.isResolved)
        // Ten access units later, 96 low: 99 and 100 fit both.
        _ = grid.place(relative: 400, estimate: 110 * 40 - 96)
        #expect(!grid.isResolved)
        // Ten more, 96 high: only 100 fits all three.
        let (placement, restarted) = grid.place(relative: 800, estimate: 120 * 40 + 96)
        #expect(!restarted)
        #expect(grid.isResolved)
        #expect(placement == .position(120 * 40))
        #expect(grid.place(relative: 0, estimate: nil).0 == .position(100 * 40))
    }

    @Test("a timestamp no point of the run allows starts a new run there: a splice")
    func spliceRestarts() {
        var grid = SourceGrid(origin: 0, step: 512, tolerance: Self.matroska)
        _ = grid.place(relative: 0, estimate: 10 * 512)
        let (placement, restarted) = grid.place(relative: 512, estimate: 50 * 512)
        #expect(restarted)
        #expect(placement == .position(50 * 512))
    }

    @Test("a restart forgets the run: the next timestamp places it")
    func restart() {
        var grid = SourceGrid(origin: 0, step: 40, tolerance: 2)
        _ = grid.place(relative: 0, estimate: 400)
        grid.restart()
        #expect(grid.place(relative: 0, estimate: nil).0 == .unplaced)
        #expect(grid.place(relative: 0, estimate: 8_000).0 == .position(8_000))
    }
}

extension SourceGridTests {
    @Test("a cut that moves the frames off the lattice starts a run placed on every frame, until a restart")
    func spliceOffTheLattice() {
        var grid = SourceGrid(origin: 0, step: 1024, tolerance: Self.matroska)
        _ = grid.place(relative: 0, estimate: 10 * 1024)
        // After an edit, frames start 500 frames off the lattice: no lattice point within 25.
        let (placement, restarted) = grid.place(relative: 1024, estimate: 30 * 1024 + 500)
        #expect(restarted)
        #expect(placement == .position(30 * 1024 + 500))
        // Later frames of that run follow on from it.
        #expect(grid.place(relative: 2048, estimate: nil).0 == .position(31 * 1024 + 500))
        // A restart lays the stream's lattice again.
        grid.restart()
        #expect(grid.place(relative: 0, estimate: 40 * 1024 + 9).0 == .position(40 * 1024))
    }
}

/// A long lattice (DTS here): a timestamp picks the frame, and noise short of half a frame never moves a run.
extension SourceGridTests {
    /// A DTS stream at 48 kHz from 53 ms, frame `n`'s exact position.
    static let dtsOrigin: Int64 = 53 * 48
    static func dtsFrame(_ n: Int64) -> Int64 { dtsOrigin + n * 512 }

    /// Frame `n`'s Matroska timestamp from a remux whose timestamps fall behind their frames and snap back:
    /// 32 frames behind per 25 frames, back every 60, then rounded to the millisecond, as measured on a
    /// DTS-HD MA title (up to 112 frames off).
    static func driftingTimestamp(_ n: Int64) -> Int64 {
        let behind = (n % 60) * 32 / 25
        let ms = (Double(dtsFrame(n) - behind) / 48).rounded()
        return Int64(ms) * 48
    }

    @Test("timestamps that drift and snap back, up to 112 frames off, place every frame exactly and never restart")
    func driftingTimestampsHold() {
        var grid = SourceGrid(origin: Self.dtsOrigin, step: 512, tolerance: Self.matroska)
        for n: Int64 in 1_845..<2_245 {
            let (placement, restarted) = grid.place(relative: (n - 1_845) * 512, estimate: Self.driftingTimestamp(n))
            #expect(!restarted, "frame \(n)")
            #expect(placement == .position(Self.dtsFrame(n)), "frame \(n)")
        }
        // The worst measured either way still names its frame.
        #expect(grid.place(relative: 400 * 512, estimate: Self.dtsFrame(2_245) - 112) == (.position(Self.dtsFrame(2_245)), false))
        #expect(grid.place(relative: 401 * 512, estimate: Self.dtsFrame(2_246) + 112) == (.position(Self.dtsFrame(2_246)), false))
    }

    @Test("frames missing from the file: timestamps naming other frames move the run by whole frames, once")
    func wholeFrameCut() {
        var grid = SourceGrid(origin: Self.dtsOrigin, step: 512, tolerance: Self.matroska)
        var restarts = 0
        for i: Int64 in 0..<200 {
            // Three frames are missing after the 100th: the decoder's count runs on, the timestamps jump.
            let n = i < 100 ? i : i + 3
            let (placement, restarted) = grid.place(relative: i * 512, estimate: Self.driftingTimestamp(n))
            if restarted { restarts += 1 }
            #expect(placement == .position(Self.dtsFrame(n)), "frame \(n)")
        }
        #expect(restarts == 1)
    }

    @Test("frames moved off the lattice by less than a frame, beyond the noise, take the new phase after a stretch")
    func subFramePhaseShift() {
        var grid = SourceGrid(origin: Self.dtsOrigin, step: 512, tolerance: Self.matroska)
        var restartedAt: [Int64] = []
        for n: Int64 in 0..<200 {
            let shift: Int64 = n < 100 ? 0 : 200
            let (placement, restarted) = grid.place(relative: n * 512, estimate: Self.dtsFrame(n) + shift)
            if restarted { restartedAt.append(n) }
            if n < 100 + Int64(SourceGrid.phaseShiftTimestamps) - 1 {
                #expect(placement == .position(Self.dtsFrame(n)), "frame \(n)")
            } else {
                #expect(placement == .position(Self.dtsFrame(n) + 200), "frame \(n)")
            }
        }
        #expect(restartedAt == [100 + Int64(SourceGrid.phaseShiftTimestamps) - 1])
    }

    @Test("a shift within the noise is absorbed: the run stays where it is")
    func shiftWithinTheNoise() {
        var grid = SourceGrid(origin: Self.dtsOrigin, step: 512, tolerance: Self.matroska)
        for n: Int64 in 0..<200 {
            let (placement, restarted) = grid.place(relative: n * 512, estimate: Self.dtsFrame(n) + (n < 100 ? 0 : 100))
            #expect(!restarted)
            #expect(placement == .position(Self.dtsFrame(n)))
        }
    }

    @Test("a copied packet's timestamp names its frame within the noise on a long lattice; beyond it, it is the position")
    func copiedPacketOnALongLattice() {
        let point = Self.dtsFrame(1_000)
        for error: Int64 in [-112, -96, 0, 112, 147] {
            #expect(SourceGrid.position(estimate: point + error, origin: Self.dtsOrigin, lattice: 512, tolerance: Self.matroska) == point)
        }
        #expect(SourceGrid.position(estimate: point + 200, origin: Self.dtsOrigin, lattice: 512, tolerance: Self.matroska) == point + 200)
        // E-AC-3's 256-frame block is no long lattice on Matroska: a rounded timestamp's span as before.
        #expect(!SourceGrid.isLong(lattice: 256, tolerance: Self.matroska))
        #expect(SourceGrid.position(estimate: 256 * 40 + 120, origin: 0, lattice: 256, tolerance: Self.matroska) == 256 * 40 + 120)
    }

    @Test("on a sample-exact container every lattice is long, TrueHD's included")
    func sampleExactContainer() {
        #expect(SourceGrid.isLong(lattice: 40, tolerance: 2))
        var grid = SourceGrid(origin: 0, step: 40, tolerance: 2)
        #expect(grid.place(relative: 0, estimate: 40 * 777 + 3) == (.position(40 * 777), false))
    }
}
