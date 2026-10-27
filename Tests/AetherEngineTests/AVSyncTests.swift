// Audio against video through the HLS route, to the sample. Each clip under Fixtures/avsync/ has
// one white frame and one click at exactly 1.000 s (`Scripts/fetch-fixtures.sh`; FFmpeg's own decode
// puts the click on the frame in every one). The engine serves the clip, and the segment it hands
// AVPlayer is decoded the way AVPlayer decodes it: AVFoundation for the picture and the sound, each
// track placed at its first fragment's `tfdt`, which HLS honours and `AVAssetReader` reading a flat
// file does not (it starts every track at its first sample).
import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import AetherEngine

private func avsyncFixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/avsync").appendingPathComponent(name)
}

@Suite("Audio against video through the HLS route", .serialized)
struct AVSyncTests {

    struct Clip: CustomTestStringConvertible, Sendable {
        let name: String
        /// Matroska stores 1 ms ticks, up to 24 samples either side of a frame. Audio coded in frames
        /// is placed on its frame grid, which the rounded timestamp names exactly (`SourceGrid`), so it
        /// lands on the sample like every other container's; PCM has no grid, frames start anywhere,
        /// and the rounded timestamp is all there is.
        var toleranceSamples: Double { name == "pcm.mkv" ? 24 : 1 }
        var testDescription: String { name }
    }

    static let clips: [Clip] = ["aac.mkv", "aac.mp4", "aac.ts", "ac3.mkv", "ac3.ts", "eac3.mkv", "eac3.mp4",
                                "flac.mkv", "pcm.mkv", "truehd.mkv", "opus.mkv", "mp3.mkv",
                                "dts.mkv", "dts-drift.mkv", "truehd-jitter.mkv"].map(Clip.init)

    @Test("the click plays on the white frame", .timeLimit(.minutes(2)), arguments: clips)
    func clickOnFrame(_ clip: Clip) async throws {
        let url = avsyncFixture(clip.name)
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "run Scripts/fetch-fixtures.sh to generate Fixtures/avsync/")
        let engine = HLSVideoEngine(url: url, dvModeAvailable: false)
        let playbackURL = try engine.start()
        defer { engine.stop() }
        var comps = try #require(URLComponents(url: playbackURL.deletingLastPathComponent(), resolvingAgainstBaseURL: false))
        comps.query = nil
        let base = try #require(comps.url)
        let initBytes = try Data(contentsOf: base.appendingPathComponent("init.mp4"))
        let segment = try Data(contentsOf: base.appendingPathComponent("seg0.mp4"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("avsync-\(UUID().uuidString).mp4")
        try (initBytes + segment).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let measured = await withCheckedContinuation { (continuation: CheckedContinuation<(Double?, Double?), Never>) in
            Thread.detachNewThread { continuation.resume(returning: Self.measure(file)) }
        }
        let flash = try #require(measured.0, "no white frame decoded")
        let click = try #require(measured.1, "no click decoded")
        let origins = Self.firstTfdtSeconds(initBytes + segment)
        let video = flash + (origins.video ?? 0), audio = click + (origins.audio ?? 0)
        let offset = (audio - video) * 48_000
        #expect(abs(offset) <= clip.toleranceSamples, "audio is \(offset) samples off the picture")
    }

    /// AE#464's audio delay moves the sound against the picture by exactly what was asked, and a
    /// negative one never publishes a negative `tfdt` (unsigned: -1 is 2^64 - 1, and AVPlayer placed
    /// such a fragment 584 thousand years out, AE#561). Where the engine encodes, audio the delay puts
    /// before zero comes off at the exact sample and the track starts on zero; a copied packet cannot
    /// be cut, so there the start holds at most the one frame that straddled zero.
    @Test("an audio delay lands exactly, and a negative one cuts the start instead of wrapping it",
          .timeLimit(.minutes(4)), arguments: ["aac.mp4", "eac3.mp4", "aac.mkv", "flac.mkv", "pcm.mkv", "truehd.mkv"],
          [-0.7, -0.15, 0.2, 0.7])
    func audioDelay(_ name: String, _ seconds: Double) async throws {
        let clip = Clip(name: name)
        let url = avsyncFixture(name)
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "run Scripts/fetch-fixtures.sh to generate Fixtures/avsync/")
        let engine = HLSVideoEngine(url: url, dvModeAvailable: false)
        engine.audioDelaySeconds = seconds
        let playbackURL = try engine.start()
        defer { engine.stop() }
        let bridged = engine.audioBridge != nil
        var comps = try #require(URLComponents(url: playbackURL.deletingLastPathComponent(), resolvingAgainstBaseURL: false))
        comps.query = nil
        let base = try #require(comps.url)
        let bytes = try Data(contentsOf: base.appendingPathComponent("init.mp4"))
            + Data(contentsOf: base.appendingPathComponent("seg0.mp4"))
        let origins = Self.firstTfdtSeconds(bytes)
        let audioOrigin = try #require(origins.audio)
        #expect(audioOrigin >= 0 && audioOrigin < 1e6, "the first audio fragment starts at \(audioOrigin) s")
        if seconds < 0 {
            if bridged {
                #expect(audioOrigin == 0, "bridged audio starts at \(audioOrigin * 48_000) samples, not on zero")
            } else {
                #expect(audioOrigin * 48_000 < 2048, "the copied track starts \(audioOrigin * 48_000) samples in")
            }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("avsync-\(UUID().uuidString).mp4")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let measured = await withCheckedContinuation { (continuation: CheckedContinuation<(Double?, Double?), Never>) in
            Thread.detachNewThread { continuation.resume(returning: Self.measure(file)) }
        }
        let flash = try #require(measured.0), click = try #require(measured.1)
        let offset = ((click + audioOrigin) - (flash + (origins.video ?? 0))) * 48_000
        #expect(abs(offset - seconds * 48_000) <= clip.toleranceSamples,
                "audio is \(offset) samples off the picture (\(bridged ? "bridged" : "copied")), asked \(seconds * 48_000)")
    }

