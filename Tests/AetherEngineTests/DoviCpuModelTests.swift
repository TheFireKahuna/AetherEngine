// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import CoreVideo
import Dovi
@testable import AetherEngine

/// M8: an independent model of the composition, written from the RPU syntax and the reshaping
/// equations rather than from the shader, and compared with the GPU on frames captured from real
/// titles. The real titles carry what synthetic test content cannot produce (multi-piece luma curves,
/// MMR chroma, large NLQ scales), so this is the check on those paths.
///
/// The model is ETSI GS CCM 001's pseudo-code ported line for line (5.4.2.2 pivots, 5.4.2.3.2 polynomial with
/// `ss` / `shift`, 5.4.2.3.3 MMR with `tt[0...21]`, 5.4.3.2 NLQ, 5.4.3.3 reconstruction), not the kernels' own
/// arrangement of it, and samples the enhancement layer with its own bilinear filter. It compares the spec's
/// 12-bit reconstructed sample (`DoviDither.debugRawVDR`), which both sides compute in integers, so they agree
/// exactly or not at all.
///
/// What it settles: arithmetic, piece selection, MMR term layout, NLQ, clamps. What it cannot: the
/// spec readings the shader and the model share by construction (the chroma-site luma filter, the
/// half-step NLQ reconstruction); those were settled against DoViBaker, an independent implementation.
@Suite(.offCooperativePoolOneLane)
struct DoviCpuModelTests {

    // MARK: - Planes

    /// One P010 plane as 10-bit codes, `components` interleaved samples per pixel.
    struct Plane {
        let width: Int, height: Int, components: Int
        let raw: [UInt16]
        func code(_ x: Int, _ y: Int, _ c: Int = 0) -> Int {
            Int(raw[(y * width + x) * components + c] >> 6)
        }
        /// Raw 16-bit word.
        func word(_ x: Int, _ y: Int, _ c: Int = 0) -> Double {
            Double(raw[(y * width + x) * components + c])
        }
    }

    static func plane(_ b: CVPixelBuffer, _ index: Int, components: Int) -> Plane {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(b, index), h = CVPixelBufferGetHeightOfPlane(b, index)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(b, index) / 2
        let base = CVPixelBufferGetBaseAddressOfPlane(b, index)!.assumingMemoryBound(to: UInt16.self)
        var out = [UInt16](); out.reserveCapacity(w * h * components)
        for y in 0..<h { for x in 0..<(w * components) { out.append(base[y * stride + x]) } }
        return Plane(width: w, height: h, components: components, raw: out)
    }

    // MARK: - The model

    struct Model {
        let p: DoviMetalParams
        /// BL_bit_depth.
        let bd: Int

        init(_ p: DoviMetalParams) {
            self.p = p
            bd = DoviFelComposer.bitDepth(ofMax: p.blMax)
        }

        /// 5.4.2.2: the first piece whose next pivot is above `s`, or one past the pieces. Past the last pivot the
        /// sample is clamped to that pivot, so the last piece is the one evaluated.
        func piece(_ c: DoviPolynomialParams, _ s: Int) -> Int {
            let n = Int(c.numPivots) - 2
            var idx = n + 1
            for i in 0..<(n + 1) where s < Int(c.pivots[i + 1]) { idx = i; break }
            return min(idx, n)
        }

        /// The same for a Q20 value (4:2:2 chroma, interpolated between codes).
        func piece(_ c: DoviPolynomialParams, q20 t: Int64) -> Int {
            let n = Int(c.numPivots) - 2
            var idx = n + 1
            for i in 0..<(n + 1) where t < Int64(c.pivots[i + 1]) << (20 - bd) { idx = i; break }
            return min(idx, n)
        }

        /// The end of 5.4.2.3.2 and 5.4.2.3.3: negative to 0, `>> (4 + coefficient_log2_denom)`, capped at 0xffff.
        static func v16(_ vv: Int64, _ denom: UInt32) -> Int { Int(min(max(vv, 0) >> (4 + Int64(denom)), 0xffff)) }

        /// 5.4.2.3.2 as the spec writes it, for an integer base-layer sample.
        func polynomial(_ c: DoviPolynomialParams, _ k: Int, s input: Int) -> (vv: Int64, v: Int) {
            var s = Int64(input)
            if s < Int64(c.pivots[0]) { s = Int64(c.pivots[0]) }
            if s > Int64(c.pivots[Int(c.numPivots) - 1]) { s = Int64(c.pivots[Int(c.numPivots) - 1]) }
            var ss: Int64 = 1
            var shift = 20
            var vv: Int64 = 0
            for i in 0...min(Int(c.order[k]), 2) {   // order = poly_order_minus1 + 1, at most 2
                vv += Int64(c.coef[k][i]) * (ss << shift)
                ss *= s
                shift -= bd
            }
            return (vv, Self.v16(vv, c.coefShift[k]))
        }

