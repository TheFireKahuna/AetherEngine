// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Foundation
import Testing
import Metal
@testable import AetherEngine

/// The enhancement layer is brought to the base-layer grid by Dolby's reference resampling (`dovi_el_*`): the
/// vertical pass first (Catmull-Rom for luma, the (64, 192) pair for chroma, rows centred), then the 8-tap
/// SPATIAL_RESAMPLING_FILTER_H (columns co-sited), each rounded and clipped. These tests run the production composer
/// and read the result back out of the reconstructed 12-bit VDR plane, against the reference as written
/// (`DoviCpuModelTests.Model.upsampledEL`) and against what its taps imply.
@Suite(.offCooperativePoolOneLane, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct DoviEnhancementUpsamplerTests {

    typealias H = DoviGpuCurveSweepTests

    /// BL luma constant 512 (v = 512 << 6), EL luma `elColumn(x)` at half resolution, residual scale 2048: the
    /// 16-bit residual is 16 r - 8 with r = el - 512 (the inverse NLQ), so the 12-bit sample is
    /// (2048 * 16 + 16 r - 8 + 8) >> 4 = 2048 + r for the positive r used here. The first row is returned.
    private func composeLuma(elColumn: (Int) -> Int) throws -> [Int] {
        let composer = try #require(DoviFelComposer.p010ForTesting())
        var p = DoviGpuEdgeCaseTests.params(nlqY: DoviGpuEdgeCaseTests.nlq(vdrInMax: 4095))
        p.ditherMode = .debugRawVDR
        let bl = try #require(H.makeBuffer(width: 64, height: 8))
        let el = try #require(H.makeBuffer(width: 32, height: 4))
        H.fillPlane(bl, plane: 0, components: 1) { _, _, _ in 512 }
        H.fillPlane(bl, plane: 1, components: 2) { _, _, _ in 512 }
        H.fillPlane(el, plane: 0, components: 1) { x, _, _ in elColumn(x) }
        H.fillPlane(el, plane: 1, components: 2) { _, _, _ in 512 }
        let out = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: p))
        return Array(DoviTestSupport.rawVDR(out)[0][0..<64])
    }

    @Test("the columns are co-sited: every even output column is its EL column, untouched by the horizontal filter")
    func evenColumnsAreTheElColumns() throws {
        // Columns differ, rows do not: the vertical pass returns each column's code, and r[2n] = y[n].
        let column: (Int) -> Int = { 600 + ($0 * 37) % 200 }
        let row = try composeLuma(elColumn: column)
        for m in 0..<32 { #expect(row[2 * m] == 2048 + column(m) - 512, "column \(2 * m)") }
    }

    @Test("a linear EL ramp is reproduced exactly at the odd columns: the 8-tap filter is a symmetric half-band")
    func rampIsReproduced() throws {
        // EL column m is 600 + 4m. The odd output 2m + 1 sits half way between m and m + 1: 602 + 4m, exactly,
        // where all eight taps fall inside the row.
        let row = try composeLuma { 600 + 4 * $0 }
        for m in 3..<28 { #expect(row[2 * m + 1] == 2048 + 602 + 4 * m - 512, "column \(2 * m + 1)") }
    }

    @Test("a step in the EL rings by the 8-tap filter's own lobes, and both plateaus are exact")
    func stepRingsByTheTaps() throws {
        // 600 | 700 between EL columns 15 and 16. The odd column 31 sits on the step: (2456 + 2456) / 4096 of each
        // side plus the lobes, so it is the mid value; columns 29 and 33 carry the -524 lobe: an undershoot on the
        // low side and an overshoot on the high side, which the reference taps produce by design.
        let row = try composeLuma { $0 < 16 ? 600 : 700 }
        let lo = 2048 + 600 - 512, hi = 2048 + 700 - 512
        #expect(row[10] == lo)
        #expect(row[53] == hi)
        #expect(row[31] == 2048 + 650 - 512)
        #expect(row[29] < lo, "the low side undershoots")
        #expect(row[33] > hi, "the high side overshoots")
    }

    @Test("EL upsampling: every luma and chroma sample equals the reference, at sizes that leave SIMD lanes past the picture",
          arguments: [(64, 8), (68, 12), (256, 36), (70, 10), (34, 6), (1030, 6)])
    func upsamplingEqualsTheReference(width: Int, height: Int) throws {
        typealias M = DoviCpuModelTests
        let composer = try #require(DoviFelComposer.p010ForTesting())
        // Wide-range NLQ ceiling so the overshoot past 1023 reaches the table, as the inverse NLQ takes it.
        var p = DoviGpuEdgeCaseTests.params(nlqY: DoviGpuEdgeCaseTests.nlq(vdrInMax: 4095),
                                            nlqCb: DoviGpuEdgeCaseTests.nlq(vdrInMax: 4095),
                                            nlqCr: DoviGpuEdgeCaseTests.nlq(vdrInMax: 4095))
        p.ditherMode = .debugRawVDR
        let bl = try #require(H.makeBuffer(width: width, height: height))
        let el = try #require(H.makeBuffer(width: width / 2, height: height / 2))
        func n(_ x: Int, _ y: Int, _ c: Int) -> Int { Int((UInt32(truncatingIfNeeded: (x &* 73_856_093) ^ (y &* 19_349_663) ^ (c &* 83_492_791)) >> 5) % 1024) }
        H.fillPlane(bl, plane: 0, components: 1) { x, y, _ in 300 + (x * 7 + y * 3) % 400 }
        H.fillPlane(bl, plane: 1, components: 2) { x, y, c in 400 + (x * 5 + y * 11 + c * 50) % 200 }
        // Full-range noise with hard steps: the 8-tap filter overshoots both ways, past 1023 and below 0.
        H.fillPlane(el, plane: 0, components: 1) { x, y, _ in (x / 3 + y) % 2 == 0 ? n(x, y, 0) : (x % 5 == 0 ? 1023 : 0) }
        H.fillPlane(el, plane: 1, components: 2) { x, y, c in (x + y) % 3 == 0 ? 1023 : n(x, y, c + 1) }
        let out = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: p))
        let gy = M.plane(out, 0, components: 1), guv = M.plane(out, 1, components: 2)
        let blY = M.plane(bl, 0, components: 1), blUV = M.plane(bl, 1, components: 2)
        let elY = M.plane(el, 0, components: 1), elUV = M.plane(el, 1, components: 2)
        let model = M.Model(p)
        var wrong = 0, overshoot = 0
        for y in 0..<height {
            for x in 0..<width {
                let q = model.lumaParts(bl: blY, blUV: blUV, el: elY, x: x, y: y)
                if q.elCode > 1023 || q.elCode == 0 { overshoot += 1 }
                if model.reconstruct(q.total) != Int(gy.raw[y * width + x] >> 4) { wrong += 1 }
            }
        }
        // Odd sizes included: the chroma planes are half the luma size rounded up, and every sample of them is composed.
        for y in 0..<guv.height {
            for x in 0..<guv.width {
                let (cb, cr) = model.chroma(bl: blY, blUV: blUV, elUV: elUV, x: x, y: y)
                let i = (y * guv.width + x) * 2
                if cb != Int(guv.raw[i] >> 4) || cr != Int(guv.raw[i + 1] >> 4) { wrong += 1 }
            }
        }
        #expect(overshoot > 0, "the fixture reaches the filters' clip and overshoot")
        #expect(wrong == 0, "\(wrong) samples differ from the reference at \(width) x \(height)")
    }

}
#endif
