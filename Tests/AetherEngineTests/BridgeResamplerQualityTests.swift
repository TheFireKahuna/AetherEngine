import Testing
import Foundation
import AetherLibavutil
import AetherLibswresample
@testable import AetherEngine

/// The bridge's resamplers were allocated with no options at all. libswresample only normalises a
/// downmix when the output is an integer format, so the E-AC-3 arm (FLTP) folded a 7.1 source's
/// sides into its backs at sqrt(1/2) on top of the backs' own unity and could hand the encoder
/// +4.6 dB over full scale, which the encoder clips. These run the production configuration.
@Suite("Bridge resampler quality options")
struct BridgeResamplerQualityTests {

    /// A 7.1 -> 5.1 resampler built exactly as the bridge builds one, then fed `frames` of input.
    private func downmixPeak(outputFormat: AVSampleFormat, inputLevel: Float) throws -> Float {
        var inLayout = AVChannelLayout()
        var outLayout = AVChannelLayout()
        av_channel_layout_default(&inLayout, 8)
        av_channel_layout_default(&outLayout, 6)
        defer {
            av_channel_layout_uninit(&inLayout)
            av_channel_layout_uninit(&outLayout)
        }
        var swr: OpaquePointer?
        #expect(swr_alloc_set_opts2(&swr, &outLayout, outputFormat, 48_000,
                                    &inLayout, AV_SAMPLE_FMT_FLT, 48_000, 0, nil) >= 0)
        defer { swr_free(&swr) }
        let ctx = try #require(swr)
        AudioBridge.applyResamplerQuality(ctx, outputFormat: outputFormat)
        #expect(swr_init(ctx) >= 0)

        let frames = 1024
        // Every channel at the same full-scale level and in phase: the worst case a downmix row sees.
        let capacity = frames + 64
        let input = UnsafeMutablePointer<Float>.allocate(capacity: frames * 8)
        input.initialize(repeating: inputLevel, count: frames * 8)
        let planes = (0..<6).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: capacity) }
        defer {
            input.deallocate()
            planes.forEach { $0.deallocate() }
        }
        var inPtrs: [UnsafePointer<UInt8>?] = [UnsafeRawPointer(input).assumingMemoryBound(to: UInt8.self)]
        var outPtrs: [UnsafeMutablePointer<UInt8>?] = planes.map {
            UnsafeMutableRawPointer($0).assumingMemoryBound(to: UInt8.self)
        }
        let produced = swr_convert(ctx, &outPtrs, Int32(capacity), &inPtrs, Int32(frames))
        #expect(produced > 0)
        return planes.map { plane in
            (0..<Int(max(produced, 0))).map { abs(plane[$0]) }.max() ?? 0
        }.max() ?? 0
    }

    @Test("a full-scale 7.1 source folded to 5.1 for E-AC-3 never exceeds full scale")
    func sevenOneToFiveOneDoesNotClip() throws {
        let peak = try downmixPeak(outputFormat: AV_SAMPLE_FMT_FLTP, inputLevel: 1.0)
        #expect(peak <= 1.0 + 1e-6, "the downmix peaks at \(peak)")
        #expect(peak > 0.5, "normalised, not muted")
    }

    @Test("the options the bridge relies on are set before init")
    func optionsAreApplied() throws {
        var layout = AVChannelLayout()
        av_channel_layout_default(&layout, 2)
        defer { av_channel_layout_uninit(&layout) }
        var swr: OpaquePointer?
        #expect(swr_alloc_set_opts2(&swr, &layout, AV_SAMPLE_FMT_S16, 48_000,
                                    &layout, AV_SAMPLE_FMT_S32, 96_000, 0, nil) >= 0)
        defer { swr_free(&swr) }
        let ctx = try #require(swr)
        AudioBridge.applyResamplerQuality(ctx, outputFormat: AV_SAMPLE_FMT_S16)
        let raw = UnsafeMutableRawPointer(ctx)
        var maxval: Double = 0
        var filterSize: Int64 = 0
        var dither: Int64 = 0
        #expect(av_opt_get_double(raw, "rematrix_maxval", 0, &maxval) >= 0)
        #expect(av_opt_get_int(raw, "filter_size", 0, &filterSize) >= 0)
        #expect(av_opt_get_int(raw, "dither_method", 0, &dither) >= 0)
        #expect(maxval == 1.0)
        #expect(filterSize == 64)
        #expect(dither == Int64(SWR_DITHER_TRIANGULAR_HIGHPASS.rawValue))
        #expect(swr_init(ctx) >= 0)
    }

    @Test("a 16-bit source into a 16-bit output is passed through untouched despite the dither")
    func sixteenBitPassThroughStaysBitExact() throws {
        var layout = AVChannelLayout()
        av_channel_layout_default(&layout, 2)
        defer { av_channel_layout_uninit(&layout) }
        var swr: OpaquePointer?
        #expect(swr_alloc_set_opts2(&swr, &layout, AV_SAMPLE_FMT_S16, 48_000,
                                    &layout, AV_SAMPLE_FMT_S16P, 48_000, 0, nil) >= 0)
        defer { swr_free(&swr) }
        let ctx = try #require(swr)
        AudioBridge.applyResamplerQuality(ctx, outputFormat: AV_SAMPLE_FMT_S16)
        #expect(swr_init(ctx) >= 0)

        let frames = 2048
        var state: UInt32 = 12_345
        let source = (0..<(frames * 2)).map { _ -> Int16 in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Int16(truncatingIfNeeded: state >> 16)
        }
        let left = UnsafeMutablePointer<Int16>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Int16>.allocate(capacity: frames)
        let out = UnsafeMutablePointer<Int16>.allocate(capacity: frames * 2)
        defer { left.deallocate(); right.deallocate(); out.deallocate() }
        for i in 0..<frames { left[i] = source[i * 2]; right[i] = source[i * 2 + 1] }
        var inPtrs: [UnsafePointer<UInt8>?] = [left, right].map {
            UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self)
        }
        var outPtrs: [UnsafeMutablePointer<UInt8>?] = [UnsafeMutableRawPointer(out).assumingMemoryBound(to: UInt8.self)]
        let produced = swr_convert(ctx, &outPtrs, Int32(frames), &inPtrs, Int32(frames))
        #expect(produced == Int32(frames))
        #expect(Array(UnsafeBufferPointer(start: out, count: frames * 2)) == source)
    }

    @Test("a 24-bit path is never dithered, so it stays bit-exact")
    func noDitherAboveSixteenBits() throws {
        var layout = AVChannelLayout()
        av_channel_layout_default(&layout, 2)
        defer { av_channel_layout_uninit(&layout) }
        var swr: OpaquePointer?
        #expect(swr_alloc_set_opts2(&swr, &layout, AV_SAMPLE_FMT_S32, 48_000,
                                    &layout, AV_SAMPLE_FMT_S32, 48_000, 0, nil) >= 0)
        defer { swr_free(&swr) }
        let ctx = try #require(swr)
        AudioBridge.applyResamplerQuality(ctx, outputFormat: AV_SAMPLE_FMT_S32)
        var dither: Int64 = -1
        #expect(av_opt_get_int(UnsafeMutableRawPointer(ctx), "dither_method", 0, &dither) >= 0)
        #expect(dither == 0)
    }
}
