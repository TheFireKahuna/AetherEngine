// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import CoreVideo
import Dovi
@testable import AetherEngine

/// The composed picture's range is the RPU's own: its colour conversion's luma offset says where black is (0 for a
/// full-range picture, 1/16 for video range), the output buffer's format states it, and the composed RPU the display
/// receives keeps the offsets that describe it. The composition clips to the code space, never to video range, so a
/// full-range picture keeps the codes below 64 and a video-range one its footroom and headroom.
@Suite("FEL composition follows the RPU's range")
struct DoviOutputRangeTests {
    typealias G = DoviRpuGuardTests
    typealias E = DoviGpuEdgeCaseTests

    static let fullRange: (UInt64, UInt64, UInt64) = (0, 1 << 27, 1 << 27)

    /// A Profile 7 FEL RPU whose display-management payload states `offsets`, or a compressed one that states none.
    static func rpu(offsets: (UInt64, UInt64, UInt64)?) -> [UInt8] {
        var dm = G.DMPayload(compressed: offsets == nil)
        if let offsets { dm.yccToRgbOffsets = offsets }
        return G.craft(pieces: [[.polynomial], [.mmr], [.mmr]], residual: .fel, dm: dm)
    }

    static func withRpu<T>(_ nal: [UInt8], _ body: (OpaquePointer) throws -> T) throws -> T {
        let rpu = try #require(nal.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) })
        defer { dovi_rpu_free(rpu) }
        return try body(rpu)
    }

    /// The luma offset of an unspec62 NAL's display-management data.
    static func lumaOffset(_ data: UnsafePointer<DoviData>) throws -> UInt32 {
        let nal = [UInt8](UnsafeBufferPointer(start: data.pointee.data, count: Int(data.pointee.len)))
        return try withRpu(nal) { rpu in
            let dm = try #require(dovi_rpu_get_vdr_dm_data(rpu))
            defer { dovi_rpu_free_vdr_dm_data(dm) }
            return dm.pointee.ycc_to_rgb_offset0
        }
    }

    @Test("the RPU's luma offset decides the range: 0 is full, 1/16 and an absent conversion are video range")
    func rangeFromTheOffset() throws {
        #expect(try Self.withRpu(Self.rpu(offsets: Self.fullRange)) { DoviFelComposer.outputFullRange(rpu: $0) })
        #expect(try !Self.withRpu(Self.rpu(offsets: (1 << 24, 1 << 27, 1 << 27))) { DoviFelComposer.outputFullRange(rpu: $0) })
        // A compressed payload leaves the conversion out, and libdovi's fields at zero: the defaults, video range.
        #expect(try !Self.withRpu(Self.rpu(offsets: nil)) { DoviFelComposer.outputFullRange(rpu: $0) })
        let params = try Self.withRpu(Self.rpu(offsets: Self.fullRange)) { DoviFelComposer.parseRpuParameters(rpu: $0) }
        #expect(params?.outputFullRange == true)
    }

    @Test("an offset that is neither range is composed as video range and logged once")
    func otherOffsetIsLogged() throws {
        let capture = EngineLogCapture()
        defer { capture.end() }
        DoviFelComposer.resetAssumptionLogForTesting()
        let odd = Self.rpu(offsets: (1 << 26, 1 << 29, 1 << 29))
        #expect(try !Self.withRpu(odd) { DoviFelComposer.outputFullRange(rpu: $0) })
        #expect(try !Self.withRpu(odd) { DoviFelComposer.outputFullRange(rpu: $0) })
        #expect(capture.matching("ycc_to_rgb_offset0 = \(1 << 26)").count == 1)
    }

    @Test("a full-range picture goes out as xf20 with its codes below 64; sv22, which has no full-range form, as P010",
          arguments: [DoviOutputMode.sv22, .p010])
    func fullRangeOutput(mode: DoviOutputMode) throws {
        let composer = try #require(DoviFelComposer())
        composer.outputModeOverride = mode
        var p = E.params(flags: [.disableResidual])
        p.outputFullRange = true
        let out = try E.composeConstant(composer, bl: (0, 512, 512), el: (512, 512, 512), params: p)
        #expect(CVPixelBufferGetPixelFormatType(out) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        #expect(E.lumaValues(out) == [0])
    }

    @Test("a video-range picture keeps its own format, its footroom and headroom passing")
    func videoRangeOutput() throws {
        let composer = try #require(DoviFelComposer())
        composer.outputModeOverride = .sv22
        let p = E.params(flags: [.disableResidual])
        let out = try E.composeConstant(composer, bl: (16, 512, 512), el: (512, 512, 512), params: p)
        #expect(CVPixelBufferGetPixelFormatType(out) == kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange)
        #expect(E.lumaValues(out) == [16])
    }

    @Test("the composed and base-layer 8.1 forms keep the RPU's own colour conversion",
          arguments: [(fullRange, UInt32(0)), ((1 << 24, 1 << 27, 1 << 27), UInt32(1 << 24))])
    func convertedFormsKeepTheOffsets(offsets: (UInt64, UInt64, UInt64), expected: UInt32) throws {
        try Self.withRpu(Self.rpu(offsets: offsets)) { rpu in
            let forms = try #require(DoviRpuConverter.dualLayerUnspec62(rpu, isFEL: true))
            defer { dovi_data_free(forms.composed); dovi_data_free(forms.baseLayer) }
            #expect(try Self.lumaOffset(forms.composed) == expected)
            #expect(try Self.lumaOffset(forms.baseLayer) == expected)
        }
    }
}
#endif
