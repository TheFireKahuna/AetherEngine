import Testing
import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Diagnostic against a real remote MKV: `AE_MKV_INDEX_URL` (with `AE_MKV_INDEX_AUTH`, an Authorization
/// header value) names the file. Reads its subtitle index and a few text frames, and decodes a text
/// track from it, timing each step. Runs only when the variable is set.
@Suite("Matroska cue index, live file")
struct MatroskaCueIndexLiveTests {
    private enum FrameEncodingNone { static let value: MatroskaCueIndex.FrameEncoding? = MatroskaCueIndex.FrameEncoding.none }

    @Test("the index reads, and a text track decodes from it")
    func liveIndex() throws {
        guard let urlString = ProcessInfo.processInfo.environment["AE_MKV_INDEX_URL"],
              let url = URL(string: urlString) else { return }
        var headers: [String: String] = [:]
        if let auth = ProcessInfo.processInfo.environment["AE_MKV_INDEX_AUTH"] { headers["Authorization"] = auth }
        guard let reader = HTTPDiscIOReader(url: url, extraHeaders: headers, baseChunkSize: 4096,
                                            maxChunkSize: 4 * 1024 * 1024) else {
            Issue.record("source unreachable"); return
        }
        let source = IOReaderByteSource(reader)
        defer { source.close() }
        var started = Date()
        let index = try MatroskaCueIndex.read(from: source, token: .forParserTests)
        print("[MKVIndex] index read in \(String(format: "%.2f", Date().timeIntervalSince(started))) s: "
              + "tracks \(index.blocksByTrack.keys.sorted()), scale \(index.timestampScale), "
              + "cluster size field \(index.clusterSizeFieldLength.map(String.init) ?? "varies")")
        for track in index.blocksByTrack.keys.sorted() {
            print("[MKVIndex]   track \(track): \(index.blocksByTrack[track]!.count) blocks, "
                  + "encoding \(index.encodingByTrack[track] ?? .none)")
        }
        // First uncompressed track: a few frames.
        if let text = index.blocksByTrack.keys.sorted().first(where: { index.encodingByTrack[$0] == FrameEncodingNone.value && $0 > 1 }) {
            for block in index.blocksByTrack[text]!.prefix(3) {
                let frame = index.readFrame(block, track: text, from: source)
                print("[MKVIndex] track \(text) @\(String(format: "%.2f", index.seconds(ticks: block.ticks, track: text))) "
                      + "dur \(frame?.durationTicks ?? -1): "
                      + "\(frame.map { String(decoding: $0.payload, as: UTF8.self) } ?? "UNREADABLE")")
                #expect(frame != nil)
            }
        } else {
            print("[MKVIndex] no uncompressed track")
        }
        // The first text track decoded from the index through the engine's own decoder.
        if let streamText = ProcessInfo.processInfo.environment["AE_MKV_INDEX_TEXT_STREAM"].flatMap(Int32.init) {
            let demuxer = Demuxer()
            try demuxer.open(url: url, extraHeaders: headers,
                             profile: DemuxerOpenProfile.subtitleSideDemuxer(callerProbesize: nil, callerMaxAnalyzeDuration: nil))
            defer { demuxer.close() }
            let streams = AetherEngine.indexedSubtitleStreams(of: demuxer)
            let mapping = index.trackNumbers(for: streams)
            print("[MKVIndex] stream ids: \(streams.map { "\($0.streamIndex)->\($0.trackID)" }.joined(separator: " "))")
            print("[MKVIndex] mapping: \(mapping.count) of \(streams.count) subtitle streams; stream \(streamText) -> track \(mapping[streamText].map(String.init) ?? "none")")
            let track = try #require(mapping[streamText])
            let facts = demuxer.withStream(at: streamText) { st in
                (st.pointee.time_base, EmbeddedSubtitleDecoder(stream: st, sourceVideoWidth: 1920, sourceVideoHeight: 1080))
            }
            let (timeBase, made) = try #require(facts)
            let decoder = try #require(made)
            let blocks = try #require(index.blocksByTrack[track])
            started = Date()
            var cues: [SubtitleCue] = []
            for block in blocks {
                guard let frame = index.readFrame(block, track: track, from: source),
                      let event = SubtitleSource.decode(frame, index: index, track: track, streamTimeBase: timeBase,
                                                        decoder: decoder) else { continue }
                cues.append(contentsOf: event.cues)
            }
            print("[MKVIndex] stream \(streamText) (track \(track)) decoded from the index: \(blocks.count) blocks -> "
                  + "\(cues.count) cues in \(String(format: "%.2f", Date().timeIntervalSince(started))) s; first "
                  + cues.prefix(3).map { c -> String in
                      if case .text(let t) = c.body { return String(format: "[%.3f-%.3f] %@", c.startTime, c.endTime, t) }
                      return "image"
                  }.joined(separator: " | "))
            #expect(cues.count == blocks.count)
        }
    }
}
