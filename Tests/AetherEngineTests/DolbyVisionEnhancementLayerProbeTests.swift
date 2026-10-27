import Testing
import Foundation
@testable import AetherEngine

/// `probeDolbyVisionEnhancementLayer` on the clips the Dolby Vision pulse probe builds
/// (DolbyVisionPulse, https://github.com/TheFireKahuna/DolbyVisionPulse, checked out beside this repository, `Scripts/build.sh`); skipped where they have not been built.
struct DolbyVisionEnhancementLayerProbeTests {

    static let clips = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("../DolbyVisionPulse/out")
    static let fel = clips.appendingPathComponent("p7fel_l1.mp4")
    static let mel = clips.appendingPathComponent("p7mel_l1.mp4")
    static let profile81 = clips.appendingPathComponent("count_mel.mp4")
    static let clipsBuilt = [fel, mel, profile81].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }

    @Test("A Profile 7 FEL clip reads as FEL, a MEL clip as MEL, and a Profile 8.1 clip as neither",
          .enabled(if: clipsBuilt, "needs the DV pulse clips: ../DolbyVisionPulse/Scripts/build.sh"))
    func classifiesBothLayers() throws {
        #expect(try AetherEngine.probeDolbyVisionEnhancementLayer(url: Self.fel) == .fel)
        #expect(try AetherEngine.probeDolbyVisionEnhancementLayer(url: Self.mel) == .mel)
        #expect(try AetherEngine.probeDolbyVisionEnhancementLayer(url: Self.profile81) == nil)
    }
}
