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
