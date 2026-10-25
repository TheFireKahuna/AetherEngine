import Foundation

/// How the upscaler covers a picture's kept area with the models' fixed windows
/// (``ArtCNNCoreMLModels/windowHeights`` x ``ArtCNNCoreMLModels/windowWidths``). Each window is a core plus the
/// network's 7-pixel reach on every side, so a core's outputs are exact. The cores form a grid: rows of chosen core
/// heights down the kept area, columns of chosen core widths across it, every row with the same columns.
///
/// The Neural Engine's time is close to linear in the window pixels it runs, plus a fixed cost per call (measured on
/// the A15: C4F16 about 7.5 ns per pixel, C4F32 about 17, and about 0.3 ms a call, flat across the shapes). The plan
/// takes, for each count of rows and of columns, the cover with the fewest window rows (and columns), then the
/// pair of counts with the least estimated time. With one fixed 128 x 704 core, a 1920 x 200 strip ran 2.3 times the
/// window pixels this plan runs.
struct SubtitleUpscaleTilePlan: Equatable {
    struct Window: Equatable {
        /// Picture position of the window's top-left pixel: its core's minus 7 on each axis.
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    /// Core heights from the top of the kept area, and core widths from its left.
    var rows: [Int]
    var columns: [Int]
    /// Row-major: window `r * columns.count + c` holds core (r, c).
    var windows: [Window]

    static let reach = 7

    /// Estimated Neural Engine nanoseconds per window pixel of `model`.
    static func nanosecondsPerPixel(_ model: ArtCNNModel) -> Double {
        switch model {
        case .c4f16: 7.5
        case .c4f32: 17
        }
    }

    static let nanosecondsPerCall = 300_000.0

    /// The cheapest grid over `kept` (picture coordinates) for one prediction per window per plane, at
    /// `nanosecondsPerPixel` per window pixel and `nanosecondsPerCall` per window, both planes together.
    static func plan(kept: (x: Int, y: Int, width: Int, height: Int), nanosecondsPerPixel: Double, nanosecondsPerCall: Double) -> Self {
        guard kept.width > 0, kept.height > 0 else { return Self(rows: [], columns: [], windows: []) }
        let rowCovers = covers(kept.height, cores: ArtCNNCoreMLModels.windowHeights.map { $0 - 2 * reach })
        let columnCovers = covers(kept.width, cores: ArtCNNCoreMLModels.windowWidths.map { $0 - 2 * reach })
        var best: (cost: Double, rows: [Int], columns: [Int])?
        for r in rowCovers {
            let rowPixels = r.reduce(0) { $0 + $1 + 2 * reach }
            for c in columnCovers {
                let columnPixels = c.reduce(0) { $0 + $1 + 2 * reach }
                let cost = Double(rowPixels * columnPixels) * nanosecondsPerPixel + Double(r.count * c.count) * nanosecondsPerCall
                if best == nil || cost < best!.cost { best = (cost, r, c) }
            }
        }
        let rows = best!.rows, columns = best!.columns
        var windows: [Window] = []
        var y = kept.y
        for h in rows {
            var x = kept.x
            for w in columns {
                windows.append(Window(x: x - reach, y: y - reach, width: w + 2 * reach, height: h + 2 * reach))
                x += w
            }
            y += h
        }
        return Self(rows: rows, columns: columns, windows: windows)
    }

    /// For each count of cores, the cores (largest first) covering `length` with the least total: `best[n][t]` is the
    /// least total of n cores covering at least t.
    static func covers(_ length: Int, cores: [Int]) -> [[Int]] {
        let maxCount = (length + cores.min()! - 1) / cores.min()!
        var best = [[Int]](repeating: [Int](repeating: .max, count: length + 1), count: maxCount + 1)
        var choice = [[Int]](repeating: [Int](repeating: 0, count: length + 1), count: maxCount + 1)
        best[0][0] = 0
        var result: [[Int]] = []
        for n in 1...maxCount {
            for t in 1...length {
                for core in cores {
                    let before = best[n - 1][max(0, t - core)]
                    guard before != .max, before + core < best[n][t] else { continue }
                    best[n][t] = before + core
                    choice[n][t] = core
                }
            }
            guard best[n][length] != .max else { continue }
            var cover: [Int] = []
            var t = length
            for k in stride(from: n, to: 0, by: -1) {
                let core = choice[k][t]
                cover.append(core)
                t = max(0, t - core)
            }
            result.append(cover.sorted(by: >))
        }
        return result
    }
}
