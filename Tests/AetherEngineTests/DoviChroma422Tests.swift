// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import CoreVideo
@testable import AetherEngine

/// sv22 chroma: composed at the 4:2:0 sites, where the reconstruction is defined, then brought to 4:2:2 by the
/// reference vertical chroma filter on the reconstructed picture (`dovi_chroma_420_to_422`). Checked against the CPU model
/// (`DoviCpuModelTests.Model.chroma422Sum`) and against the 4:2:0 composition itself, which every on-site row equals.
@Suite(.offCooperativePoolOneLane)
struct DoviChroma422Tests {

    typealias H = DoviGpuCurveSweepTests
    typealias M = DoviCpuModelTests

    /// The real RPU parameter sets with MMR chroma (clip A, clip C, fel_orig), residual enabled.
    static func realParams() -> [(String, DoviMetalParams)] {
        M.realMmrParams().filter { !$0.0.hasPrefix("fel_1584") }.map { name, p in
            var q = p
            q.flags.remove(.disableResidual)
            return (name, q)
        }
    }

    /// One `AVChromaLocation` per vertical siting: LEFT (between rows 2k and 2k + 1), TOPLEFT (on row 2k),
    /// BOTTOMLEFT (on row 2k + 1).
    static let sitings: [UInt32] = [1, 3, 5]
    /// Every value the kernel distinguishes, UNSPECIFIED and the horizontally shifted twins included.
    static let allLocations: [UInt32] = [0, 1, 2, 3, 4, 5, 6]

    /// Cheap deterministic noise in [-16, 16].
    static func n(_ x: Int, _ y: Int) -> Int { Int((UInt32(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663) >> 7) % 33) - 16 }

    /// BL and EL buffers filled from closures of (column, row, component), EL at half the BL size.
    static func buffers(width: Int, height: Int, bl: (Int, Int, Int) -> Int, blUV: (Int, Int, Int) -> Int,
                        el: (Int, Int, Int) -> Int, elUV: (Int, Int, Int) -> Int) throws -> (CVPixelBuffer, CVPixelBuffer) {
        let b = try #require(H.makeBuffer(width: width, height: height))
        let e = try #require(H.makeBuffer(width: width / 2, height: height / 2))
        H.fillPlane(b, plane: 0, components: 1, bl)
        H.fillPlane(b, plane: 1, components: 2, blUV)
        H.fillPlane(e, plane: 0, components: 1, el)
        H.fillPlane(e, plane: 1, components: 2, elUV)
        return (b, e)
    }