    // MARK: - Measurement

    /// The white frame's presentation time and the click's (cross-correlated against the 144-sample
    /// burst, refined to a fraction of a sample), each on its track's own timeline.
    static func measure(_ file: URL) -> (Double?, Double?) {
        let asset = AVURLAsset(url: file)
        var flash: Double?, click: Double?
        if let track = asset.tracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) {
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(out)
            reader.startReading()
            while flash == nil, let buffer = out.copyNextSampleBuffer() {
                guard let px = CMSampleBufferGetImageBuffer(buffer) else { continue }
                CVPixelBufferLockBaseAddress(px, .readOnly)
                let base = CVPixelBufferGetBaseAddress(px)!.assumingMemoryBound(to: UInt8.self)
                let centre = base[CVPixelBufferGetBytesPerRow(px) * (CVPixelBufferGetHeight(px) / 2) + 4 * (CVPixelBufferGetWidth(px) / 2) + 1]
                CVPixelBufferUnlockBaseAddress(px, .readOnly)
                if centre > 128 { flash = CMSampleBufferGetPresentationTimeStamp(buffer).seconds }
            }
            reader.cancelReading()
        }
        if let track = asset.tracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) {
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48_000])
            reader.add(out)
            reader.startReading()
            var buffers: [CMSampleBuffer] = []
            while let buffer = out.copyNextSampleBuffer() { buffers.append(buffer) }
            if let first = buffers.first, let lag = clickLag(buffers) {
                click = CMSampleBufferGetPresentationTimeStamp(first).seconds + lag / 48_000
            }
        }
        return (flash, click)
    }

    /// Where the click starts in `buffers` (48 kHz float PCM, the loudest channel of each frame), in samples from the
    /// first: cross-correlated against the 144-sample burst, refined to a fraction of a sample.
    static func clickLag(_ buffers: [CMSampleBuffer]) -> Double? {
        var mono: [Float] = []
        for buffer in buffers {
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { continue }
            let channels = Int(asbd.mChannelsPerFrame)
            var block: CMBlockBuffer?
            var list = AudioBufferList()
            _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                buffer, bufferListSizeNeededOut: nil, bufferListOut: &list,
                bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
            guard let samples = list.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for f in 0..<CMSampleBufferGetNumSamples(buffer) {
                var loudest: Float = 0
                for c in 0..<channels where abs(samples[f * channels + c]) > abs(loudest) { loudest = samples[f * channels + c] }
                mono.append(loudest)
            }
        }
        guard mono.count > 288 else { return nil }
        let burst = (0..<144).map { 0.8 * sinf(2 * .pi * 1000 * Float($0) / 48_000) }
        var corr = [Float](repeating: 0, count: mono.count - 144)
        var best = 0
        for lag in corr.indices {
            var acc: Float = 0
            for k in 0..<144 { acc += mono[lag + k] * burst[k] }
            corr[lag] = acc
            if acc > corr[best] { best = lag }
        }
        var fraction = 0.0
        if best > 0, best + 1 < corr.count {
            let a = Double(corr[best - 1]), b = Double(corr[best]), c = Double(corr[best + 1])
            fraction = 0.5 * (a - c) / (a - 2 * b + c)
        }
        return Double(best) + fraction
    }

    /// Each track's first `tfdt`, in seconds of its own timescale.
    static func firstTfdtSeconds(_ data: Data) -> (video: Double?, audio: Double?) {
        let bytes = [UInt8](data)
        func u32(_ o: Int) -> UInt32 { bytes[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        func u64(_ o: Int) -> UInt64 { bytes[o..<o + 8].reduce(0) { $0 << 8 | UInt64($1) } }
        func boxes(_ range: Range<Int>) -> [(String, Range<Int>)] {
            var out: [(String, Range<Int>)] = []
            var o = range.lowerBound
            while o + 8 <= range.upperBound {
                let size = Int(u32(o))
                guard size >= 8, o + size <= range.upperBound else { break }
                out.append((String(bytes: bytes[o + 4..<o + 8], encoding: .isoLatin1) ?? "", (o + 8)..<(o + size)))
                o += size
            }
            return out
        }
        var kind: [UInt32: (handler: String, timescale: Double)] = [:]
        func walk(_ range: Range<Int>, _ id: inout UInt32, _ handler: inout String, _ timescale: inout Double) {
            for (type, body) in boxes(range) {
                switch type {
                case "tkhd": id = u32(body.lowerBound + (bytes[body.lowerBound] == 1 ? 20 : 12))
                case "hdlr": handler = String(bytes: bytes[body.lowerBound + 8..<body.lowerBound + 12], encoding: .isoLatin1) ?? ""
                case "mdhd": timescale = Double(u32(body.lowerBound + (bytes[body.lowerBound] == 1 ? 20 : 12)))
                case "mdia", "minf", "stbl": walk(body, &id, &handler, &timescale)
                default: break
                }
            }
        }
        for (type, moov) in boxes(0..<bytes.count) where type == "moov" {
            for (t, trak) in boxes(moov) where t == "trak" {
                var id: UInt32 = 0, handler = "", timescale = 0.0
                walk(trak, &id, &handler, &timescale)
                kind[id] = (handler, timescale)
            }
        }
        var video: Double?, audio: Double?
        for (type, moof) in boxes(0..<bytes.count) where type == "moof" {
            for (t, traf) in boxes(moof) where t == "traf" {
                var id: UInt32 = 0
                for (t3, body) in boxes(traf) {
                    if t3 == "tfhd" { id = u32(body.lowerBound + 4) }
                    if t3 == "tfdt", let k = kind[id], k.timescale > 0 {
                        let ticks = bytes[body.lowerBound] == 1 ? Double(u64(body.lowerBound + 4)) : Double(u32(body.lowerBound + 4))
                        if k.handler == "vide", video == nil { video = ticks / k.timescale }
                        if k.handler == "soun", audio == nil { audio = ticks / k.timescale }
                    }
                }
            }
        }
        return (video, audio)
    }
}