        /// 5.4.2.3.3 as the spec writes it (tt[0...21]), for integer samples, each already clamped to its pivots.
        func mmr(_ m: DoviMmrParams, _ k: Int, order: Int, s0: Int64, s1: Int64, s2: Int64) -> (vv: Int64, v: Int) {
            var tt = [Int64](repeating: 0, count: 22)
            tt[0] = 1 << 20
            if order >= 1 {
                tt[1] = s0 << (20 - bd); tt[2] = s1 << (20 - bd); tt[3] = s2 << (20 - bd)
                tt[4] = (s0 * s1) << (20 - 2 * bd); tt[5] = (s0 * s2) << (20 - 2 * bd); tt[6] = (s1 * s2) << (20 - 2 * bd)
                tt[7] = (tt[4] * tt[3]) >> 20
            }
            if order >= 2 {
                tt[8] = (s0 * s0) << (20 - 2 * bd); tt[9] = (s1 * s1) << (20 - 2 * bd); tt[10] = (s2 * s2) << (20 - 2 * bd)
                tt[11] = (tt[4] * tt[4]) >> 20; tt[12] = (tt[5] * tt[5]) >> 20
                tt[13] = (tt[6] * tt[6]) >> 20; tt[14] = (tt[7] * tt[7]) >> 20
            }
            if order >= 3 {
                tt[15] = (tt[1] * tt[8]) >> 20; tt[16] = (tt[2] * tt[9]) >> 20; tt[17] = (tt[3] * tt[10]) >> 20
                tt[18] = (tt[4] * tt[11]) >> 20; tt[19] = (tt[5] * tt[12]) >> 20; tt[20] = (tt[6] * tt[13]) >> 20
                tt[21] = (tt[7] * tt[14]) >> 20
            }
            var rr = Int64(m.constant[k]) * tt[0]
            var cnt = 1
            for i in stride(from: 1, through: order, by: 1) {
                for j in 0..<7 {
                    rr += Int64(m.coef[k][(i - 1) * 7 + j]) * tt[cnt]
                    cnt += 1
                }
            }
            return (rr, Self.v16(rr, m.coefShift))
        }

        /// The spec's fixed point carried to Q20 inputs that need not be whole codes (the 4:2:2 kernel's
        /// interpolated chroma): s << (20 - BL_bit_depth) becomes t, a product s_a * s_b << (20 - 2 BL_bit_depth)
        /// becomes (t_a * t_b) >> 20. For whole codes both are the spec's terms exactly (`q20FormIsTheSpecs`).
        func mmr(_ m: DoviMmrParams, _ k: Int, order: Int, q20 t0: Int64, _ t1: Int64, _ t2: Int64) -> (vv: Int64, v: Int) {
            var tt = [Int64](repeating: 0, count: 22)
            tt[0] = 1 << 20
            tt[1] = t0; tt[2] = t1; tt[3] = t2
            tt[4] = (t0 * t1) >> 20; tt[5] = (t0 * t2) >> 20; tt[6] = (t1 * t2) >> 20
            tt[7] = (tt[4] * tt[3]) >> 20
            for j in 1...7 { tt[7 + j] = (tt[j] * tt[j]) >> 20 }
            for j in 1...7 { tt[14 + j] = (tt[j] * tt[7 + j]) >> 20 }
            var rr = Int64(m.constant[k]) * tt[0]
            for i in stride(from: 1, through: order, by: 1) {
                for j in 0..<7 { rr += Int64(m.coef[k][(i - 1) * 7 + j]) * tt[(i - 1) * 7 + j + 1] }
            }
            return (rr, Self.v16(rr, m.coefShift))
        }

        /// One component's prediction: the 16-bit v and the sum before the clamps. Integer samples: `s` is the
        /// component's own, s0 / s1 / s2 what an MMR piece reads.
        func predict(_ c: DoviPolynomialParams, _ m: DoviMmrParams, s: Int, s0: Int, s1: Int, s2: Int) -> (vv: Int64, v: Int) {
            if c.numPivots < 2 { return (Int64(s) << (20 + 4), s << (16 - bd)) }
            let k = piece(c, s)
            if c.method[k] == DoviMapping.mmr.rawValue {
                func clamped(_ x: Int, _ cc: DoviPolynomialParams) -> Int64 {
                    cc.numPivots < 2 ? Int64(x) : Int64(min(max(x, Int(cc.pivots[0])), Int(cc.pivots[Int(cc.numPivots) - 1])))
                }
                return mmr(m, k, order: min(Int(c.order[k]), 3),
                           s0: clamped(s0, p.polyY), s1: clamped(s1, p.polyCb), s2: clamped(s2, p.polyCr))
            }
            return polynomial(c, k, s: s)
        }

        /// The same from Q20 values.
        func predict(_ c: DoviPolynomialParams, _ m: DoviMmrParams, q20 t: Int64, _ t0: Int64, _ t1: Int64, _ t2: Int64) -> (vv: Int64, v: Int) {
            if c.numPivots < 2 { return (t << 4, Int(min(max(t, 0) >> 4, 0xffff))) }
            func clamped(_ x: Int64, _ cc: DoviPolynomialParams) -> Int64 {
                cc.numPivots < 2 ? x : min(max(x, Int64(cc.pivots[0]) << (20 - bd)), Int64(cc.pivots[Int(cc.numPivots) - 1]) << (20 - bd))
            }
            let k = piece(c, q20: t)
            if c.method[k] == DoviMapping.mmr.rawValue {
                return mmr(m, k, order: min(Int(c.order[k]), 3), q20: clamped(t0, p.polyY), clamped(t1, p.polyCb), clamped(t2, p.polyCr))
            }
            let x = clamped(t, c)
            var vv = Int64(c.coef[k][0]) << 20
            if c.order[k] >= 1 { vv += Int64(c.coef[k][1]) * x }
            if c.order[k] >= 2 { vv += Int64(c.coef[k][2]) * ((x * x) >> 20) }
            return (vv, Self.v16(vv, c.coefShift[k]))
        }

