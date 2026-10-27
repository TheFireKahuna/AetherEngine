// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import CoreGraphics
import CoreVideo
@testable import AetherEngine

/// A Dolby Vision profile 5 / AV1 10.0 picture made into a still on the GPU
/// (``DoviFelComposer/composeBaseLayerStill(baseBuffer:params:conversion:)``), against a reference computed here from
/// the process itself: the composer's fixed-point prediction of each base-layer code, its reconstruction to
/// hdr_bit_depth bits, then the RPU's colour conversion (ycc_to_rgb with its offsets, the ST 2084 EOTF, rgb_to_lms and
/// LMS to BT.2020), encoded as BT.2020 Y'CbCr PQ, 16-bit video range.
@Suite(.serialized)
struct DolbyVisionBaseLayerStillTests {

    static let width = 512
    static let height = 4
    /// Constant chroma: every reference resampling filter sums to one, so the composed chroma reaches every pixel
    /// unchanged and the reference needs no filter of its own.
    static let cb = 600
    static let cr = 420

    /// The display-management colour data of a real profile 5 RPU (`Fixtures/user`'s sample, frame 0).
    static let conversion: DoviIptConversion = {
        let ycc = [8192, 799, 1681, 8192, -933, 1091, 8192, 267, -5545].map { Double($0) / 8192 }
        let offsets = [0, 134_217_728, 134_217_728].map { Double($0) / 268_435_456 }
        let rgbToLms = [17081, -349, -349, -349, 17081, -349, -349, -349, 17081].map { Double($0) / 16384 }
        return DoviIptConversion(words: (ycc + offsets + DoviIptConversion.multiply(DoviIptConversion.lmsToBT2020, rgbToLms))
            .map(Float.init))
    }()

    /// A piecewise curve in the shape real profile 5 RPUs carry: quadratic luma pieces, linear chroma.
    static func curve(pivots: [UInt32], coefficients: [[Double]]) -> DoviPolynomialParams {
        var poly = DoviPolynomialParams()
        poly.numPivots = UInt32(pivots.count)
        for (i, pivot) in pivots.enumerated() { poly.pivots[i] = pivot }
        for (piece, c) in coefficients.enumerated() {
            poly.method[piece] = DoviMapping.polynomial.rawValue
            poly.order[piece] = UInt32(c.count - 1)
            poly.coef[piece] = (0..<3).map { $0 < c.count ? Int32((c[$0] * Double(1 << 23)).rounded()) : 0 }
            poly.coefShift[piece] = 23
        }
        return poly
    }

    static func params() throws -> DoviMetalParams {
        var params = DoviMetalParams()
        let depthsSet = params.setBitDepths(bl: 10, vdr: 12)
        try #require(depthsSet)
        params.polyY = curve(pivots: [0, 300, 700, 1023],
                             coefficients: [[0.002, 0.95, 0.10], [0.01, 0.90, 0.12], [-0.02, 1.02, -0.01]])
        params.polyCb = curve(pivots: [0, 1023], coefficients: [[0.06739, 1.05242]])
        params.polyCr = curve(pivots: [0, 1023], coefficients: [[-0.031, 0.96]])
        params.outputFullRange = true
        return params
    }

    /// The reconstructed hdr_bit_depth sample of a 16-bit prediction: (h + 2^(15 - bits)) >> (16 - bits), clipped.
    static func reconstruct(_ h: Int32) -> Double {
        Double(min(max((Int(h) + 8) >> 4, 0), 4095))
    }

    static func pqEOTF(_ e: Double) -> Double {
        let p = pow(max(e, 0), 1 / 78.84375)
        return pow(max(p - 0.8359375, 0) / (18.8515625 - 18.6875 * p), 1 / 0.1593017578125)
    }

    static func pqOETF(_ l: Double) -> Double {
        let p = pow(max(l, 0), 0.1593017578125)
        return pow((0.8359375 + 18.8515625 * p) / (1 + 18.6875 * p), 78.84375)
    }

    /// The expected 16-bit (Y', Cb, Cr) of base-layer luma `code`.
    static func expected(code: Int, params: DoviMetalParams) -> [Int] {
        let signal = [DoviFelComposer.polynomialPrediction(params.polyY, code: code, blBitDepth: 10),
                      DoviFelComposer.polynomialPrediction(params.polyCb, code: cb, blBitDepth: 10),
                      DoviFelComposer.polynomialPrediction(params.polyCr, code: cr, blBitDepth: 10)]
            .map { reconstruct($0) / 4095 }
        let w = conversion.words.map(Double.init)
        let s = (0..<3).map { signal[$0] - w[9 + $0] }
        let lms = (0..<3).map { r in pqEOTF((0..<3).reduce(0) { $0 + w[r * 3 + $1] * s[$1] }) }
        let rgb = (0..<3).map { r in pqOETF(max((0..<3).reduce(0) { $0 + w[12 + r * 3 + $1] * lms[$1] }, 0)) }
        let y = 0.2627 * rgb[0] + 0.6780 * rgb[1] + 0.0593 * rgb[2]
        return [4096 + 56064 * y, 32768 + 57344 * (rgb[2] - y) / 1.8814, 32768 + 57344 * (rgb[0] - y) / 1.4746]
            .map { min(max(Int($0.rounded()), 0), 65535) }
    }

