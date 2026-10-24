import Foundation
import CoreVideo
import Metal
import Testing
import AetherLibavutil
@testable import AetherEngine

/// The GPU finisher against a double-precision reference of docs/colour-representation.md (H.273), on random
/// pictures. Source samples are read through FFmpeg's own `av_read_image_line2`, so the kernel's reader is
/// checked against FFmpeg's definition of every layout. Integer paths (pack, grey, the dither) must match word
/// for word; the real-valued ones (resampled chroma, RGB) too, except where the reference value lies within
/// 1e-4 of a rounding tie (RGB is evaluated in 2^-30 fixed point).
@Suite("Planar frame finisher writes H.273's values")
struct PlanarFrameFinisherTests {

    struct Case: CustomStringConvertible, @unchecked Sendable {
        var format: AVPixelFormat
        var range: AVColorRange = AVCOL_RANGE_MPEG
        var tenBitStream = false
        var sv22 = false
        var location: AVChromaLocation = AVCHROMA_LOC_LEFT
        var matrix: CFString = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        var description: String {
            "\(String(cString: av_get_pix_fmt_name(format))) range=\(range.rawValue)\(tenBitStream ? " 10-bit stream" : "")"
                + "\(sv22 ? " sv22" : "") loc=\(location.rawValue) \(matrix)"
        }
    }

    static let cases: [Case] = [
        // Same subsampling: a shift (video range) or H.273's (2^n - 1) scaling (full range).
        Case(format: AV_PIX_FMT_YUV420P), Case(format: AV_PIX_FMT_YUV420P, tenBitStream: true),
        Case(format: AV_PIX_FMT_YUV420P10LE), Case(format: AV_PIX_FMT_YUV420P10BE),
        Case(format: AV_PIX_FMT_YUV420P12LE), Case(format: AV_PIX_FMT_YUV420P16LE),
        Case(format: AV_PIX_FMT_YUV422P), Case(format: AV_PIX_FMT_YUV444P),
        Case(format: AV_PIX_FMT_YUV422P10LE), Case(format: AV_PIX_FMT_YUV444P10LE),
        Case(format: AV_PIX_FMT_YUV422P12LE), Case(format: AV_PIX_FMT_YUV444P12LE),
        Case(format: AV_PIX_FMT_NV12), Case(format: AV_PIX_FMT_P010LE),
        Case(format: AV_PIX_FMT_YUYV422), Case(format: AV_PIX_FMT_UYVY422),
        Case(format: AV_PIX_FMT_YUVA420P), Case(format: AV_PIX_FMT_YUVA444P10LE),
        Case(format: AV_PIX_FMT_YUVJ420P, range: AVCOL_RANGE_JPEG),
        Case(format: AV_PIX_FMT_YUV420P, range: AVCOL_RANGE_JPEG, tenBitStream: true),
        Case(format: AV_PIX_FMT_YUV420P10LE, range: AVCOL_RANGE_JPEG),
        Case(format: AV_PIX_FMT_YUV422P12LE, range: AVCOL_RANGE_JPEG),
        Case(format: AV_PIX_FMT_YUV420P12LE, range: AVCOL_RANGE_JPEG),
        // Grey.
        Case(format: AV_PIX_FMT_GRAY8), Case(format: AV_PIX_FMT_GRAY10LE), Case(format: AV_PIX_FMT_GRAY12LE),
        Case(format: AV_PIX_FMT_YA8), Case(format: AV_PIX_FMT_GRAY8, range: AVCOL_RANGE_JPEG, tenBitStream: true),
        // Chroma resampled to the output's subsampling.
        Case(format: AV_PIX_FMT_YUV420P12LE, sv22: true),
        Case(format: AV_PIX_FMT_YUV420P12LE, sv22: true, location: AVCHROMA_LOC_TOPLEFT),
        Case(format: AV_PIX_FMT_YUV420P12LE, sv22: true, location: AVCHROMA_LOC_BOTTOM),
        Case(format: AV_PIX_FMT_YUV411P), Case(format: AV_PIX_FMT_YUV411P, location: AVCHROMA_LOC_CENTER),
        Case(format: AV_PIX_FMT_YUV440P), Case(format: AV_PIX_FMT_YUV410P),
        Case(format: AV_PIX_FMT_YUVJ411P, range: AVCOL_RANGE_JPEG),
        // RGB and palette, encoded at video range with the tagged matrix.
        Case(format: AV_PIX_FMT_GBRP), Case(format: AV_PIX_FMT_GBRP10LE), Case(format: AV_PIX_FMT_GBRP12LE),
        Case(format: AV_PIX_FMT_GBRP, range: AVCOL_RANGE_MPEG),
        Case(format: AV_PIX_FMT_GBRP, range: AVCOL_RANGE_JPEG, matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4),
        Case(format: AV_PIX_FMT_GBRP10LE, range: AVCOL_RANGE_JPEG, matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020),
        Case(format: AV_PIX_FMT_RGB24, range: AVCOL_RANGE_JPEG), Case(format: AV_PIX_FMT_BGRA, range: AVCOL_RANGE_JPEG),
        Case(format: AV_PIX_FMT_RGB565LE, range: AVCOL_RANGE_JPEG), Case(format: AV_PIX_FMT_X2RGB10LE, range: AVCOL_RANGE_JPEG),
        Case(format: AV_PIX_FMT_RGB48BE, range: AVCOL_RANGE_JPEG), Case(format: AV_PIX_FMT_PAL8),
    ]

