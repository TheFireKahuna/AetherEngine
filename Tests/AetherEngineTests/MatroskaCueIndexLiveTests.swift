import Testing
import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Diagnostic against a real remote MKV: `AE_MKV_INDEX_URL` (with `AE_MKV_INDEX_AUTH`, an Authorization
/// header value) names the file. Reads its subtitle index, scans its first PGS track for forced display
/// sets and reads a few text frames, timing each step. Runs only when the variable is set.
@Suite("Matroska cue index, live file")
struct MatroskaCueIndexLiveTests {
    private enum FrameEncodingNone { static let value: MatroskaCueIndex.FrameEncoding? = MatroskaCueIndex.FrameEncoding.none }

    @Test("the index reads, and a PGS track's forced display sets are found from their headers")
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
            let plan = AetherEngine.IndexedRenditionPlan(ordinal: 0, streamIndex: streamText, trackNumber: track,
                                                         frameCount: nil, timeBase: timeBase, language: "eng", kind: .text)
            let blocks = try #require(index.blocksByTrack[track])
            started = Date()
            var cues: [SubtitleCue] = []
            for block in blocks {
                guard let frame = index.readFrame(block, track: track, from: source),
                      let event = AetherEngine.decode(frame, plan: plan, index: index, decoder: decoder) else { continue }
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
        // A PGS track: header scan, 16 readers at once.
        let pgs = UInt64(ProcessInfo.processInfo.environment["AE_MKV_INDEX_PGS_TRACK"] ?? "") ??
            index.blocksByTrack.keys.sorted().first(where: { index.encodingByTrack[$0] == .zlib })
        if let pgs {
            let blocks = index.blocksByTrack[pgs]!
            started = Date()
            let lanes = 16
            let sources: [IOReaderByteSource] = (0..<lanes).compactMap { _ in
                reader.makeIndependentReader().map(IOReaderByteSource.init)
            }
            defer { sources.forEach { $0.close() } }
            let results = UnsafeMutableBufferPointer<PGSCompositionHeader?>.allocate(capacity: blocks.count)
            results.initialize(repeating: nil)
            defer { results.deallocate() }
            DispatchQueue.concurrentPerform(iterations: sources.count) { lane in
                var i = lane
                while i < blocks.count {
                    if let frame = index.readFrame(blocks[i], track: pgs, from: sources[lane], prefix: 512) {
                        results[i] = PGSCompositionHeader.parse(frame.payload)
                    }
                    i += sources.count
                }
            }
            var states: [UInt8: Int] = [:]
            var forced: [Int64] = []
            var failedAt: [Int] = []
            for i in 0..<blocks.count {
                guard let header = results[i] else { failedAt.append(i); continue }
                states[header.state, default: 0] += 1
                if header.isForced { forced.append(blocks[i].ticks) }
            }
            print("[MKVIndex] track \(pgs) header scan: \(blocks.count) blocks in "
                  + "\(String(format: "%.2f", Date().timeIntervalSince(started))) s on \(sources.count) readers, "
                  + "failed \(failedAt.count), states \(states), forced display sets \(forced.count) at "
                  + "\(forced.prefix(12).map { String(format: "%.1f", index.seconds(ticks: $0, track: pgs)) })")
            for i in failedAt.prefix(4) {
                let frame = index.readFrame(blocks[i], track: pgs, from: source, prefix: 512)
                let described = frame.map { f in
                    "read, \(f.payload.count) B, prefix \(f.isPrefix), head "
                        + f.payload.prefix(12).map { String(format: "%02x", $0) }.joined()
                } ?? "unreadable"
                print("[MKVIndex]   failed #\(i) @\(String(format: "%.2f", index.seconds(ticks: blocks[i].ticks, track: pgs))): "
                      + "frame \(described)")
                if let frame, let full = index.readFrame(blocks[i], track: pgs, from: source) {
                    print("[MKVIndex]     full \(full.payload.count) B; parse from full: \(String(describing: PGSCompositionHeader.parse(full.payload)))")
                    _ = frame
                }
            }
        }
    }
}