        /// 5.4.3.2 as the spec writes it: the 16-bit residual of one EL code.
        func inverseNlq(_ n: DoviNlqParams, _ e: Int) -> Int {
            guard n.nlqMethod == .linear, n.nlqScale != 0 else { return 0 }
            let elBitDepth: Int64 = 10
            let coefficientLog2Denom = Int64(n.nlqShift) + 5 + elBitDepth
            let T = Int64(n.nlqThreshold), S = Int64(n.nlqScale), R = Int64(n.vdrInMax)
            var rr = Int64(e) - Int64(n.nlqOffset)
            if rr == 0 { return 0 }
            let sign: Int64 = rr < 0 ? -1 : 1
            rr <<= 1
            rr -= sign
            rr <<= (10 - elBitDepth)
            var dq = rr * S
            let TT = (T << (10 - elBitDepth + 1)) * sign
            dq += TT
            let RR = R << (10 - elBitDepth + 1)
            if dq > RR { dq = RR } else if dq < -RR { dq = -RR }
            return Int(dq >> (coefficientLog2Denom - 5 - elBitDepth))
        }

        /// 5.4.3.3: h = v (+ r), then (h + 2^(15 - out_bit_depth)) >> (16 - out_bit_depth), clipped.
        func reconstruct(_ h: Int) -> Int {
            let out = DoviFelComposer.bitDepth(ofMax: p.vdrMax)
            let maxOut = (1 << out) - 1
            let r = (h + (1 << (15 - out))) >> (16 - out)
            return min(max(r, 0), maxOut)
        }

        func nlqActive(_ n: DoviNlqParams) -> Bool {
            !p.flags.contains(.disableResidual) && n.nlqMethod == .linear && n.nlqScale != 0
        }

        /// Bilinear sample of an enhancement-layer plane at base-layer sample (x, y) of a plane `baseW` x
        /// `baseH`: the 10-bit codes interpolated, then rounded half up. Luma samples sit at pixel centres;
        /// chroma (`cosited`) is co-sited with the top-left luma sample, so the two grids share sample 0.
        func elCode(_ el: Plane, comp: Int, x: Int, y: Int, baseW: Int, baseH: Int, cosited: Bool = false) -> Int {
            let centre = cosited ? 0.0 : 0.5
            // Multiplied before dividing: (x + centre) * el / base is exact for the 2:1 and 1:1 grids, where
            // (x + centre) / base * el lands a hair below a quarter and turns exact halves down.
            let u = (Double(x) + centre) * Double(el.width) / Double(baseW) - centre
            let v = (Double(y) + centre) * Double(el.height) / Double(baseH) - centre
            let x0 = Int(floor(u)), y0 = Int(floor(v))
            let fx = u - Double(x0), fy = v - Double(y0)
            func w(_ xx: Int, _ yy: Int) -> Double {
                Double(el.code(min(max(xx, 0), el.width - 1), min(max(yy, 0), el.height - 1), comp))
            }
            let top = w(x0, y0) * (1 - fx) + w(x0 + 1, y0) * fx
            let bot = w(x0, y0 + 1) * (1 - fx) + w(x0 + 1, y0 + 1) * fx
            return Int((top * (1 - fy) + bot * fy + 0.5).rounded(.down))
        }

        /// One component's pieces: the prediction sum before its clamps, the 16-bit prediction, the
        /// enhancement-layer code and the 16-bit residual it decodes to.
        struct Parts { var vv: Int64 = 0; var pred = 0; var elCode = 0; var residual = 0; var active = false
            var total: Int { pred + residual } }

        func lumaParts(bl: Plane, blUV: Plane, el: Plane, x: Int, y: Int) -> Parts {
            let by = bl.code(x, y)
            let cx = min(x >> 1, blUV.width - 1), cy = min(y >> 1, blUV.height - 1)
            var r = Parts()
            (r.vv, r.pred) = predict(p.polyY, p.mmrY, s: by, s0: by, s1: blUV.code(cx, cy, 0), s2: blUV.code(cx, cy, 1))
            if nlqActive(p.nlqY) {
                r.active = true
                r.elCode = elCode(el, comp: 0, x: x, y: y, baseW: bl.width, baseH: bl.height)
                r.residual = inverseNlq(p.nlqY, r.elCode)
            }
            return r
        }

        /// Luma at the chroma site, 5.4.2.3.3: [1 2 1] around the even column in both rows of the cell, rounded
        /// per row, then the two rows averaged; edges replicated.
        static func chromaSiteLuma(_ bl: Plane, x: Int, y: Int) -> Int {
            func at(_ c: Int, _ r: Int) -> Int { bl.code(min(max(c, 0), bl.width - 1), min(r, bl.height - 1)) }
            let rows = [y * 2, y * 2 + 1].map { r in (at(x * 2 - 1, r) + 2 * at(x * 2, r) + at(x * 2 + 1, r) + 2) >> 2 }
            return (rows[0] + rows[1] + 1) >> 1
        }

        func chromaParts(bl: Plane, blUV: Plane, elUV: Plane, x: Int, y: Int) -> (cb: Parts, cr: Parts) {
            let by = Self.chromaSiteLuma(bl, x: x, y: y)
            let cb = blUV.code(x, y, 0), cr = blUV.code(x, y, 1)
            var a = Parts(), b = Parts()
            (a.vv, a.pred) = predict(p.polyCb, p.mmrCb, s: cb, s0: by, s1: cb, s2: cr)
            (b.vv, b.pred) = predict(p.polyCr, p.mmrCr, s: cr, s0: by, s1: cb, s2: cr)
            if nlqActive(p.nlqCb) {
                a.active = true
                a.elCode = elCode(elUV, comp: 0, x: x, y: y, baseW: blUV.width, baseH: blUV.height, cosited: true)
                a.residual = inverseNlq(p.nlqCb, a.elCode)
            }
            if nlqActive(p.nlqCr) {
                b.active = true
                b.elCode = elCode(elUV, comp: 1, x: x, y: y, baseW: blUV.width, baseH: blUV.height, cosited: true)
                b.residual = inverseNlq(p.nlqCr, b.elCode)
            }
            return (a, b)
        }

