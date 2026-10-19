// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import CoreMedia
import CoreVideo
import Foundation
import Dovi
@_spi(Diagnostics) @testable import AetherEngine

/// The composed-frame RPU override (`AetherEngine.felComposedRpuOverride`, a display-path experiment): a
/// composed frame carries the override in place of its converted RPU, in the same attachment form, and a
/// frame delivered as its raw base layer keeps the RPU with its mapping. Synthetic frames through the real
/// pairing and delivery path with a fake composer; the decoder's own override seam, not the process-wide
/// one, because other suites run alongside.
@Suite(.serialized, .offCooperativePoolOneLane, .timeLimit(.minutes(1)))
struct DoviComposedRpuOverrideTests {

    /// Completes every composition at once with its base layer, or fails every one.
    private final class FakeComposer: FelComposing, @unchecked Sendable {
        let fails: Bool
        init(fails: Bool) { self.fails = fails }
        func acquireSlot() {}
        func releaseSlot() {}
        func flush() {}
        func composeAsync(baseBuffer: CVPixelBuffer, enhancementBuffer: CVPixelBuffer, params: DoviMetalParams,
                          frameIndex: UInt32, completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
            completion(fails ? nil : baseBuffer)
        }
        func composeAsyncWithAcquiredSlot(baseBuffer: CVPixelBuffer, enhancementBuffer: CVPixelBuffer, params: DoviMetalParams,
                                          frameIndex: UInt32, completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
            completion(fails ? nil : baseBuffer)
        }
    }

    private final class Payloads: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Data?] = []
        func record(_ buffer: CVPixelBuffer) {
            let p = CVBufferCopyAttachment(buffer, DoviDisplayMetadata.rpuDataKey as CFString, nil) as? Data
            lock.lock(); items.append(p); lock.unlock()
        }
        var all: [Data?] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private static func buffer(width: Int, height: Int) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &out)
        return status == kCVReturnSuccess ? out : nil
    }

    /// The converted (composed) and mapping-kept (base-layer) RPUs of the FEL fixture, through the production
    /// conversion, plus a third libdovi-written RPU to override with: `fel_orig` rewritten unconverted (mode 0),
    /// which differs from both.
    private static func fixtureRpus() throws -> (composed: [UInt8], baseLayer: [UInt8], override: [UInt8]) {
        let nal = DoviComposedFrameRpuTests.felNAL
        let forms = nal.withUnsafeBufferPointer { buf -> (composed: [UInt8], baseLayer: [UInt8])? in
            guard let rpu = DoviRpuGuard.parse(buf.baseAddress!, buf.count) else { return nil }
            defer { dovi_rpu_free(rpu) }
            guard let out = DoviRpuConverter.dualLayerUnspec62(rpu, isFEL: true) else { return nil }
            defer { dovi_data_free(out.composed); dovi_data_free(out.baseLayer) }
            func bytes(_ d: UnsafePointer<DoviData>) -> [UInt8] { [UInt8](UnsafeBufferPointer(start: d.pointee.data, count: d.pointee.len)) }
            return (bytes(out.composed), bytes(out.baseLayer))
        }
        let (composed, baseLayer) = try #require(forms)
        let override = try #require(DoviComposedFrameRpuTests.converted(nal, mode: 0))
        try #require(override != composed && override != baseLayer)
        return (composed, baseLayer, override)
    }

    /// One frame through pairing, composition (or its failure) and delivery; the attachment it came out with.
    private static func deliverOneFrame(composerFails: Bool, override: [UInt8]?, composed: [UInt8], baseLayer: [UInt8]) async throws -> Data? {
        let payloads = Payloads()
        let decoder = DualLayerVideoDecoder(composer: FakeComposer(fails: composerFails))
        defer { decoder.close() }
        decoder.composedRpuOverrideForTesting = override
        decoder.onFrame = { buffer, _, _ in payloads.record(buffer) }
        decoder.primeForTesting(enhancementLayer: true)
        let pts = CMTime(value: 3754, timescale: 90000)
        decoder.seedRPUForTesting(pts: pts, params: DoviMetalParams(), displayMetadataNAL: composed, baseLayerNAL: baseLayer)
        decoder.handleEnhancementLayerFrame(elBuffer: try #require(buffer(width: 32, height: 32)), pts: pts)
        decoder.handleBaseLayerFrame(baseBuffer: try #require(buffer(width: 64, height: 64)), pts: pts, hdr10Data: nil)
        try await waitFor { payloads.all.count == 1 }
        return payloads.all.first ?? nil
    }

    @Test("A composed frame carries the override, in exactly the form the converted RPU is attached in")
    func composedFrameCarriesOverride() async throws {
        let (composed, baseLayer, override) = try Self.fixtureRpus()
        let plain = try await Self.deliverOneFrame(composerFails: false, override: nil, composed: composed, baseLayer: baseLayer)
        #expect(plain == Data(composed.dropFirst(2)), "without the override: the converted RPU, header stripped")

        let overridden = try #require(try await Self.deliverOneFrame(composerFails: false, override: override, composed: composed, baseLayer: baseLayer))
        #expect(overridden == Data(override.dropFirst(2)))
        // Same framing as the converted RPU: the RPU prefix first, emulation prevention kept, the trailing 0x80.
        #expect(overridden.first == 0x19 && plain?.first == 0x19)
        #expect(overridden.last == 0x80 && plain?.last == 0x80)
        #expect(DualLayerVideoDecoder.validatedRpuOverride(overridden) == override, "the attached payload parses back to the override")
    }

    @Test("A frame whose composition failed goes out as its base layer with the mapping-kept RPU, override or not")
    func failedCompositionKeepsBaseLayerRpu() async throws {
        let (composed, baseLayer, override) = try Self.fixtureRpus()
        let payload = try await Self.deliverOneFrame(composerFails: true, override: override, composed: composed, baseLayer: baseLayer)
        #expect(payload == Data(baseLayer.dropFirst(2)))
    }

    @Test("Validation takes a libdovi unspec62 NAL with or without its header and refuses anything libdovi cannot parse")
    func validation() throws {
        let (_, _, override) = try Self.fixtureRpus()
        #expect(DualLayerVideoDecoder.validatedRpuOverride(Data(override)) == override)
        #expect(DualLayerVideoDecoder.validatedRpuOverride(Data(override.dropFirst(2))) == override)
        #expect(DualLayerVideoDecoder.validatedRpuOverride(Data()) == nil)
        #expect(DualLayerVideoDecoder.validatedRpuOverride(Data([0x7C, 0x01])) == nil)
        #expect(DualLayerVideoDecoder.validatedRpuOverride(Data([0x00, 0x00, 0x00, 0x01] + override)) == nil, "an Annex-B start code is not stripped")
        var corrupt = override
        corrupt[corrupt.count / 2] ^= 0x55
        #expect(DualLayerVideoDecoder.validatedRpuOverride(Data(corrupt)) == nil, "a bad CRC never reaches libdovi")
    }

    @Test("The public switch refuses unparseable bytes and leaves the override off")
    func publicSwitchRefusesGarbage() {
        AetherEngine.felComposedRpuOverride = Data([0x7C, 0x01, 0x19, 0x00, 0x01, 0x02, 0x03, 0x04, 0x80])
        #expect(AetherEngine.felComposedRpuOverride == nil)
        #expect(DualLayerVideoDecoder.composedRpuOverride == nil)
    }
}
#endif