    /// sv22 compose.
    static func sv22(_ bl: CVPixelBuffer, _ el: CVPixelBuffer, _ p: DoviMetalParams) throws -> CVPixelBuffer {
        let composer = try #require(DoviFelComposer())
        composer.outputModeOverride = .sv22
        let out = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: p, frameIndex: 0))
        #expect(CVPixelBufferGetHeightOfPlane(out, 1) == CVPixelBufferGetHeight(out))
        return out
    }

    /// The 4:2:0 composition as full-precision words (P010, `dovi_full_precision`): the same clamp sv22 applies, so
    /// an sv22 row on a chroma row must equal it word for word.
    static func composed420(_ bl: CVPixelBuffer, _ el: CVPixelBuffer, _ p: DoviMetalParams) throws -> M.Plane {
        let composer = try #require(DoviFelComposer())
        composer.outputModeOverride = .p010FullPrecision
        return M.plane(try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: p, frameIndex: 0)), 1, components: 2)
    }

    /// The model's 16-bit sum as the sv22 word (`dovi_full_precision`: h clipped as the 12-bit reconstruction is).
    static func word(_ h: Int) -> Int { min(max(h, 0), M.Model.sumMax(vdrMax: 4095)) }

    @Test("sv22 4:2:2-site chroma: the GPU matches the CPU model on real RPU coefficient sets",
          arguments: DoviChroma422Tests.realParams().map(\.0), DoviChroma422Tests.sitings)
    func gpuMatchesModel(name: String, location: UInt32) throws {
        var p = try #require(Self.realParams().first { $0.0 == name }).1
        p.blChromaLocation = location
        let (w, h) = (256, 64)
        // A luma ramp with grain, chroma swept around neutral down the rows and across, an EL of +-40 codes.
        let (bl, el) = try Self.buffers(width: w, height: h,
            bl: { x, y, _ in 64 + x * 876 / w + Self.n(x, y) },
            blUV: { x, y, c in 512 + (c == 0 ? x * 300 / (w / 2) - 150 : y * 300 / (h / 2) - 150) + 3 * Self.n(y, x) },
            el: { x, y, _ in 512 + Self.n(x, y) * 40 / 16 },
            elUV: { x, y, _ in 512 + Self.n(y, x) * 20 / 16 })
        let out = try Self.sv22(bl, el, p)
        let model = M.Model(p)
        let blP = M.plane(bl, 0, components: 1), blUV = M.plane(bl, 1, components: 2)
        let elUV = M.plane(el, 1, components: 2), g = M.plane(out, 1, components: 2)
        var cb = M.Stat(), cr = M.Stat()
        for row in 0..<h {
            for x in 0..<(w / 2) {
                let (mcb, mcr) = model.chroma422Sum(bl: blP, blUV: blUV, elUV: elUV, x: x, row: row)
                cb.add(Self.word(mcb) - Int(g.word(x, row, 0)))
                cr.add(Self.word(mcr) - Int(g.word(x, row, 1)))
            }
        }
        print("[422] \(name) loc \(location): Cb \(cb.description)")
        print("[422] \(name) loc \(location): Cr \(cr.description)")
        // Both sides are the reference's integer arithmetic on the same inputs: the 16-bit words agree exactly.
        for (label, st) in [("Cb", cb), ("Cr", cr)] {
            #expect(st.exact == st.n, "\(label): \(st.description)")
        }
    }

    @Test("a frame with an MMR piece too large for the float-pinned high word takes the exact pipelines, a frame without the estimate ones, and both equal the reference",
          arguments: [(Int32(1) << 29, true), (Int32(1) << 25, false)])
    func mmrBothPathsEqualTheReference(cbCoefficient: Int32, exact: Bool) throws {
        // Cb = c * (u - 1/2) + 1/2 at Q23. At c = 2^29 its |coefficient * term| sum is 2^29 * 2^20 + (2^28 - 2^22) * 2^20,
        // over the 2^49 bound, so the frame cannot pin the high word from the estimate; at c = 2^25 it is inside the
        // bound. Cr is the same curve at c = 2^25 in both frames.
        var p = DoviGpuEdgeCaseTests.params(flags: [.disableResidual])
        for (comp, c) in [(0, cbCoefficient), (1, Int32(1) << 25)] {
            var poly = DoviPolynomialParams()
            poly.numPivots = 2; poly.pivots[0] = 0; poly.pivots[1] = 1023
            poly.method[0] = DoviMapping.mmr.rawValue; poly.order[0] = 1; poly.coefShift[0] = 23
            var mmr = DoviMmrParams()
            mmr.coefShift = 23
            mmr.coef[0][1 + comp] = c                       // the component's own term, u or v
            mmr.constant[0] = (1 << 22) - c / 2             // 1/2 - c / 2
            if comp == 0 { (p.polyCb, p.mmrCb) = (poly, mmr) } else { (p.polyCr, p.mmrCr) = (poly, mmr) }
        }
        var table = [Int32](repeating: 0, count: DoviFelComposer.mmrTableCount)
        #expect(DoviFelComposer.populateMmrTable(into: &table, params: p) == exact,
                exact ? "over the bound: the exact pipelines" : "within it: the estimate pipelines")

        let (w, h) = (128, 32)
        let (bl, el) = try Self.buffers(width: w, height: h,
            bl: { x, y, _ in 64 + (7 * x + 3 * y) % 800 }, blUV: { x, y, _ in 500 + (x + 3 * y) % 25 },
            el: { _, _, _ in 512 }, elUV: { _, _, _ in 512 })
        let out = M.plane(try Self.sv22(bl, el, p), 1, components: 2)
        let model = M.Model(p)
        let blP = M.plane(bl, 0, components: 1), blUV = M.plane(bl, 1, components: 2), elUV = M.plane(el, 1, components: 2)
        var cb = M.Stat(), cr = M.Stat(), spread = Set<Int>()
        for row in 0..<h {
            for x in 0..<(w / 2) {
                let (mcb, mcr) = model.chroma422Sum(bl: blP, blUV: blUV, elUV: elUV, x: x, row: row)
                cb.add(Self.word(mcb) - Int(out.word(x, row, 0)))
                cr.add(Self.word(mcr) - Int(out.word(x, row, 1)))
                spread.insert(Int(out.word(x, row, 0)))
            }
        }
        #expect(spread.count > 20, "the steep Cb curve spans many output words, not a clamp")
        #expect(cb.exact == cb.n, "Cb: \(cb.description)")
        #expect(cr.exact == cr.n, "Cr: \(cr.description)")
    }

    @Test("on flat luma and flat chroma every 4:2:2 row is the 4:2:0 composition")
    func flatFieldIsTheComposition() throws {
        let sets = [("identity", DoviGpuEdgeCaseTests.params())] + Self.realParams()
        for (name, p) in sets {
            let (bl, el) = try Self.buffers(width: 64, height: 16,
                bl: { _, _, _ in 500 }, blUV: { _, _, c in c == 0 ? 600 : 450 },
                el: { _, _, _ in 520 }, elUV: { _, _, c in c == 0 ? 505 : 515 })
            let out = M.plane(try Self.sv22(bl, el, p), 1, components: 2)
            let ref = try Self.composed420(bl, el, p)
            #expect(Set(out.raw) == Set(ref.raw), "\(name): flat-field sv22 chroma differs from the 4:2:0 composition")
        }
    }

    @Test("on real titles every sv22 row on a chroma row is the 4:2:0 composition, word for word",
          .enabled(if: !DoviFelRealFileTests.availableFixtures.isEmpty, DoviFelRealFileTests.needsClips),
          arguments: DoviFelRealFileTests.availableFixtures)
    func onSiteRowsOnRealTitles(name: String) throws {
        let rec = try #require(DoviFelRealFileTests.RecordingComposer(limit: 4, stride: 40))
        let s = try DoviFelRealFileTests.open(name, composer: rec)
        defer { s.decoder.close(); s.demuxer.close() }
        DoviFelRealFileTests.feed(s, count: 200)
        s.decoder.flush()
        try #require(!rec.captures.isEmpty, "no frames reached the composer")
        var n = 0, differ = 0
        for cap in rec.captures {
            let loc = cap.params.blChromaLocation
            try #require(loc == 3 || loc == 4, "these titles signal type 2 / 3 siting (AVChromaLocation \(loc))")
            let out = M.plane(try Self.sv22(cap.bl, cap.el, cap.params), 1, components: 2)
            let ref = try Self.composed420(cap.bl, cap.el, cap.params)
            for k in 0..<ref.height {
                for x in 0..<ref.width {
                    for c in 0..<2 {
                        n += 1
                        if out.raw[(2 * k * out.width + x) * 2 + c] != ref.raw[(k * ref.width + x) * 2 + c] { differ += 1 }
                    }
                }
            }
        }
        #expect(n > 0 && differ == 0, "\(name): \(differ) of \(n) on-site samples differ from the 4:2:0 composition")
    }

    @Test("top and bottom rows clamp to the edge chroma rows: exact against the model, no out-of-bounds reads",
          arguments: [16, 4], DoviChroma422Tests.allLocations)
    func edgeRowsClamp(height: Int, location: UInt32) throws {
        // Identity curves are exact on the interpolated fraction (n / 128 codes, times 64 in the 16-bit sum), so
        // every sample must match exactly; an out-of-range row read as 0 would pull the edge rows far down.
        var p = DoviGpuEdgeCaseTests.params()
        p.blChromaLocation = location
        let (bl, el) = try Self.buffers(width: 64, height: height,
            bl: { x, y, _ in 400 + 7 * x + 11 * y }, blUV: { x, y, c in c == 0 ? 900 - 37 * y + x : 120 + 41 * y + x },
            el: { _, _, _ in 512 }, elUV: { x, y, c in 512 + (c == 0 ? 3 * y - x % 5 : 2 * x % 7 - y) })
        let out = M.plane(try Self.sv22(bl, el, p), 1, components: 2)
        let model = M.Model(p)
        let blP = M.plane(bl, 0, components: 1), blUV = M.plane(bl, 1, components: 2), elUV = M.plane(el, 1, components: 2)
        var mismatches = 0
        for row in 0..<height {
            for x in 0..<32 {
                let (mcb, mcr) = model.chroma422Sum(bl: blP, blUV: blUV, elUV: elUV, x: x, row: row)
                if Self.word(mcb) != Int(out.word(x, row, 0)) || Self.word(mcr) != Int(out.word(x, row, 1)) {
                    mismatches += 1
                }
            }
        }
        #expect(mismatches == 0, "\(mismatches) samples differ from the model at height \(height), location \(location)")
    }

    @Test("top / bottom siting: the row on the chroma site is the 4:2:0 composition bit for bit, the other half way",
          arguments: [UInt32(3), 4, 5, 6])
    func onSiteRowsAreTheFourTwoZeroComposition(location: UInt32) throws {
        var (name, p) = try #require(Self.realParams().first { $0.0 == "clip C" })
        p.blChromaLocation = location
        // Luma, chroma and the EL vary in both directions, with grain.
        let (w, h) = (64, 32)
        let (bl, el) = try Self.buffers(width: w, height: h,
            bl: { x, y, _ in 200 + 9 * x + 5 * y + Self.n(y, x) }, blUV: { x, y, c in 512 + (c == 0 ? 11 * y - 90 : 60 - 7 * y) + Self.n(x, y) },
            el: { x, y, _ in 512 + Self.n(x, y) * 40 / 16 }, elUV: { x, y, _ in 512 + Self.n(y, x) * 20 / 16 })
        let new = M.plane(try Self.sv22(bl, el, p), 1, components: 2)
        let ref = try Self.composed420(bl, el, p)
        let onSite = location <= 4 ? 0 : 1
        var differ = 0
        for row in stride(from: onSite, to: h, by: 2) {
            let k = row / 2
            for x in 0..<(w / 2) where new.word(x, row, 0) != ref.word(x, k, 0) || new.word(x, row, 1) != ref.word(x, k, 1) {
                differ += 1
            }
        }
        #expect(differ == 0, "\(name) location \(location): \(differ) on-site samples differ from the 4:2:0 composition")

        // The other rows sit half way between two chroma rows: (-4, 36, 36, -4) / 64 on the composed sums.
        // Identity curves and no residual make each sum 64 x its chroma code, so the row is exactly
        // -4 c[k - 1] + 36 c[k] + 36 c[k + 1] - 4 c[k + 2].
        var q = DoviGpuEdgeCaseTests.params(flags: [.disableResidual])
        q.blChromaLocation = location
        let ident = M.plane(try Self.sv22(bl, el, q), 1, components: 2)
        let blUV = M.plane(bl, 1, components: 2)
        func c(_ x: Int, _ r: Int, _ comp: Int) -> Double { Double(blUV.code(x, min(max(r, 0), h / 2 - 1), comp)) }
        var wrong = 0
        for row in stride(from: 1 - onSite, to: h, by: 2) {
            let k = onSite == 0 ? row / 2 : row / 2 - 1   // halfway between chroma rows k and k + 1
            for x in 0..<(w / 2) {
                for comp in 0..<2 {
                    let h = Int(-4 * c(x, k - 1, comp) + 36 * c(x, k, comp) + 36 * c(x, k + 1, comp) - 4 * c(x, k + 2, comp))
                    if Self.word(h) != Int(ident.word(x, row, comp)) { wrong += 1 }
                }
            }
        }
        #expect(wrong == 0, "location \(location): \(wrong) half-way samples off the reference value")
    }
}
#endif