        /// The 12-bit reconstructed luma sample (5.4.3.3).
        func luma(bl: Plane, blUV: Plane, el: Plane, x: Int, y: Int) -> Int {
            reconstruct(lumaParts(bl: bl, blUV: blUV, el: el, x: x, y: y).total)
        }

        /// The 12-bit reconstructed (Cb, Cr) samples.
        func chroma(bl: Plane, blUV: Plane, elUV: Plane, x: Int, y: Int) -> (Int, Int) {
            let (a, b) = chromaParts(bl: bl, blUV: blUV, elUV: elUV, x: x, y: y)
            return (reconstruct(a.total), reconstruct(b.total))
        }

        // MARK: 4:2:2 sites (sv22)

        /// The chroma-row coordinate of 4:2:2 row `row` for the base layer's siting (`AVChromaLocation`): chroma
        /// between luma rows 2k and 2k + 1 for LEFT / CENTER and unspecified (row / 2 - 1/4), on row 2k for TOPLEFT /
        /// TOP (row / 2), on row 2k + 1 for BOTTOMLEFT / BOTTOM (row / 2 - 1/2).
        func chroma422Coordinate(row: Int) -> Double {
            switch p.blChromaLocation {
            case 3, 4: return Double(row) / 2
            case 5, 6: return Double(row) / 2 - 0.5
            default: return Double(row) / 2 - 0.25
            }
        }

        /// Catmull-Rom (B = 0, C = 0.5) weights for rows i - 1 ... i + 2 at phase t from row i.
        static func catmullRom(_ t: Double) -> [Double] {
            [(-t + 2 * t * t - t * t * t) / 2, (2 - 5 * t * t + 3 * t * t * t) / 2,
             (t + 4 * t * t - 3 * t * t * t) / 2, (-t * t + t * t * t) / 2]
        }

        /// Base-layer chroma at 4:2:2 row `row`: Catmull-Rom at the row's coordinate over the clamped chroma rows,
        /// clamped to [0, bl_max].
        func chroma422Base(_ blUV: Plane, x: Int, row: Int, comp: Int) -> Double {
            let c = chroma422Coordinate(row: row)
            let i0 = Int(floor(c))
            let w = Self.catmullRom(c - Double(i0))
            var s = 0.0
            for i in 0..<4 {
                s += Double(blUV.code(x, min(max(i0 - 1 + i, 0), blUV.height - 1), comp)) * w[i]
            }
            return min(max(s, 0), Double(p.blMax))
        }

        /// Q20 of a base-layer value; exact for the 1/128 multiples the 4:2:2 interpolation produces.
        func q20(_ s: Double) -> Int64 { Int64((s * Double(1 << (20 - bd))).rounded()) }

        /// Luma at a 4:2:2 chroma site: [1 2 1] around the even column on that row alone, edges clamped.
        static func chroma422Luma(_ bl: Plane, x: Int, row: Int) -> Int {
            func at(_ c: Int) -> Int { bl.code(min(max(c, 0), bl.width - 1), row) }
            return (at(x * 2 - 1) + 2 * at(x * 2) + at(x * 2 + 1) + 2) >> 2
        }

        /// Bilinear EL chroma code at 4:2:2 row `row`, column `x`: the row's 4:2:0 coordinate (`chroma422Coordinate`) mapped
        /// through the co-sited grid relation of ``elCode(_:comp:x:y:baseW:baseH:cosited:)``, rounded half up.
        func elCode422(_ el: Plane, comp: Int, x: Int, row: Int, baseW: Int, baseH: Int) -> Int {
            let u = Double(x) * Double(el.width) / Double(baseW)
            let v = chroma422Coordinate(row: row) * Double(el.height) / Double(baseH)
            let x0 = Int(floor(u)), y0 = Int(floor(v))
            let fx = u - Double(x0), fy = v - Double(y0)
            func w(_ xx: Int, _ yy: Int) -> Double {
                Double(el.code(min(max(xx, 0), el.width - 1), min(max(yy, 0), el.height - 1), comp))
            }
            let top = w(x0, y0) * (1 - fx) + w(x0 + 1, y0) * fx
            let bot = w(x0, y0 + 1) * (1 - fx) + w(x0 + 1, y0 + 1) * fx
            return Int((top * (1 - fy) + bot * fy + 0.5).rounded(.down))
        }

        /// The 16-bit sums (Cb, Cr) at 4:2:2 site (x, row), before any output rounding, as `dovi_compose_chroma_422`
        /// composes them.
        func chroma422Sum(bl: Plane, blUV: Plane, elUV: Plane, x: Int, row: Int) -> (Int, Int) {
            let t0 = Int64(Self.chroma422Luma(bl, x: x, row: row)) << (20 - bd)
            let t1 = q20(chroma422Base(blUV, x: x, row: row, comp: 0)), t2 = q20(chroma422Base(blUV, x: x, row: row, comp: 1))
            var hcb = predict(p.polyCb, p.mmrCb, q20: t1, t0, t1, t2).v
            var hcr = predict(p.polyCr, p.mmrCr, q20: t2, t0, t1, t2).v
            if nlqActive(p.nlqCb) {
                hcb += inverseNlq(p.nlqCb, elCode422(elUV, comp: 0, x: x, row: row, baseW: blUV.width, baseH: blUV.height))
            }
            if nlqActive(p.nlqCr) {
                hcr += inverseNlq(p.nlqCr, elCode422(elUV, comp: 1, x: x, row: row, baseW: blUV.width, baseH: blUV.height))
            }
            return (hcb, hcr)
        }

