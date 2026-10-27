import Testing
import Foundation
@testable import AetherEngine

/// #660: the engine hands its stored volume to a host right after building it, before `load()`.
/// The FFmpeg audio host forwarded that write to an `AudioOutput` that `load()` had not built yet, so it
/// was dropped and every session started at full volume. The host now keeps the volume itself and
/// hands it to each output it builds.
@Suite("The audio host keeps a volume set before its audio output exists (#660)")
struct AudioHostVolumeBeforeLoadTests {

    @MainActor
    @Test("an audio host reports the volume it was given before load")
    func audioHostKeepsVolumeBeforeLoad() {
        let host = AudioPlaybackHost()
        host.volume = 0.25
        #expect(host.volume == 0.25)
    }

    @MainActor
    @Test("an audio host plays at the volume it was given before load")
    func audioHostAppliesVolumeOnLoad() async throws {
        let host = AudioPlaybackHost()
        host.volume = 0.25
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: makeWAV(seconds: 1)))
        try await host.load(demuxer: demuxer, startPosition: nil, audioSourceStreamIndex: nil)
        defer { host.stop() }
        #expect(host.outputVolumeForTesting == 0.25)
    }

    private func makeWAV(seconds: Double) -> Data {
        let sampleRate = 48_000, channels = 2
        let pcm = Data(count: Int(Double(sampleRate) * seconds) * channels * 2)
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        str("data"); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }
}
