import Testing
import Foundation
@testable import AetherEngine

struct SubtitleUpscaleTilePlanTests {
    static func plan(_ w: Int, _ h: Int, x: Int = 0, y: Int = 0, model: ArtCNNModel = .c4f16) -> SubtitleUpscaleTilePlan {
        SubtitleUpscaleTilePlan.plan(kept: (x, y, w, h), nanosecondsPerPixel: 2 * SubtitleUpscaleTilePlan.nanosecondsPerPixel(model),
                                     nanosecondsPerCall: 2 * SubtitleUpscaleTilePlan.nanosecondsPerCall)
    }

    @Test("the cores tile the kept area from its corner, each window its core plus the reach, every shape a model's",
          arguments: [(1, 1), (37, 23), (242, 32), (243, 33), (1054, 114), (1526, 157), (1338, 140), (1920, 1080), (3840, 300)])
    func covers(_ w: Int, _ h: Int) {
        let p = Self.plan(w, h, x: 11, y: 5)
        #expect(p.rows.reduce(0, +) >= h && p.columns.reduce(0, +) >= w)
        // No band past the first that covers nothing.
        #expect(p.rows.dropLast().reduce(0, +) < h && p.columns.dropLast().reduce(0, +) < w)
        #expect(p.windows.count == p.rows.count * p.columns.count)
        var y = 5
        for (r, ch) in p.rows.enumerated() {
            var x = 11
            for (c, cw) in p.columns.enumerated() {
                let window = p.windows[r * p.columns.count + c]
                #expect(window == .init(x: x - 7, y: y - 7, width: cw + 14, height: ch + 14))
                #expect(ArtCNNCoreMLModels.windowHeights.contains(window.height) && ArtCNNCoreMLModels.windowWidths.contains(window.width))
                x += cw
            }
            y += ch
        }
    }

    @Test("an empty kept area has no windows")
    func empty() {
        #expect(Self.plan(0, 0).windows.isEmpty && Self.plan(100, 0).windows.isEmpty)
    }

    @Test("a 1920 x 200 strip's kept area runs under two thirds of the window pixels of one fixed 128 x 704 core")
    func fit() {
        let p = Self.plan(1526, 157)
        let pixels = p.windows.reduce(0) { $0 + $1.width * $1.height }
        #expect(pixels * 3 < 611_736 * 2, "\(p.rows) x \(p.columns): \(pixels)")
    }
}