        /// The 12-bit (Cb, Cr) at 4:2:2 site (x, row).
        func chroma422(bl: Plane, blUV: Plane, elUV: Plane, x: Int, row: Int) -> (Int, Int) {
            let (a, b) = chroma422Sum(bl: bl, blUV: blUV, elUV: elUV, x: x, row: row)
            return (reconstruct(a), reconstruct(b))
        }
    }

    // MARK: - Comparison

    struct Stat {
        var n = 0, exact = 0, over1 = 0, maxAbs = 0, sum = 0
        mutating func add(_ d: Int) {
            n += 1; let a = abs(d)
            if a == 0 { exact += 1 }
            if a > 1 { over1 += 1 }
            maxAbs = max(maxAbs, a); sum += d
        }
        var exactPct: Double { n == 0 ? 0 : 100 * Double(exact) / Double(n) }
        var over1Pct: Double { n == 0 ? 0 : 100 * Double(over1) / Double(n) }
        var description: String {
            String(format: "n=%d exact %.2f%% |d|>1 %.3f%% max %d mean %+.3f", n, exactPct, over1Pct, maxAbs,
                   n == 0 ? 0 : Double(sum) / Double(n))
        }
    }

    static func describe(_ c: DoviPolynomialParams, _ mmr: DoviMmrParams) -> String {
        guard c.numPivots >= 2 else { return "identity" }
        let pieces = Int(c.numPivots) - 1
        let kinds = (0..<pieces).map { c.method[$0] == DoviMapping.mmr.rawValue ? "mmr\(c.order[$0])" : "poly\(c.order[$0])" }
        return "\(pieces) pieces [\(kinds.joined(separator: ","))] shift \(c.coefShift[0])/\(mmr.coefShift)"
    }

    @Test("the independent CPU model reproduces the GPU's 12-bit VDR on real titles, MMR chroma and multi-piece curves included",
          .enabled(if: !DoviFelRealFileTests.availableFixtures.isEmpty, DoviFelRealFileTests.needsClips),
          arguments: DoviFelRealFileTests.availableFixtures)
    func modelMatchesGpu(name: String) throws {
        let rec = try #require(DoviFelRealFileTests.RecordingComposer(limit: 6, stride: 40))
        let s = try DoviFelRealFileTests.open(name, composer: rec)
        defer { s.decoder.close(); s.demuxer.close() }
        DoviFelRealFileTests.feed(s, count: 300)
        s.decoder.flush()
        let caps = rec.captures
        try #require(!caps.isEmpty, "no frames reached the composer")

        var yStat = Stat(), cbStat = Stat(), crStat = Stat()
        for (i, cap) in caps.enumerated() {
            var params = cap.params
            params.ditherMode = .debugRawVDR
            let out = try #require(rec.inner.compose(baseBuffer: cap.bl, enhancementBuffer: cap.el, params: params, frameIndex: 0))
            let gy = Self.plane(out, 0, components: 1), guv = Self.plane(out, 1, components: 2)
            let bl = Self.plane(cap.bl, 0, components: 1), blUV = Self.plane(cap.bl, 1, components: 2)
            let el = Self.plane(cap.el, 0, components: 1), elUV = Self.plane(cap.el, 1, components: 2)
            let model = Model(params)
            if i == 0 {
                print("[m8] \(name): Y \(Self.describe(params.polyY, params.mmrY)); Cb \(Self.describe(params.polyCb, params.mmrCb)); Cr \(Self.describe(params.polyCr, params.mmrCr)); flags \(params.flags.rawValue); nlqY scale \(params.nlqY.nlqScale) thr \(params.nlqY.nlqThreshold) max \(params.nlqY.vdrInMax) shift \(params.nlqY.nlqShift); nlqCb scale \(params.nlqCb.nlqScale)")
            }
            // The raw-VDR planes hold the 12-bit code shifted left 4 in a 16-bit word.
            func gpu(_ p: Plane, _ x: Int, _ y: Int, _ c: Int) -> Int { Int(p.raw[(y * p.width + x) * p.components + c] >> 4) }
            for y in stride(from: 3, to: bl.height, by: 7) {
                for x in stride(from: 5, to: bl.width, by: 11) {
                    yStat.add(model.luma(bl: bl, blUV: blUV, el: el, x: x, y: y) - gpu(gy, x, y, 0))
                }
            }
            for y in stride(from: 1, to: blUV.height, by: 5) {
                for x in stride(from: 2, to: blUV.width, by: 7) {
                    let (cb, cr) = model.chroma(bl: bl, blUV: blUV, elUV: elUV, x: x, y: y)
                    cbStat.add(cb - gpu(guv, x, y, 0))
                    crStat.add(cr - gpu(guv, x, y, 1))
                }
            }
        }
        print("[m8] \(name): Y \(yStat.description)")
        print("[m8] \(name): Cb \(cbStat.description)")
        print("[m8] \(name): Cr \(crStat.description)")
        // Both sides are integer arithmetic on the same inputs, the enhancement-layer filter included: any
        // difference is a disagreement about the maths.
        for (label, st) in [("Y", yStat), ("Cb", cbStat), ("Cr", crStat)] {
            #expect(st.n > 0 && st.exact == st.n, "\(label): \(st.description)")
        }
    }

