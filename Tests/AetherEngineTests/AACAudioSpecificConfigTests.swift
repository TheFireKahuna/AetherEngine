import Testing
@testable import AetherEngine

/// ADTS AAC (an MPEG-TS, a raw .aac) carries no AudioSpecificConfig, and the fMP4 sample entry needs
/// one, so the engine writes the stream's own. HE-AAC and HE-AACv2 are written with explicit
/// hierarchical signalling, which tvOS decodes, so they stream-copy like any AAC rather than going
/// through the bridge.
///
/// libavcodec profiles: AAC_MAIN 0, AAC_LOW 1, AAC_HE 4, AAC_HE_V2 28.
@Suite("AAC AudioSpecificConfig")
struct AACAudioSpecificConfigTests {

    private func hex(_ bytes: [UInt8]?) -> String? {
        bytes.map { $0.map { String(format: "%02x", $0) }.joined() }
    }

    @Test("the object type follows libavcodec's profile, or SBR's 2048-sample frame without one")
    func objectType() {
        #expect(HLSVideoEngine.aacObjectType(profile: 1, frameSize: 1024) == 2)
        #expect(HLSVideoEngine.aacObjectType(profile: 0, frameSize: 1024) == 1)
        #expect(HLSVideoEngine.aacObjectType(profile: 4, frameSize: 2048) == 5)
        #expect(HLSVideoEngine.aacObjectType(profile: 28, frameSize: 2048) == 29)
        #expect(HLSVideoEngine.aacObjectType(profile: -99, frameSize: 2048) == 5)
        #expect(HLSVideoEngine.aacObjectType(profile: -99, frameSize: 1024) == 2)
    }

    @Test("AAC-LC: object type, rate and channel configuration in two bytes")
    func lowComplexity() {
        #expect(hex(HLSVideoEngine.audioSpecificConfig(objectType: 2, sampleRate: 48_000, frameSize: 1024, channels: 2)) == "1190")
        #expect(hex(HLSVideoEngine.audioSpecificConfig(objectType: 2, sampleRate: 44_100, frameSize: 1024, channels: 6)) == "1230")
        #expect(hex(HLSVideoEngine.audioSpecificConfig(objectType: 2, sampleRate: 48_000, frameSize: 1024, channels: 8)) == "11b8")
    }

    @Test("HE-AAC: SBR over an LC core at half the rate, the output rate as the extension rate")
    func highEfficiency() {
        // 5, core 24 kHz (6), stereo, output 48 kHz (3), LC, GASpecificConfig 000.
        #expect(hex(HLSVideoEngine.audioSpecificConfig(objectType: 5, sampleRate: 48_000, frameSize: 2048, channels: 2)) == "2b118800")
    }

    @Test("HE-AACv2: parametric stereo over a mono core")
    func highEfficiencyV2() {
        // 29, core 24 kHz (6), mono, output 48 kHz (3), LC, GASpecificConfig 000.
        #expect(hex(HLSVideoEngine.audioSpecificConfig(objectType: 29, sampleRate: 48_000, frameSize: 2048, channels: 2)) == "eb098800")
    }

    @Test("no configuration where the syntax has none")
    func unrepresentable() {
        #expect(HLSVideoEngine.audioSpecificConfig(objectType: 2, sampleRate: 48_000, frameSize: 1024, channels: 7) == nil)
        #expect(HLSVideoEngine.audioSpecificConfig(objectType: 2, sampleRate: 47_000, frameSize: 1024, channels: 2) == nil)
        #expect(HLSVideoEngine.audioSpecificConfig(objectType: 5, sampleRate: 14_000, frameSize: 2048, channels: 2) == nil)
    }
}
