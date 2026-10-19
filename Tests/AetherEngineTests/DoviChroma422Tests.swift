// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import CoreVideo
@testable import AetherEngine

/// sv22 chroma composed at every 4:2:2 site (`dovi_compose_chroma_422`): luma from that row alone, the 4:2:0 BL
/// chroma brought to the row by a Catmull-Rom at phase 1/4 or 3/4 and reshaped as a fraction, the EL read at the
/// same row coordinate. Checked against the CPU model (`DoviCpuModelTests.Model.chroma422`), against the old
/// row-duplicated output where the two must agree (flat fields) and where they must not (a luma edge between
/// the two rows of a 4:2:0 cell).
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

    /// sv22 compose; `duplicated` takes the 4:2:0 kernel with its rows repeated, as before the 4:2:2 kernel.
    static func sv22(_ bl: CVPixelBuffer, _ el: CVPixelBuffer, _ p: DoviMetalParams, duplicated: Bool = false) throws -> CVPixelBuffer {
        let composer = try #require(DoviFelComposer())
        composer.outputModeOverride = .sv22
        composer.sv22RowDuplicationForTesting = duplicated
        let out = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: p, frameIndex: 0))
        #expect(CVPixelBufferGetHeightOfPlane(out, 1) == CVPixelBufferGetHeight(out))
        return out
    }

    /// The model's clamped VDR as the sv22 full-precision word (`dovi_full_precision`, chroma 64...960).
    static func word(_ vdr: Int, _ p: DoviMetalParams) -> Int {
        let s = Int(p.vdrScale)
        return min(max((vdr * 64 + s / 2) / s, 64 << 6), 960 << 6)
    }

    @Test("sv22 4:2:2-site chroma: the GPU matches the CPU model on real RPU coefficient sets",
          arguments: DoviChroma422Tests.realParams().map(\.0))
    func gpuMatchesModel(name: String) throws {
        let p = try #require(Self.realParams().first { $0.0 == name }).1
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
        let unit = 64 / Int(p.vdrScale)   // full-precision word steps per VDR code
        for row in 0..<h {
            for x in 0..<(w / 2) {
                let (mcb, mcr) = model.chroma422(bl: blP, blUV: blUV, elUV: elUV, x: x, row: row)
                cb.add((Self.word(mcb, p) - Int(g.word(x, row, 0))) / unit)
                cr.add((Self.word(mcr, p) - Int(g.word(x, row, 1))) / unit)
            }
        }
        print("[422] \(name): Cb \(cb.description)")
        print("[422] \(name): Cr \(cr.description)")
        for (label, st) in [("Cb", cb), ("Cr", cr)] {
            #expect(st.over1Pct < 0.5, "\(label): \(st.description)")
            #expect(st.exactPct > 90, "\(label): \(st.description)")
        }
    }

    @Test("on flat luma and flat chroma the 4:2:2-site result is the 4:2:0 result on both rows")
    func flatFieldMatchesDuplicated() throws {
        let sets = [("identity", DoviGpuEdgeCaseTests.params())] + Self.realParams()
        for (name, p) in sets {
            let (bl, el) = try Self.buffers(width: 64, height: 16,
                bl: { _, _, _ in 500 }, blUV: { _, _, c in c == 0 ? 600 : 450 },
                el: { _, _, _ in 520 }, elUV: { _, _, c in c == 0 ? 505 : 515 })
            let new = M.plane(try Self.sv22(bl, el, p), 1, components: 2)
            let old = M.plane(try Self.sv22(bl, el, p, duplicated: true), 1, components: 2)
            #expect(new.raw == old.raw, "\(name): flat-field sv22 chroma differs from the 4:2:0 result")
        }
    }

    @Test("a sharp luma edge between rows 2k and 2k + 1 under order-3 MMR chroma gives the two rows different chroma")
    func lumaEdgeSplitsTheCell() throws {
        // Order-3 MMR chroma whose luma terms are live: Cb = u + 0.25 y^3, Cr = v - 0.5 (yv)^2. Clip A's order-3
        // sets are no use here: on flat chroma their luma terms cancel (the same Cb for luma 100 ... 900).
        var p = DoviGpuEdgeCaseTests.params(flags: [.disableResidual])
        for (comp, terms) in [(0, [(1, 1.0), (14, 0.25)]), (1, [(2, 1.0), (11, -0.5)])] {
            var poly = DoviPolynomialParams()
            poly.numPivots = 2; poly.pivots[0] = 0; poly.pivots[1] = 1023
            poly.method[0] = DoviMapping.mmr.rawValue; poly.order[0] = 3; poly.coefShift[0] = 23
            var mmr = DoviMmrParams()
            mmr.coefShift = 23
            for (t, v) in terms { mmr.coef[0][t] = Int32(v * Double(1 << 23)) }
            if comp == 0 { (p.polyCb, p.mmrCb) = (poly, mmr) } else { (p.polyCr, p.mmrCr) = (poly, mmr) }
        }
        // Rows 0...16 dark, 17... bright: the edge runs through chroma cell 8 (rows 16 and 17).
        let (bl, el) = try Self.buffers(width: 64, height: 32,
            bl: { _, y, _ in y <= 16 ? 300 : 700 }, blUV: { _, _, c in c == 0 ? 600 : 420 },
            el: { _, _, _ in 512 }, elUV: { _, _, _ in 512 })
        let new = M.plane(try Self.sv22(bl, el, p), 1, components: 2)
        let old = M.plane(try Self.sv22(bl, el, p, duplicated: true), 1, components: 2)
        let model = M.Model(p)
        let blP = M.plane(bl, 0, components: 1), blUV = M.plane(bl, 1, components: 2), elUV = M.plane(el, 1, components: 2)
        for x in 0..<32 {
            #expect(old.word(x, 16, 0) == old.word(x, 17, 0), "the duplicated rows were identical")
            #expect(new.word(x, 16, 0) != new.word(x, 17, 0) || new.word(x, 16, 1) != new.word(x, 17, 1),
                    "x \(x): rows 16 and 17 share their chroma")
            for row in [16, 17] {
                let (mcb, mcr) = model.chroma422(bl: blP, blUV: blUV, elUV: elUV, x: x, row: row)
                #expect(abs(Self.word(mcb, p) - Int(new.word(x, row, 0))) <= 16, "Cb (\(x), \(row))")
                #expect(abs(Self.word(mcr, p) - Int(new.word(x, row, 1))) <= 16, "Cr (\(x), \(row))")
            }
        }
        print("[422] edge: Cb words row 16 \(Int(new.word(5, 16, 0))) row 17 \(Int(new.word(5, 17, 0))), duplicated \(Int(old.word(5, 16, 0)))")
    }

    @Test("top and bottom rows clamp to the edge chroma rows: exact against the model, no out-of-bounds reads",
          arguments: [16, 4])
    func edgeRowsClamp(height: Int) throws {
        // Identity curves are exact on the interpolated fraction (n / 128 codes times 4), so every sample must
        // match exactly; an out-of-range row read as 0 would pull the edge rows far down.
        let p = DoviGpuEdgeCaseTests.params()
        let (bl, el) = try Self.buffers(width: 64, height: height,
            bl: { x, y, _ in 400 + 7 * x + 11 * y }, blUV: { x, y, c in c == 0 ? 900 - 37 * y + x : 120 + 41 * y + x },
            el: { _, _, _ in 512 }, elUV: { x, y, c in 512 + (c == 0 ? 3 * y - x % 5 : 2 * x % 7 - y) })
        let out = M.plane(try Self.sv22(bl, el, p), 1, components: 2)
        let model = M.Model(p)
        let blP = M.plane(bl, 0, components: 1), blUV = M.plane(bl, 1, components: 2), elUV = M.plane(el, 1, components: 2)
        var mismatches = 0
        for row in 0..<height {
            for x in 0..<32 {
                let (mcb, mcr) = model.chroma422(bl: blP, blUV: blUV, elUV: elUV, x: x, row: row)
                if Self.word(mcb, p) != Int(out.word(x, row, 0)) || Self.word(mcr, p) != Int(out.word(x, row, 1)) {
                    mismatches += 1
                }
            }
        }
        #expect(mismatches == 0, "\(mismatches) samples differ from the model at height \(height)")
    }

    /// How far the 4:2:2-site rows move from the old duplicated rows on real content. A diagnostic, not a
    /// check: set DV_FEL_TESTS_DIR to a folder and DOVI_422_DIAG to comma-separated file names in it.
    @Test("diagnostic: 4:2:2-site rows against the duplicated rows on a real clip",
          .enabled(if: ProcessInfo.processInfo.environment["DOVI_422_DIAG"] != nil, "set DOVI_422_DIAG"),
          arguments: (ProcessInfo.processInfo.environment["DOVI_422_DIAG"] ?? "").split(separator: ",").map(String.init))
    func diagnosticAgainstDuplicated(name: String) throws {
        let rec = try #require(DoviFelRealFileTests.RecordingComposer(limit: 6, stride: 40))
        let s = try DoviFelRealFileTests.open(name, composer: rec)
        defer { s.decoder.close(); s.demuxer.close() }
        DoviFelRealFileTests.feed(s, count: 300)
        s.decoder.flush()
        var n = 0, sum = 0.0, maxAbs = 0, changed = 0, meanNew = [0.0, 0.0], meanOld = [0.0, 0.0]
        for cap in rec.captures {
            let new = M.plane(try Self.sv22(cap.bl, cap.el, cap.params), 1, components: 2)
            let old = M.plane(try Self.sv22(cap.bl, cap.el, cap.params, duplicated: true), 1, components: 2)
            for i in 0..<new.raw.count {
                let d = abs(Int(new.raw[i]) - Int(old.raw[i]))
                n += 1; sum += Double(d); maxAbs = max(maxAbs, d); if d != 0 { changed += 1 }
                meanNew[i & 1] += Double(new.raw[i]); meanOld[i & 1] += Double(old.raw[i])
            }
        }
        try #require(n > 0, "no frames reached the composer")
        let half = Double(n / 2) * 64
        print(String(format: "[422diag] %@: %d frames, |new - duplicated| mean %.4f max %.3f (10-bit codes), %.2f%% of samples changed; mean Cb %.3f -> %.3f, Cr %.3f -> %.3f",
                     name, rec.captures.count, sum / Double(n) / 64, Double(maxAbs) / 64, 100 * Double(changed) / Double(n),
                     meanOld[0] / half, meanNew[0] / half, meanOld[1] / half, meanNew[1] / half))
    }
}
#endif
