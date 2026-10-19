import CoreGraphics
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// Bitmap subtitles are authored at the disc's resolution (PGS 1080p, DVD 480p) and drawn into
/// frames up to 4K, 2x for PGS and 4.5x for DVD. The CGImage was created with
/// `shouldInterpolate: false`, asking every consumer for nearest-neighbour stairs. Measured on
/// macOS 27, a bitmap `CGContext` ignores that flag (only `interpolationQuality = .none` gives
/// nearest; `.default` through `.high` give the same filtered ramp), so the PiP compositor was
/// already smooth there; the flag still reaches hosts that draw `SubtitleImage.cgImage` through
/// other paths, and the compositor now asks for `.high` explicitly instead of relying on the default.
struct BitmapSubtitleScalingTests {

    /// A decoder-made image: a 4x4 opaque white square inside a one-pixel ring at alpha 8 (the
    /// decoder's visibility threshold), so the 6x6 crop has a hard white-to-near-transparent edge.
    /// The palette is libavcodec's [B, G, R, A].
    private func whiteSquare() throws -> SubtitleImage {
        var pixels = [UInt8](repeating: 0, count: 8 * 8)
        for i in 1..<7 { pixels[1 * 8 + i] = 2; pixels[6 * 8 + i] = 2; pixels[i * 8 + 1] = 2; pixels[i * 8 + 6] = 2 }
        for y in 2..<6 { for x in 2..<6 { pixels[y * 8 + x] = 1 } }
        var palette = [UInt8](repeating: 0, count: 256 * 4)
        palette[4] = 255; palette[5] = 255; palette[6] = 255; palette[7] = 255
        palette[8] = 255; palette[9] = 255; palette[10] = 255; palette[11] = 8
        return try pixels.withUnsafeMutableBufferPointer { px in
            try palette.withUnsafeMutableBufferPointer { pal in
                var rect = AVSubtitleRect()
                rect.type = SUBTITLE_BITMAP
                rect.w = 8; rect.h = 8; rect.linesize.0 = 8
                rect.data.0 = px.baseAddress
                rect.data.1 = pal.baseAddress
                return try #require(withUnsafeMutablePointer(to: &rect) {
                    EmbeddedSubtitleDecoder.imageForSubtitleRect($0, videoWidth: 8, videoHeight: 8)
                })
            }
        }
    }

    /// RGBA bytes of `image` drawn 1:1 into a premultiplied RGBA context.
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = try #require(out.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        })
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return out
    }

    @Test("decoded bitmap subtitles allow interpolation")
    func decoderImageInterpolates() throws {
        #expect(try whiteSquare().cgImage.shouldInterpolate)
    }

    @Test("an upscaled bitmap cue is resampled smoothly, not pixel-doubled")
    func compositorUpscalesSmoothly() throws {
        let image = try whiteSquare()
        // A 6x6 crop normalized to an 8x8 frame, drawn into a 64x64 frame: 8x upscale.
        let cue = SubtitleCue(id: 1, startTime: 0, endTime: 1, body: .image(image))
        let overlay = try #require(SubtitleFrameCompositor.renderOverlay(for: [cue], frameWidth: 64, frameHeight: 64))
        let bytes = try rgba(overlay)
        let alphas = Set(stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] })
        // Nearest-neighbour gives exactly {0, 8, 255}; a filtered upscale ramps between them.
        #expect(alphas.count > 6, "alpha values: \(alphas.sorted())")
    }

    /// The palette is premultiplied before the blit, so a filtered edge blends white into
    /// transparent black and stays white once unpremultiplied. A straight-alpha source would show
    /// a dark fringe.
    @Test("interpolated edges stay clean: no dark or tinted fringe")
    func interpolatedEdgesStayWhite() throws {
        let image = try whiteSquare()
        let cue = SubtitleCue(id: 1, startTime: 0, endTime: 1, body: .image(image))
        let overlay = try #require(SubtitleFrameCompositor.renderOverlay(for: [cue], frameWidth: 64, frameHeight: 64))
        let bytes = try rgba(overlay)
        for p in stride(from: 0, to: bytes.count, by: 4) where bytes[p + 3] > 0 {
            let a = Int(bytes[p + 3])
            for c in 0..<3 {
                #expect(abs(Int(bytes[p + c]) - a) <= 2, "pixel \(p / 4): \(bytes[p..<(p + 4)].map { $0 })")
            }
        }
    }
}
