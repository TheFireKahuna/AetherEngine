// Only with the TrueHDObjectAudio and APACObjectOutput traits: the object bridge is not built without them.
#if TrueHDObjectAudio && APACObjectOutput
import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Diagnostic: feeds every `.thd` in `AE_APAC_GAP_DIR` through the object bridge the way a session does
/// (`objectOutput: true`) and reports where the APAC timeline breaks, i.e. where a feed failed and its
/// audio never came out. Runs only when the variable names a directory.
@Suite("APAC object gap probe")
struct APACObjectGapProbeTests {

    @Test("the object bridge's APAC timeline has no holes")
    func probe() throws {
        guard let dir = ProcessInfo.processInfo.environment["AE_APAC_GAP_DIR"] else { return }
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".thd") }.sorted()
        for name in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name))
            let bridge = try SpatialAudioBridge(
                srcTimeBase: AVRational(num: 1, den: 48_000), layout: .l714,
                decoder: TrueHDObjectAudioDecoder(), objectOutput: true)
            bridge.setSourceStart(0)
            defer { bridge.close() }
            var pts: [Int64] = []
            let start = Date()
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = min(3000, raw.count - offset)
                    let pkt = av_packet_alloc()!
                    defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
                    _ = av_new_packet(pkt, Int32(n))
                    pkt.pointee.data.update(from: raw.baseAddress!.assumingMemoryBound(to: UInt8.self) + offset, count: n)
                    pkt.pointee.pts = offset == 0 ? 0 : Int64.min
                    for fp in try bridge.feed(packet: pkt) {
                        pts.append(fp.pointee.pts)
                        var p: UnsafeMutablePointer<AVPacket>? = fp; trackedPacketFree(&p)
                    }
                    offset += n
                }
            }
            for fp in bridge.flush() {
                pts.append(fp.pointee.pts)
                var p: UnsafeMutablePointer<AVPacket>? = fp; trackedPacketFree(&p)
            }
            let holes = zip(pts, pts.dropFirst()).filter { $1 - $0 != 1024 }
            let seconds = Double(pts.count * 1024) / 48_000
            print("[APACGapProbe] \(name): \(pts.count) packets, \(String(format: "%.1f", seconds)) s in "
                  + "\(String(format: "%.1f", Date().timeIntervalSince(start))) s; holes \(holes.count)")
            for (a, b) in holes {
                print("[APACGapProbe]   at \(String(format: "%.3f", Double(a) / 48_000)) s: next pts "
                      + "\(String(format: "%.3f", Double(b) / 48_000)) s (\(b - a - 1024) frames)")
            }
        }
    }
}
#endif
