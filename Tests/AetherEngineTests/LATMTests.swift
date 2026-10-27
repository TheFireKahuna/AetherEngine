import AetherLibavcodec
import AetherLibavutil
import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

/// LATM is a transport around AAC: taken out of it, a stream's frames and its AudioSpecificConfig are AAC like any
/// other (`LATM`). The proof is the engine's own path: the HLS route's configuration and AAC parameters for the
/// stream, its frames unwrapped, decode to exactly the samples the stream decodes to as it was.
@Suite("LATM unwraps to AAC")
struct LATMTests {

    private struct Run {
        var pcm = Data()
        var elements: [[UInt8]] = []
        var unwrapped = 0
        /// The configuration the HLS route declares for the stream, and the one its elements carried.
        var declared: [UInt8]?
        var carried: [UInt8]?
    }

    /// The fixture opened the way the engine opens a file and decoded by the engine's audio decoder: as it is, or
    /// `unwrapped` as the HLS route copies it, the stream's parameters made AAC and each element's frame taken out.
    private func decoded(_ data: Data, unwrapped: Bool) throws -> Run {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("latm-\(UUID().uuidString).latm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = Demuxer()
        try demuxer.open(url: url)
        defer { demuxer.close() }
        let stream = try #require(demuxer.stream(at: demuxer.audioStreamIndex))
        var run = Run()
        var reader = LATM.Reader()
        if unwrapped {
            let declared = try #require(HLSVideoEngine.latmConfiguration(stream.pointee.codecpar))
            try #require(HLSVideoEngine.prepareLATMForFMP4(stream.pointee.codecpar, config: declared))
            run.declared = declared
        }
        let decoder = AudioDecoder()
        try decoder.open(stream: stream)
        defer { decoder.close() }
        var buffers: [CMSampleBuffer] = []
        while let pkt = try demuxer.readPacket() {
            let element = [UInt8](UnsafeRawBufferPointer(start: pkt.pointee.data, count: Int(pkt.pointee.size)))
            run.elements.append(element)
            if unwrapped, let frame = element.withUnsafeBytes({ reader.payload($0) }) {
                run.unwrapped += 1
                try #require(HLSSegmentProducer.replacePayload(of: pkt, with: frame))
            }
            buffers += decoder.decode(packet: pkt)
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        buffers += decoder.drain()
        run.carried = reader.config
        for b in buffers {
            let block = try #require(CMSampleBufferGetDataBuffer(b))
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes)
            run.pcm.append(contentsOf: bytes)
        }
        return run
    }

    @Test("the unwrapped frames decode as AAC to exactly what the LATM stream decodes to",
          arguments: ["lowComplexity", "highEfficiency"])
    func unwrapsLosslessly(fixture: String) throws {
        let data = fixture == "lowComplexity" ? LATMFixture.lowComplexity : LATMFixture.highEfficiency
        let original = try decoded(data, unwrapped: false)
        let unwrapped = try decoded(data, unwrapped: true)
        #expect(unwrapped.unwrapped == unwrapped.elements.count, "every element unwraps")
        #expect(unwrapped.carried == unwrapped.declared, "the probe's configuration is the one the elements carry")
        #expect(unwrapped.pcm.count > 100_000)
        #expect(unwrapped.pcm == original.pcm)
    }

    @Test("an element reusing a configuration no element has carried yet is not read")
    func needsAConfiguration() throws {
        // The muxer carries the configuration in every fifth element, the first included.
        let elements = try decoded(LATMFixture.lowComplexity, unwrapped: false).elements
        var reader = LATM.Reader()
        #expect(elements[1].withUnsafeBytes { reader.payload($0) } == nil)
        #expect(elements[0].withUnsafeBytes { reader.payload($0) } != nil)
        #expect(elements[1].withUnsafeBytes { reader.payload($0) } != nil)
    }

    @Test("the configuration's length is read off its own syntax")
    func configurationLength() {
        func length(_ bytes: [UInt8]) -> Int? {
            bytes.withUnsafeBytes { AudioSpecificConfigReader.length(LATM.BitReader($0)) }
        }
        #expect(length([0x11, 0x90]) == 16)              // LC, 48 kHz, stereo: 5+4+4+3
        #expect(length([0x2b, 0x11, 0x88, 0x00]) == 25)  // HE-AAC, explicit: 5+4+4+4+5+3
        #expect(length([0xeb, 0x09, 0x88, 0x00]) == 25)  // HE-AACv2, explicit
        #expect(length([0x11, 0x80]) == nil)             // channel configuration 0: a PCE
    }
}