    /// Row `row` of `plane` as its 16-bit words, `components` per sample.
    static func words(_ buffer: CVPixelBuffer, plane: Int, components: Int, row: Int) -> [[Int]] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return [] }
        let words = (base + row * CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)).assumingMemoryBound(to: UInt16.self)
        return (0..<CVPixelBufferGetWidthOfPlane(buffer, plane)).map { column in
            (0..<components).map { Int(words[column * components + $0]) }
        }
    }

    /// Within 1 of 65535: the reference's own rounding.
    @Test("a base-layer still matches the reconstruction and the RPU's colour conversion at every luma code")
    func composedStillMatchesReference() throws {
        let composer = try #require(DoviFelComposer.p010ForTesting())
        let base = try #require(DoviGpuCurveSweepTests.makeBuffer(width: Self.width, height: Self.height))
        DoviGpuCurveSweepTests.fillPlane(base, plane: 0, components: 1) { column, _, _ in min(column * 2, 1023) }
        DoviGpuCurveSweepTests.fillPlane(base, plane: 1, components: 2) { _, _, c in c == 0 ? Self.cb : Self.cr }
        let params = try Self.params()

        let still = try #require(composer.composeBaseLayerStill(baseBuffer: base, params: params, conversion: Self.conversion,
                                                                staticMetadata: .none))
        #expect(CVPixelBufferGetPixelFormatType(still) == kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange)
        #expect(CVBufferCopyAttachment(still, kCVImageBufferTransferFunctionKey, nil) as? String
                == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        #expect(CVBufferCopyAttachment(still, kCVImageBufferYCbCrMatrixKey, nil) as? String
                == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)

        var worst = (difference: 0, code: 0, component: 0, got: 0, want: 0)
        for row in 0..<Self.height {
            let luma = Self.words(still, plane: 0, components: 1, row: row)
            let chroma = Self.words(still, plane: 1, components: 2, row: row)
            for column in 0..<Self.width {
                let code = min(column * 2, 1023)
                let want = Self.expected(code: code, params: params)
                let got = [luma[column][0], chroma[column][0], chroma[column][1]]
                for component in 0..<3 where abs(got[component] - want[component]) > worst.difference {
                    worst = (abs(got[component] - want[component]), code, component, got[component], want[component])
                }
            }
        }
        #expect(worst.difference <= 1, """
            the GPU still differs from the reference by \(worst.difference) of 65535 at base-layer code \(worst.code), \
            component \(worst.component): \(worst.got) against \(worst.want)
            """)
    }

    @Test("the RPU's source PQ range reads as the mastering display's luminance")
    func sourceRangeLuminance() {
        // The sample's source_max_pq / source_min_pq: a 1000 cd/m2 mastering display, and its black.
        #expect(abs(DolbyVisionMasteringDisplay.nits(pq: 3079.0 / 4095) - 1000) < 5)
        #expect(DolbyVisionMasteringDisplay.nits(pq: 7.0 / 4095) < 0.001)
        #expect(DolbyVisionMasteringDisplay.primaries(nil) == nil)
        #expect(DolbyVisionMasteringDisplay.predefinedPrimaries[0] == [0.68, 0.32, 0.265, 0.69, 0.15, 0.06, 0.3127, 0.329])
    }

    @Test("LMS to BT.2020 keeps every neutral neutral and matches the matrices it is derived from")
    func lmsToBT2020() {
        let m = DoviIptConversion.lmsToBT2020
        for row in 0..<3 {
            #expect(abs(m[row * 3] + m[row * 3 + 1] + m[row * 3 + 2] - 1) < 1e-12, "row \(row) of LMS (1, 1, 1)")
        }
        // Computed separately: BT.2020 RGB to XYZ at D65 (0.3127, 0.3290), times the crosstalk-free
        // Hunt-Pointer-Estevez XYZ to LMS, inverted.
        let independent = [3.06441868, -2.16596473, 0.10154605, -0.65613855, 1.78557672, -0.12943816,
                           0.01736083, -0.04724472, 1.02988390]
        #expect(zip(m, independent).allSatisfy { abs($0 - $1) < 1e-7 })
        // BT.709's normalised primary matrix, the textbook values.
        let bt709 = ColourRepresentation.rgbToXYZ(primaries: 1)!.m.flatMap { $0 }
        #expect(zip(bt709, [0.4124, 0.3576, 0.1805, 0.2126, 0.7152, 0.0722, 0.0193, 0.1192, 0.9505])
            .allSatisfy { abs($0 - $1) < 1e-4 })
    }

    /// A real profile 5 title (`Fixtures/user`, never committed): its stills decode on VideoToolbox and come out of the
    /// composition, not as IPT read as Y'CbCr.
    static let sampleURL: URL? = {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/user")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().first { $0.localizedCaseInsensitiveContains("p5") }.map { directory.appendingPathComponent($0) }
    }()

    @Test("a real profile 5 title's still decodes on VideoToolbox and is composed",
          .enabled(if: DolbyVisionBaseLayerStillTests.sampleURL != nil))
    func realTitleStill() throws {
        let url = try #require(Self.sampleURL)
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let context = FrameDecodeContext(reader: DataIOReader(data: data), formatHint: url.pathExtension)
        defer { context.close() }
        try context.ensureOpen()
        #expect(context.isDolbyVisionNoBaseLayer)
        let image = try #require(context.decodeFrame(at: 10, mode: .thumbnail, targetWidth: 480, maxSize: nil,
                                                    isCancelled: { false }))
        #expect(context.hardwareDecoderName == "videotoolbox")
        #expect(image.width == 480)
    }
}
#endif