    // MARK: - MMR float precision (M9)

    /// The same sum in exact integer arithmetic: every term over the common denominator 2^(coefShift + 90)
    /// (1024^9 covers order 3 of the three-way product).
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, *)
    static func mmrExact(_ mmr: DoviMmrParams, piece k: Int, order: Int, y: Int, u: Int, v: Int) -> Double {
        let m: [(Int128, Int)] = [(Int128(y), 1), (Int128(u), 1), (Int128(v), 1), (Int128(y * u), 2),
                                  (Int128(y * v), 2), (Int128(u * v), 2), (Int128(y * u * v), 3)]
        var n = Int128(mmr.constant[k]) << 90
        for o in 0..<order {
            for j in 0..<7 {
                var p: Int128 = 1
                for _ in 0...o { p *= m[j].0 }
                n += Int128(mmr.coef[k][o * 7 + j]) * p << (90 - 10 * m[j].1 * (o + 1))
            }
        }
        return Double(n) / pow(2, Double(Int(mmr.coefShift) + 90))
    }

    /// Every real chroma MMR coefficient set the tests can reach: the clip A and clip C RPUs, dovi_tool's
    /// `fel_orig`, and the distinct sets of the probe's 1584-RPU file when it is present.
    static func realMmrParams() -> [(String, DoviMetalParams)] {
        func hex(_ h: String) -> [UInt8] {
            stride(from: 0, to: h.count, by: 2).map { i in
                let a = h.index(h.startIndex, offsetBy: i)
                return UInt8(h[a..<h.index(a, offsetBy: 2)], radix: 16)!
            }
        }
        var out: [(String, DoviMetalParams)] = []
        for (name, nal) in [("clip A", hex(DoviFelMathTests.clipARpuHex)), ("clip C", hex(DoviFelMathTests.clipCRpuHex)),
                            ("fel_orig", DoviComposedFrameRpuTests.felNAL)] {
            if let rpu = dovi_parse_unspec62_nalu(nal, nal.count) {
                if let p = DoviFelComposer.parseRpuParameters(rpu: rpu) { out.append((name, p)) }
                dovi_rpu_free(rpu)
            }
        }
        let bin = "/Users/matthewfaust/Github/tvosplayer/AetherEngine/Probes/DolbyVisionPulse/out/fel_1584.bin"
        if FileManager.default.fileExists(atPath: bin), let list = dovi_parse_rpu_bin_file(bin) {
            defer { dovi_rpu_list_free(list) }
            var seen = Set<[Int32]>()
            for i in 0..<list.pointee.len {
                guard let rpu = list.pointee.list?[i], let p = DoviFelComposer.parseRpuParameters(rpu: rpu) else { continue }
                let key = [p.mmrCb, p.mmrCr].flatMap { $0.constant + $0.coef.flatMap { $0 } }
                if seen.insert(key).inserted { out.append(("fel_1584 #\(i)", p)) }
            }
        }
        return out
    }

    @Test("M9: the Q20 form the kernels use equals the spec's tt[] on every real coefficient set; the spec's truncation stays within a 16-bit unit or two")
    func q20FormIsTheSpecs() throws {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, *) else { return }
        let sets = Self.realMmrParams()
        try #require(!sets.isEmpty)
        var curves = 0, points = 0, mismatches = 0, worstTruncation = 0.0
        for (name, p) in sets {
            let m = Model(p)
            for (label, curve, mmr) in [("Cb", p.polyCb, p.mmrCb), ("Cr", p.polyCr, p.mmrCr)] {
                guard curve.numPivots >= 2 else { continue }
                let pieces = Int(curve.numPivots) - 1
                guard (0..<pieces).contains(where: { curve.method[$0] == DoviMapping.mmr.rawValue }) else { continue }
                curves += 1
                func range(_ c: DoviPolynomialParams) -> ClosedRange<Int> {
                    c.numPivots < 2 ? 0...1023 : Int(c.pivots[0])...Int(c.pivots[Int(c.numPivots) - 1])
                }
                func grid(_ r: ClosedRange<Int>, _ step: Int) -> [Int] { Array(stride(from: r.lowerBound, to: r.upperBound, by: step)) + [r.upperBound] }
                let ys = grid(range(p.polyY), 64), us = grid(range(p.polyCb), 16), vs = grid(range(p.polyCr), 16)
                var curveWorst = 0.0
                for y in ys { for u in us { for v in vs {
                    let own = label == "Cb" ? u : v
                    let k = m.piece(curve, own)
                    guard curve.method[k] == DoviMapping.mmr.rawValue else { continue }
                    let order = min(Int(curve.order[k]), 3)
                    let spec = m.mmr(mmr, k, order: order, s0: Int64(y), s1: Int64(u), s2: Int64(v))
                    let q20 = m.mmr(mmr, k, order: order, q20: Int64(y) << 10, Int64(u) << 10, Int64(v) << 10)
                    if spec.vv != q20.vv { mismatches += 1 }
                    // The spec truncates each product term to Q20; against the exact sum, in 16-bit units.
                    let exact = Self.mmrExact(mmr, piece: k, order: order, y: y, u: u, v: v) * 65536
                    curveWorst = max(curveWorst, abs(Double(spec.vv) / pow(2, Double(mmr.coefShift) + 4) - exact))
                    points += 1
                } } }
                worstTruncation = max(worstTruncation, curveWorst)
                if !name.hasPrefix("fel_1584") || curveWorst == worstTruncation {
                    print(String(format: "[m9] %@ %@: spec truncation vs exact sum, worst %.4f 16-bit units", name, label, curveWorst))
                }
            }
        }
        print("[m9] \(sets.count) coefficient sets, \(curves) MMR curves, \(points) points: \(mismatches) Q20 / tt[] mismatches")
        #expect(curves > 0)
        #expect(mismatches == 0)
        #expect(worstTruncation < 4, "spec truncation \(worstTruncation) 16-bit units")
    }

    // MARK: - Loss census (M1) and error attribution (M3, M4, M6)

    /// Counts, per plane, every pixel at a point where information can be lost. Fractions of the
    /// sampled pixels. The output range clamps are video range: 64...940 luma, 64...960 chroma.
    struct Census {
        var n = 0
        var predBelow0 = 0, predAbove1 = 0
        var nlqAtMax = 0, residualPixels = 0
        var vdrBelow0 = 0, vdrAboveMax = 0
        var outBelowLo = 0, outAboveHi = 0
        var elAt0 = 0, elAt1023 = 0
        var worstOvershoot = 0
        mutating func add(_ q: Model.Parts, _ nlq: DoviNlqParams, model m: Model, lo: Int, hi: Int) {
            n += 1
            if q.vv < 0 { predBelow0 += 1 }
            if q.pred == 0xffff { predAbove1 += 1 }
            if q.active {
                residualPixels += 1
                // The residual's ceiling, R at 16 bits (5.4.3.2: the clamp is +/-2R before the shift).
                if nlq.vdrInMax > 0 && abs(q.residual) >= Int((Int64(nlq.vdrInMax) << 1) >> Int64(nlq.nlqShift)) { nlqAtMax += 1 }
                if q.elCode <= 0 { elAt0 += 1 }
                if q.elCode >= 1023 { elAt1023 += 1 }
            }
            let t = q.total
            if t < 0 { vdrBelow0 += 1 }
            if t > 0xffff { vdrAboveMax += 1 }
            let out = Int(floor(Double(min(max(t, 0), 0xffff)) / 64 + 0.5))
            if out < lo { outBelowLo += 1; worstOvershoot = max(worstOvershoot, lo - out) }
            if out > hi { outAboveHi += 1; worstOvershoot = max(worstOvershoot, out - hi) }
        }
        var line: String {
            func f(_ v: Int) -> String { String(format: "%.4f%%", n == 0 ? 0 : 100 * Double(v) / Double(n)) }
            return "n=\(n) pred<0 \(f(predBelow0)) pred>1 \(f(predAbove1)) | residual px \(f(residualPixels)) at vdr_in_max \(f(nlqAtMax)) EL=0 \(f(elAt0)) EL=1023 \(f(elAt1023)) | vdr<0 \(f(vdrBelow0)) vdr>max \(f(vdrAboveMax)) | out<lo \(f(outBelowLo)) out>hi \(f(outAboveHi)) worst overshoot \(worstOvershoot) codes"
        }
    }

    @Test("M1: loss census on real titles, every clamp counted", .enabled(if: !DoviFelRealFileTests.availableFixtures.isEmpty, DoviFelRealFileTests.needsClips),
          arguments: DoviFelRealFileTests.availableFixtures)
    func lossCensus(name: String) throws {
        let rec = try #require(DoviFelRealFileTests.RecordingComposer(limit: 6, stride: 40))
        let s = try DoviFelRealFileTests.open(name, composer: rec)
        defer { s.decoder.close(); s.demuxer.close() }
        DoviFelRealFileTests.feed(s, count: 300)
        s.decoder.flush()
        var y = Census(), cb = Census(), cr = Census()
        for cap in rec.captures {
            let p = cap.params
            let m = Model(p)
            let bl = Self.plane(cap.bl, 0, components: 1), blUV = Self.plane(cap.bl, 1, components: 2)
            let el = Self.plane(cap.el, 0, components: 1), elUV = Self.plane(cap.el, 1, components: 2)
            for yy in stride(from: 3, to: bl.height, by: 5) {
                for xx in stride(from: 5, to: bl.width, by: 7) {
                    y.add(m.lumaParts(bl: bl, blUV: blUV, el: el, x: xx, y: yy), p.nlqY, model: m, lo: 64, hi: 940)
                }
            }
            for yy in stride(from: 1, to: blUV.height, by: 3) {
                for xx in stride(from: 2, to: blUV.width, by: 5) {
                    let (a, b) = m.chromaParts(bl: bl, blUV: blUV, elUV: elUV, x: xx, y: yy)
                    cb.add(a, p.nlqCb, model: m, lo: 64, hi: 960)
                    cr.add(b, p.nlqCr, model: m, lo: 64, hi: 960)
                }
            }
        }
        print("[m1] \(name): Y  \(y.line)")
        print("[m1] \(name): Cb \(cb.line)")
        print("[m1] \(name): Cr \(cr.line)")
    }

    @Test("M3/M4/M6: where the GPU and the exact model still differ, split by cause", .enabled(if: !DoviFelRealFileTests.availableFixtures.isEmpty, DoviFelRealFileTests.needsClips),
          arguments: DoviFelRealFileTests.availableFixtures)
    func errorAttribution(name: String) throws {
        let rec = try #require(DoviFelRealFileTests.RecordingComposer(limit: 6, stride: 40))
        let s = try DoviFelRealFileTests.open(name, composer: rec)
        defer { s.decoder.close(); s.demuxer.close() }
        DoviFelRealFileTests.feed(s, count: 300)
        s.decoder.flush()
        var lumaNoRes = Stat(), chromaNoRes = Stat(), lumaRes = Stat(), chromaRes = Stat()
        for cap in rec.captures {
            let bl = Self.plane(cap.bl, 0, components: 1), blUV = Self.plane(cap.bl, 1, components: 2)
            let el = Self.plane(cap.el, 0, components: 1), elUV = Self.plane(cap.el, 1, components: 2)
            for residual in [false, true] {
                var params = cap.params
                params.ditherMode = .debugRawVDR
                if !residual { params.flags.insert(.disableResidual) }
                let out = try #require(rec.inner.compose(baseBuffer: cap.bl, enhancementBuffer: cap.el, params: params, frameIndex: 0))
                let gy = Self.plane(out, 0, components: 1), guv = Self.plane(out, 1, components: 2)
                let m = Model(params)
                func g(_ p: Plane, _ x: Int, _ y: Int, _ c: Int) -> Int { Int(p.raw[(y * p.width + x) * p.components + c] >> 4) }
                for yy in stride(from: 3, to: bl.height, by: 5) {
                    for xx in stride(from: 5, to: bl.width, by: 7) {
                        let d = m.luma(bl: bl, blUV: blUV, el: el, x: xx, y: yy) - g(gy, xx, yy, 0)
                        if residual { lumaRes.add(d) } else { lumaNoRes.add(d) }
                    }
                }
                for yy in stride(from: 1, to: blUV.height, by: 3) {
                    for xx in stride(from: 2, to: blUV.width, by: 5) {
                        let (a, b) = m.chroma(bl: bl, blUV: blUV, elUV: elUV, x: xx, y: yy)
                        let d1 = a - g(guv, xx, yy, 0), d2 = b - g(guv, xx, yy, 1)
                        if residual { chromaRes.add(d1); chromaRes.add(d2) } else { chromaNoRes.add(d1); chromaNoRes.add(d2) }
                    }
                }
            }
        }
        print("[m3] \(name): luma, no residual (table):       \(lumaNoRes.description)")
        print("[m4] \(name): chroma, no residual (MMR):       \(chromaNoRes.description)")
        print("[m6] \(name): luma, with residual (+ EL sampling): \(lumaRes.description)")
        print("[m6] \(name): chroma, with residual:               \(chromaRes.description)")
    }

    /// M7: how much the chroma MMR output depends on how the luma is brought down to the chroma site.
    /// Each variant replaces only the luma input of the cross terms; the production reading is the baseline.
    @Test("M7: chroma MMR sensitivity to the luma downsampling at the chroma site", .enabled(if: !DoviFelRealFileTests.availableFixtures.isEmpty, DoviFelRealFileTests.needsClips),
          arguments: DoviFelRealFileTests.availableFixtures)
    func lumaSiteSensitivity(name: String) throws {
        let rec = try #require(DoviFelRealFileTests.RecordingComposer(limit: 6, stride: 40))
        let s = try DoviFelRealFileTests.open(name, composer: rec)
        defer { s.decoder.close(); s.demuxer.close() }
        DoviFelRealFileTests.feed(s, count: 300)
        s.decoder.flush()
        let names = ["top row", "2x2 box", "vertical 2-tap", "bottom row"]
        var sq = [Double](repeating: 0, count: names.count), mx = [Int](repeating: 0, count: names.count)
        var n = 0
        for cap in rec.captures {
            let p = cap.params
            let m = Model(p)
            let bl = Self.plane(cap.bl, 0, components: 1), blUV = Self.plane(cap.bl, 1, components: 2)
            func at(_ x: Int, _ y: Int) -> Int { bl.code(min(max(x, 0), bl.width - 1), min(max(y, 0), bl.height - 1)) }
            for yy in stride(from: 1, to: blUV.height, by: 3) {
                for xx in stride(from: 2, to: blUV.width, by: 5) {
                    let cb = m.q20(Double(blUV.code(xx, yy, 0))), cr = m.q20(Double(blUV.code(xx, yy, 1)))
                    // 12-bit predictions; the variants' luma is a whole or a quarter code, exact in Q20.
                    func pred(_ luma: Double) -> (Int, Int) {
                        let t0 = m.q20(luma)
                        return (m.reconstruct(m.predict(p.polyCb, p.mmrCb, q20: cb, t0, cb, cr).v),
                                m.reconstruct(m.predict(p.polyCr, p.mmrCr, q20: cr, t0, cb, cr).v))
                    }
                    let x0 = xx * 2, y0 = yy * 2
                    let base = pred(Double(Model.chromaSiteLuma(bl, x: xx, y: yy)))
                    let box = (at(x0, y0) + at(x0 + 1, y0) + at(x0, y0 + 1) + at(x0 + 1, y0 + 1))
                    let variants = [pred(Double(at(x0, y0))), pred(Double(box) / 4),
                                    pred(Double((at(x0, y0) + at(x0, y0 + 1) + 1) >> 1)), pred(Double(at(x0, y0 + 1)))]
                    for (i, v) in variants.enumerated() {
                        for d in [v.0 - base.0, v.1 - base.1] { sq[i] += Double(d * d); mx[i] = max(mx[i], abs(d)) }
                    }
                    n += 2
                }
            }
        }
        for i in 0..<names.count {
            print(String(format: "[m7] %@: %@ vs [1 2 1] x 2-row: RMS %.3f codes (12-bit), max %d", name, names[i], (sq[i] / Double(n)).squareRoot(), mx[i]))
        }
    }
}
#endif