    @Test("GPU output equals the H.273 reference", arguments: cases.indices, [(35, 9), (66, 34)])
    func matchesReference(_ index: Int, _ size: (Int, Int)) throws {
        try run(Self.cases[index], width: size.0, height: size.1)
    }

    @Test("GPU output equals the H.273 reference at 1080p",
          arguments: [Case(format: AV_PIX_FMT_YUV420P10LE), Case(format: AV_PIX_FMT_YUV420P12LE),
                      Case(format: AV_PIX_FMT_YUV420P12LE, sv22: true), Case(format: AV_PIX_FMT_GBRP)])
    func matchesReferenceAt1080p(_ c: Case) throws {
        try run(c, width: 1920, height: 1080)
    }

    @Test("formats outside H.273's code definitions are refused")
    func refusals() {
        #expect(!PlanarFrameFinisher.reads(AV_PIX_FMT_MONOBLACK), "grey below 8 bits")
        #expect(!PlanarFrameFinisher.reads(AV_PIX_FMT_GRAYF32LE), "float samples")
        #expect(!PlanarFrameFinisher.reads(AV_PIX_FMT_BAYER_RGGB8), "Bayer")
        #expect(!PlanarFrameFinisher.reads(AV_PIX_FMT_XYZ12LE), "XYZ")
        #expect(!PlanarFrameFinisher.reads(AV_PIX_FMT_VIDEOTOOLBOX), "hardware")
        #expect(PlanarFrameFinisher.reads(AV_PIX_FMT_RGB4), "RGB at any depth decodes through its range")
        // An interlaced picture is never resampled vertically.
        let out = SoftwareVideoDecoder.OutputFormat(chroma: .yuv444, depth: .eight, fullRange: false)
        #expect(PlanarFrameFinisher.plan(source: AV_PIX_FMT_YUV440P, output: out, sourceFullRange: false,
                                         chromaLocation: AVCHROMA_LOC_LEFT, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                                         interlaced: true) == nil)
    }

    @Test("the dither keeps a 12-bit level's mean in 10-bit codes")
    func ditherKeepsTheMean() throws {
        // 12-bit 2049 is 10-bit 512.25: a quarter of each 8x8 cell rounds up.
        let words = try finishFlat(AV_PIX_FMT_YUV420P12LE, value: 2049)
        #expect(words.allSatisfy { $0 & 0x3F == 0 })
        let codes = words.map { Int($0 >> 6) }
        #expect(Set(codes) == [512, 513])
        #expect(Double(codes.filter { $0 == 513 }.count) / Double(codes.count) == 0.25)
    }

    // MARK: - Harness

    private func finishFlat(_ format: AVPixelFormat, value: UInt16) throws -> [UInt16] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let allocator = try #require(DecodeFrameAllocator(device: device))
        let finisher = try PlanarFrameFinisher(device: device)
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        let f = try #require(frame)
        f.pointee.width = 64; f.pointee.height = 64; f.pointee.format = format.rawValue
        #expect(av_frame_get_buffer(f, 0) >= 0)
        let y = UnsafeMutableRawPointer(try #require(f.pointee.data.0))
        for i in 0..<(Int(f.pointee.linesize.0) * 64 / 2) { y.storeBytes(of: value, toByteOffset: 2 * i, as: UInt16.self) }
        let output = SoftwareVideoDecoder.outputFormat(pixelFormat: format.rawValue, colorRange: AVCOL_RANGE_MPEG, streamIs10Bit: true)
        let plan = try #require(PlanarFrameFinisher.plan(source: format, output: output, sourceFullRange: false,
                                                         chromaLocation: AVCHROMA_LOC_LEFT, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2))
        let planes = try #require(allocator.copy(f))
        defer { allocator.release(planes.slab) }
        let pb = try makeBuffer(output, width: 64, height: 64)
        #expect(finisher.finish(planes, plan: plan, width: 64, height: 64, into: pb))
        return readPlane(pb, plane: 0).map { UInt16($0) }
    }

    private func makeBuffer(_ format: SoftwareVideoDecoder.OutputFormat, width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: NSDictionary = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format.pixelFormatType, attrs, &pb)
        return try #require(pb)
    }

    /// Every sample of `plane`, row-major (chroma interleaved Cb, Cr).
    private func readPlane(_ pb: CVPixelBuffer, plane: Int) -> [Int] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let wide = CVPixelBufferGetBytesPerRowOfPlane(pb, plane) >= CVPixelBufferGetWidthOfPlane(pb, plane) * (plane == 0 ? 2 : 4)
            && [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
                kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
                kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange]
                .contains(CVPixelBufferGetPixelFormatType(pb))
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!, stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
        let samples = CVPixelBufferGetWidthOfPlane(pb, plane) * (plane == 0 ? 1 : 2)
        var out: [Int] = []
        for y in 0..<CVPixelBufferGetHeightOfPlane(pb, plane) {
            for x in 0..<samples {
                out.append(wide ? Int(base.load(fromByteOffset: y * stride + 2 * x, as: UInt16.self))
                                : Int(base.load(fromByteOffset: y * stride + x, as: UInt8.self)))
            }
        }
        return out
    }

    private func run(_ c: Case, width: Int, height: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let allocator = try #require(DecodeFrameAllocator(device: device))
        let finisher = try PlanarFrameFinisher(device: device)

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        let f = try #require(frame)
        f.pointee.width = Int32(width); f.pointee.height = Int32(height); f.pointee.format = c.format.rawValue
        f.pointee.color_range = c.range
        #expect(av_frame_get_buffer(f, 0) >= 0)
        var rng = SystemRandomNumberGenerator()
        withUnsafeBytes(of: f.pointee.buf) { bufs in
            for ref in bufs.bindMemory(to: UnsafeMutablePointer<AVBufferRef>?.self) {
                guard let ref, let data = ref.pointee.data else { continue }
                for i in 0..<ref.pointee.size { data[i] = UInt8.random(in: 0...255, using: &rng) }
            }
        }

        let output = SoftwareVideoDecoder.outputFormat(pixelFormat: c.format.rawValue, colorRange: c.range,
                                                       streamIs10Bit: c.tenBitStream, twelveBit420: c.sv22 ? .sv22 : .p010Dithered)
        let desc = try #require(av_pix_fmt_desc_get(c.format)).pointee
        let isRGB = desc.flags & UInt64(AV_PIX_FMT_FLAG_RGB) != 0
        let sourceFullRange = isRGB ? c.range != AVCOL_RANGE_MPEG : output.fullRange
        let plan = try #require(PlanarFrameFinisher.plan(source: c.format, output: output, sourceFullRange: sourceFullRange,
                                                         chromaLocation: c.location, matrix: c.matrix), "\(c)")
        let planes = try #require(allocator.copy(f))
        defer { allocator.release(planes.slab) }
        let pb = try makeBuffer(output, width: width, height: height)
        #expect(finisher.finish(planes, plan: plan, width: width, height: height, into: pb), "\(c)")

        let reference = Reference(frame: f, desc: desc, output: output, sourceFullRange: sourceFullRange,
                                  location: c.location, matrix: c.matrix)
        for plane in 0..<2 {
            let got = readPlane(pb, plane: plane)
            let expected = reference.plane(plane)
            #expect(got.count == expected.count)
            var mismatches = 0, first = ""
            for i in 0..<min(got.count, expected.count) where got[i] != expected[i].word {
                if expected[i].nearTie, abs(got[i] - expected[i].word) <= expected[i].step { continue }
                if mismatches == 0 { first = "sample \(i): got \(got[i]) expected \(expected[i].word) (real \(expected[i].real))" }
                mismatches += 1
            }
            #expect(mismatches == 0, "\(c) \(width)x\(height) plane \(plane): \(mismatches) differ, first \(first)")
        }
    }

    // MARK: - Reference

    /// docs/colour-representation.md, in Double, reading through av_read_image_line2.
    struct Reference {
        struct Word { var word: Int; var real: Double; var nearTie: Bool; var step: Int }

        let frame: UnsafeMutablePointer<AVFrame>
        let desc: AVPixFmtDescriptor
        let output: SoftwareVideoDecoder.OutputFormat
        let sourceFullRange: Bool
        let location: AVChromaLocation
        let matrix: CFString

        var width: Int { Int(frame.pointee.width) }
        var height: Int { Int(frame.pointee.height) }
        var targetBits: Int { output.depth == .eight ? 8 : (output.depth == .ten ? 10 : 16) }
        var fractionBits: Int { output.dithers ? 6 : 0 }
        var containerShift: Int { output.depth == .ten && !output.dithers ? 6 : 0 }
        var wordMax: Int { targetBits + fractionBits >= 16 ? 0xFFFF : (1 << (targetBits + fractionBits)) - 1 }
        var isPalette: Bool { desc.flags & UInt64(AV_PIX_FMT_FLAG_PAL) != 0 }
        var isRGB: Bool { !isPalette && desc.flags & UInt64(AV_PIX_FMT_FLAG_RGB) != 0 }
        var isGray: Bool { !isPalette && !isRGB && desc.nb_components < 3 }
        var outLog2: (Int, Int) { output.chroma == .yuv420 ? (1, 1) : (output.chroma == .yuv422 ? (1, 0) : (0, 0)) }
        func depth(_ c: Int) -> Int { Int(withUnsafeBytes(of: desc.comp) { $0.bindMemory(to: AVComponentDescriptor.self)[c].depth }) }

        func read(_ c: Int, _ x: Int, _ y: Int) -> Int {
            var value: UInt32 = 0
            var d = desc
            withUnsafeMutablePointer(to: &frame.pointee.data) { dp in
                withUnsafePointer(to: &frame.pointee.linesize) { lp in
                    av_read_image_line2(&value, UnsafeMutableRawPointer(dp).assumingMemoryBound(to: UnsafePointer<UInt8>?.self),
                                        UnsafeRawPointer(lp).assumingMemoryBound(to: Int32.self), &d,
                                        Int32(x), Int32(y), Int32(c), 1, 0, 4)
                }
            }
            return Int(value)
        }

        static let bayer: [Int] = [
             0, 32,  8, 40,  2, 34, 10, 42,  48, 16, 56, 24, 50, 18, 58, 26,
            12, 44,  4, 36, 14, 46,  6, 38,  60, 28, 52, 20, 62, 30, 54, 22,
             3, 35, 11, 43,  1, 33,  9, 41,  51, 19, 59, 27, 49, 17, 57, 25,
            15, 47,  7, 39, 13, 45,  5, 37,  63, 31, 55, 23, 61, 29, 53, 21,
        ]

        func container(_ w: Int, wordX: Int, y: Int) -> Int {
            guard fractionBits > 0 else { return w << containerShift }
            let sum = w + Self.bayer[(y & 7) * 8 + (wordX & 7)]
            return sum > 0xFFFF ? 0xFFC0 : sum & 0xFFC0
        }

        /// An exact integer code at T bits with F fraction bits (section 1).
        func exact(_ v: Int, depth d: Int, chroma: Bool) -> Int {
            let T = targetBits, F = fractionBits
            guard sourceFullRange else { return v << (T + F - d) }
            let num = (1 << T) - 1, den = (1 << d) - 1
            if !chroma { return min((2 * v * num * (1 << F) + den) / (2 * den), wordMax) }
            let n = 2 * (v - (1 << (d - 1))) * num * (1 << F) + 2 * (1 << (T - 1)) * (1 << F) * den + den
            return n <= 0 ? 0 : min(n / (2 * den), wordMax)
        }

        func rounded(_ x: Double) -> Word {
            let r = Int(min(max((x + 0.5).rounded(.down), 0), Double(wordMax)))
            let frac = x - x.rounded(.down)
            return Word(word: r, real: x, nearTie: abs(frac - 0.5) < 1e-4, step: 1)
        }

        func site(_ i: Double, log2: Int, vertical: Bool) -> Double {
            let span = Double(1 << log2) - 1, l = location.rawValue
            let offset: Double = !vertical
                ? ([1, 3, 5].contains(l) ? 0 : span / 2)
                : ([3, 4].contains(l) ? 0 : ([5, 6].contains(l) ? span : span / 2))
            return i * Double(1 << log2) + offset
        }

        func cubic(_ t: Double) -> [Double] {
            let t2 = t * t, t3 = t2 * t
            return [(-t3 + 2 * t2 - t) / 2, (3 * t3 - 5 * t2 + 2) / 2, (-3 * t3 + 4 * t2 + t) / 2, (t3 - t2) / 2]
        }

        func resampled(_ c: Int, ox: Int, oy: Int) -> Double {
            let sw = Int(desc.log2_chroma_w), sh = Int(desc.log2_chroma_h)
            let srcW = (width + (1 << sw) - 1) >> sw, srcH = (height + (1 << sh) - 1) >> sh
            let ux = (site(Double(ox), log2: outLog2.0, vertical: false) - site(0, log2: sw, vertical: false)) / Double(1 << sw)
            let uy = (site(Double(oy), log2: outLog2.1, vertical: true) - site(0, log2: sh, vertical: true)) / Double(1 << sh)
            let x0 = Int(ux.rounded(.down)), y0 = Int(uy.rounded(.down))
            let wx = sw == outLog2.0 ? [0, 1, 0, 0] : cubic(ux - ux.rounded(.down))
            let wy = sh == outLog2.1 ? [0, 1, 0, 0] : cubic(uy - uy.rounded(.down))
            var sum = 0.0
            for j in 0..<4 where wy[j] != 0 {
                let sy = min(max(y0 - 1 + j, 0), srcH - 1)
                for i in 0..<4 where wx[i] != 0 {
                    sum += wy[j] * wx[i] * Double(read(c, min(max(x0 - 1 + i, 0), srcW - 1), sy))
                }
            }
            return sum
        }

        func resampledWord(_ value: Double, depth d: Int) -> Word {
            let c = min(max(value, 0), Double((1 << d) - 1))
            let T = Double(targetBits), scale = Double(1 << fractionBits)
            let x = sourceFullRange
                ? ((c - pow(2, Double(d - 1))) * (pow(2, T) - 1) / (pow(2, Double(d)) - 1) + pow(2, T - 1)) * scale
                : c * pow(2, T - Double(d)) * scale
            // The kernel resamples in exact integers (weights n / 1024 per axis), as this does in Double: no allowance.
            var w = rounded(x)
            w.nearTie = false
            return w
        }

        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            func e(_ code: Int, _ d: Int, full: Bool) -> Double {
                full ? Double(code) / (pow(2, Double(d)) - 1) : (Double(code) / pow(2, Double(d - 8)) - 16) / 219
            }
            if isPalette {
                let index = read(0, x, y)
                let entry = frame.pointee.data.1!.withMemoryRebound(to: UInt32.self, capacity: 256) { $0[index] }
                return (e(Int((entry >> 16) & 0xFF), 8, full: true), e(Int((entry >> 8) & 0xFF), 8, full: true),
                        e(Int(entry & 0xFF), 8, full: true))
            }
            return (e(read(0, x, y), depth(0), full: sourceFullRange), e(read(1, x, y), depth(1), full: sourceFullRange),
                    e(read(2, x, y), depth(2), full: sourceFullRange))
        }

        func rgbWords(_ x: Int, _ y: Int) -> (Word, Word, Word) {
            let (kr, kb) = PlanarFrameFinisher.coefficients(matrix)
            let (r, g, b) = rgb(x, y)
            let ey = kr * r + (1 - kr - kb) * g + kb * b
            let pb = 0.5 * (b - ey) / (1 - kb), pr = 0.5 * (r - ey) / (1 - kr)
            let n = Double(targetBits), scale = Double(1 << fractionBits)
            if output.fullRange {
                return (rounded((pow(2, n) - 1) * ey * scale), rounded(((pow(2, n) - 1) * pb + pow(2, n - 1)) * scale),
                        rounded(((pow(2, n) - 1) * pr + pow(2, n - 1)) * scale))
            }
            let k = pow(2, n - 8)
            return (rounded(k * (219 * ey + 16) * scale), rounded(k * (224 * pb + 128) * scale), rounded(k * (224 * pr + 128) * scale))
        }

        func plane(_ p: Int) -> [Word] {
            var out: [Word] = []
            if p == 0 {
                for y in 0..<height {
                    for x in 0..<width {
                        var w = isRGB || isPalette ? rgbWords(x, y).0 : Word(word: exact(read(0, x, y), depth: depth(0), chroma: false), real: 0, nearTie: false, step: 0)
                        w.word = container(w.word, wordX: x, y: y)
                        w.step = 1 << (fractionBits > 0 ? 6 : containerShift)
                        out.append(w)
                    }
                }
                return out
            }
            let cw = (width + (1 << outLog2.0) - 1) >> outLog2.0, ch = (height + (1 << outLog2.1) - 1) >> outLog2.1
            for y in 0..<ch {
                for x in 0..<cw {
                    var cb: Word, cr: Word
                    if isGray {
                        cb = Word(word: 1 << (targetBits - 1 + fractionBits), real: 0, nearTie: false, step: 0); cr = cb
                    } else if isRGB || isPalette {
                        let words = rgbWords(x, y); cb = words.1; cr = words.2
                    } else if Int(desc.log2_chroma_w) == outLog2.0 && Int(desc.log2_chroma_h) == outLog2.1 {
                        cb = Word(word: exact(read(1, x, y), depth: depth(1), chroma: true), real: 0, nearTie: false, step: 0)
                        cr = Word(word: exact(read(2, x, y), depth: depth(2), chroma: true), real: 0, nearTie: false, step: 0)
                    } else {
                        cb = resampledWord(resampled(1, ox: x, oy: y), depth: depth(1))
                        cr = resampledWord(resampled(2, ox: x, oy: y), depth: depth(2))
                    }
                    cb.word = container(cb.word, wordX: 2 * x, y: y)
                    cr.word = container(cr.word, wordX: 2 * x + 1, y: y)
                    cb.step = 1 << (fractionBits > 0 ? 6 : containerShift); cr.step = cb.step
                    out.append(cb); out.append(cr)
                }
            }
            return out
        }
    }
}
