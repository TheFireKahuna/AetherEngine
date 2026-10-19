#if DualLayerDolbyVision
import Foundation
@_spi(Diagnostics) import AetherEngine

/// Sets `AetherEngine.felOutputMode` from `--fel-output`, or exits 64 on an unknown mode.
func applyFelOutputFlag(_ spec: String?) {
    guard let spec else { return }
    guard let mode = AetherEngine.FelOutputMode(rawValue: spec) else {
        let modes = AetherEngine.FelOutputMode.allCases.map(\.rawValue).joined(separator: ", ")
        print("ERROR: --fel-output takes one of \(modes), got '\(spec)'")
        exit(64)
    }
    AetherEngine.felOutputMode = mode
    print("[aetherctl] FEL output: \(mode.rawValue)")
}

/// Sets `AetherEngine.felComposedRpuOverride` from `--fel-rpu-override <file>` (one unspec62 RPU NAL, as
/// `dovi_write_unspec62_nalu` writes it), or exits 64 on a file it cannot read or libdovi cannot parse.
func applyFelRpuOverrideFlag(_ path: String?) {
    guard let path else { return }
    guard let bytes = FileManager.default.contents(atPath: path) else {
        print("ERROR: --fel-rpu-override cannot read '\(path)'")
        exit(64)
    }
    AetherEngine.felComposedRpuOverride = bytes
    guard let nal = AetherEngine.felComposedRpuOverride else {
        print("ERROR: --fel-rpu-override: '\(path)' (\(bytes.count) bytes) does not parse as a Dolby Vision unspec62 RPU NAL")
        exit(64)
    }
    print("[aetherctl] FEL composed-frame RPU override: \(path), \(nal.count) bytes")
}

/// Standalone test runner for Dolby Vision Profile 7 FEL dual-layer decoding and Metal reconstruction.
func runFelTest(url: URL, maxFrames: Int = 100, probePoint: (x: Int, y: Int)? = nil) -> Int32 {
    print("==================================================")
    print("aetherctl feltest: Dolby Vision Profile 7 FEL Engine")
    print("Source: \(url.path)")
    print("Max frames to test: \(maxFrames)")
    print("==================================================")

    let result: FelProbeResult
    do {
        result = try AetherEngine.felDecodeProbe(url: url, maxPackets: maxFrames, probePoint: probePoint)
    } catch {
        print("ERROR: felDecodeProbe failed: \(error)")
        return 1
    }

    print("")
    print("=== DOLBY VISION FEL TEST RESULTS ===")
    print("Stream Classification:    \(result.isFEL ? "Profile 7 FEL" : "Not FEL (MEL / single-layer)")")
    print("Packets processed:        \(result.packetsProcessed)")
    print("Frames output:            \(result.framesReconstructed)")
    print("Frames composed on GPU:   \(result.composedFrames)")
    print("Dimensions:               \(result.width) x \(result.height)")
    print("Pixel Format:             \(result.pixelFormat)")
    print("Elapsed time:             \(String(format: "%.3f", result.durationSeconds)) seconds")
    print("Reconstruction Throughput: \(String(format: "%.2f", result.fps)) FPS")
    print("--- Pixel Quality Audit ---")
    print("Avg Luma (Y):             \(String(format: "%.1f", result.avgLuma)) [10-bit code]")
    print("Avg Chroma Cb:            \(String(format: "%.1f", result.avgCb)) (std dev: \(String(format: "%.2f", result.stdDevCb)))")
    print("Avg Chroma Cr:            \(String(format: "%.1f", result.avgCr)) (std dev: \(String(format: "%.2f", result.stdDevCr)))")
    print("Chroma Validity Check:    \(result.isChromaValid ? "PASS (active picture)" : "FAIL (collapsed to 64)")")
    print("Luma below 10 bits:       \(String(format: "%.1f", result.lumaSubTenBitFraction * 100))% of samples carry bits below the 10-bit code")
    if let pt = probePoint {
        // Runs of identical words, so a phase switch shows as one line: "frames a-b: word (code + frac)".
        print("--- Luma at (\(pt.x), \(pt.y)), raw 16-bit word = 10-bit code + fraction in 1/64 ---")
        var start = 0
        for i in 1...result.probeWords.count where i == result.probeWords.count || result.probeWords[i] != result.probeWords[start] {
            let w = result.probeWords[start]
            print("frames \(start)-\(i - 1): \(w) = \(w >> 6) + \(w & 0x3F)/64")
            start = i
        }
    }
    print("--- Dolby Vision Display Metadata ---")
    print("Frames w/ RPU attachment: \(result.framesWithDVMetadata) / \(result.framesReconstructed)")
    print("Distinct RPU payloads:    \(result.distinctDVPayloads)")
    print("First payload size:       \(result.firstDVPayloadBytes) bytes")
    print("First payload prefix:     \(result.firstDVPayloadPrefix)... (expect leading 19)")
    print("=====================================")

    if result.framesReconstructed > 0 {
        if !result.isFEL {
            print("VERDICT: NOT FEL - Stream classified as MEL or non-FEL; enhancement layer was not engaged.")
            return 0
        }
        if !result.isChromaValid {
            print("VERDICT: FAILED - Chroma collapsed to flat 64 (the known green-picture failure)!")
            return 3
        }
        if result.framesWithDVMetadata < result.framesReconstructed {
            print("VERDICT: FAILED - \(result.framesReconstructed - result.framesWithDVMetadata) frame(s) emitted without per-frame Dolby Vision display metadata.")
            return 4
        }
        if result.composedFrames == 0 {
            print("VERDICT: FAILED - \(result.framesReconstructed) frame(s) came out but none was composed; every frame bypassed to its base layer.")
            return 5
        }
        if result.distinctDVPayloads <= 1 && result.framesReconstructed > 1 {
            print("WARNING: the RPU payload is static across \(result.framesReconstructed) frames. L1 is usually per-frame, but a static-metadata clip is valid; check the source if this one should vary.")
        }
        print("VERDICT: SUCCESS - Dolby Vision Profile 7 dual-layer Metal reconstruction verified.")
        return 0
    } else {
        print("VERDICT: FAILED - No frames were reconstructed.")
        return 2
    }
}
#endif
