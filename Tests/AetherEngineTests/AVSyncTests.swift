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
        /// Matroska stores 1 ms ticks, so a clip's first audio timestamp is up to half of one off what
        /// the codec's frame grid says; the other containers state the sample.
        var toleranceSamples: Double { name.hasSuffix(".mkv") ? 24 : 1 }
        var testDescription: String { name }
    }

    static let clips: [Clip] = ["aac.mkv", "aac.mp4", "aac.ts", "ac3.mkv", "ac3.ts", "eac3.mkv", "eac3.mp4",
                                "flac.mkv", "pcm.mkv", "truehd.mkv", "opus.mkv", "mp3.mkv"].map(Clip.init)

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
            var mono: [Float] = []
            var start: Double?
            while let buffer = out.copyNextSampleBuffer() {
                guard let format = CMSampleBufferGetFormatDescription(buffer),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { continue }
                let channels = Int(asbd.mChannelsPerFrame)
                if start == nil { start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds }
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
            if let start, mono.count > 288 {
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
                click = start + (Double(best) + fraction) / 48_000
            }
        }
        return (flash, click)
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
