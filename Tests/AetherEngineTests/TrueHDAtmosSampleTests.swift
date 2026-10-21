// Only with the TrueHDObjectAudio trait (off by default): the decoder and its library are not built without it.
#if TrueHDObjectAudio
import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// End to end on a real TrueHD Atmos elementary stream: decode, render, encode. The sample is not
/// in the repository (Dolby's "Unfold" demo, TrueHD Atmos, LFE + 15 objects, 27 s), so these run
/// only when `AE_TRUEHD_ATMOS_SAMPLE` names a `.thd` file.
@Suite("TrueHD Atmos sample, decode to APAC")
struct TrueHDAtmosSampleTests {

    private static var sample: Data? {
        ProcessInfo.processInfo.environment["AE_TRUEHD_ATMOS_SAMPLE"]
            .flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
    }

    @Test("objects decode with positions and render into the height speakers")
    func decodesAndRendersHeights() throws {
        guard let data = Self.sample else { return }
        let decoder = try TrueHDObjectAudioDecoder()
        let layout = SpatialSpeakerLayout.l714
        var renderer: ObjectAudioRenderer?
        let out = (0..<layout.channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 256) }
        defer { out.forEach { $0.deallocate() } }
        var energy = [Double](repeating: 0, count: layout.channelCount)
        var frames = 0, updates = 0, raisedObjects = 0
        var roles: [ObjectAudioRole] = []

        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = min(4096, raw.count - offset)
                try decoder.push(UnsafeRawBufferPointer(rebasing: raw[offset..<offset + n]))
                offset += n
                while let block = try decoder.nextBlock() {
                    if renderer == nil { renderer = ObjectAudioRenderer(layout: layout, roles: block.roles); roles = block.roles }
                    updates += block.updates.count
                    for u in block.updates {
                        raisedObjects += u.states.enumerated().filter {
                            block.roles[$0.offset] == .object && ($0.element?.position.z ?? 0) > 0.3
                        }.count
                    }
                    renderer!.render(inputs: block.planes, frameCount: block.frameCount,
                                     updates: block.updates, outputs: out)
                    for c in 0..<layout.channelCount {
                        for i in 0..<block.frameCount { energy[c] += Double(out[c][i] * out[c][i]) }
                    }
                    frames += block.frameCount
                }
            }
        }
        let rms = energy.map { ($0 / Double(max(frames, 1))).squareRoot() }
        print("[TrueHDAtmosSample] frames=\(frames) roles=\(roles) updates=\(updates) raisedObjectStates=\(raisedObjects)")
        print("[TrueHDAtmosSample] 7.1.4 rms dBFS: " + zip(layout.speakers, rms).map {
            "\($0.0.rawValue)=\(String(format: "%.1f", 20 * log10(max($0.1, 1e-9))))" }.joined(separator: " "))

        #expect(frames == 1_298_000)
        #expect(roles.filter { $0 == .object }.count == 15)
        #expect(roles.filter { $0 == .lfe }.count == 1)
        #expect(updates > 800, "OAMD every 1536 samples over 27 s")
        #expect(raisedObjects > 0, "Unfold moves objects overhead")
        for (c, speaker) in layout.speakers.enumerated() where speaker.isHeight {
            #expect(rms[c] > 1e-4, "\(speaker.rawValue) carries the overhead objects")
        }
    }

    #if TrueHDReferenceRender
    // The exact decode it measures against is only built with the measurement trait.
    @Test("the bed split's guide with ramps and hop-exact snapshots is closer to the exact render than without",
          .enabled(if: ProcessInfo.processInfo.environment["AE_TRUEHD_ATMOS_SAMPLE"] != nil))
    func bedSplitGuideTiming() throws {
        guard let data = Self.sample else { return }
        let decoder = try TrueHDObjectAudioDecoder(splitsBed: true)
        // The truth both approximate: the exact objects (a LibTrueHD built with matrix-interpolation)
        // through the TS 103 448 renderer, ramps and all.
        let exact = try TrueHDObjectAudioDecoder(splitsBed: false)
        var truthRenderer: ObjectAudioRenderer?
        var queueTruth: [[Float]] = Array(repeating: [], count: SpatialSpeakerLayout.l714.channelCount)
        // The splitter's output frame i is input frame i (its latency only delays it).
        let layout = SpatialSpeakerLayout.l714
        let channels = layout.channelCount
        var old: (ObjectAudioRenderer, BedSplitter)?
        var new: (ObjectAudioRenderer, BedSplitter)?
        var snapshot = ObjectAudioGainSnapshot()
        let outOld = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 4096) }
        let outNew = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 4096) }
        defer { (outOld + outNew).forEach { $0.deallocate() } }
        var energyOld = [Double](repeating: 0, count: channels), energyNew = energyOld, energyDiff = energyOld
        var energyTruth = energyOld, errOld = energyOld, errNew = energyOld
        // Per speaker and 1024-frame window: energy of each version and of the truth, for the level
        // error over time (where the guide puts energy, which is what it decides).
        var win = (old: [Double](repeating: 0, count: channels), new: [Double](repeating: 0, count: channels),
                   truth: [Double](repeating: 0, count: channels), frames: 0)
        var levelErr = (old: 0.0, new: 0.0, count: 0)
        let outTruth = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 4096) }
        defer { outTruth.forEach { $0.deallocate() } }
        var queueOld: [[Float]] = Array(repeating: [], count: channels), queueNew = queueOld

        func collect() {
            let n = min(queueOld[0].count, queueNew[0].count, queueTruth[0].count)
            for c in 0..<channels {
                for i in 0..<n {
                    let (a, b, t) = (Double(queueOld[c][i]), Double(queueNew[c][i]), Double(queueTruth[c][i]))
                    energyOld[c] += a * a; energyNew[c] += b * b; energyDiff[c] += (a - b) * (a - b)
                    energyTruth[c] += t * t; errOld[c] += (a - t) * (a - t); errNew[c] += (b - t) * (b - t)
                    win.old[c] += a * a; win.new[c] += b * b; win.truth[c] += t * t
                }
                queueOld[c].removeFirst(n); queueNew[c].removeFirst(n); queueTruth[c].removeFirst(n)
            }
            win.frames += n
            if win.frames >= 1024 {
                for c in 0..<channels where layout.speakers[c] != .lfe && win.truth[c] / Double(win.frames) > 1e-7 {
                    let t = 10 * log10(win.truth[c])
                    levelErr.old += abs(10 * log10(max(win.old[c], 1e-20)) - t)
                    levelErr.new += abs(10 * log10(max(win.new[c], 1e-20)) - t)
                    levelErr.count += 1
                }
                win = ([Double](repeating: 0, count: channels), [Double](repeating: 0, count: channels),
                       [Double](repeating: 0, count: channels), 0)
            }
        }

        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = min(4096, raw.count - offset)
                try decoder.push(UnsafeRawBufferPointer(rebasing: raw[offset..<offset + n]))
                try exact.push(UnsafeRawBufferPointer(rebasing: raw[offset..<offset + n]))
                offset += n
                while let block = try exact.nextBlock() {
                    if truthRenderer == nil { truthRenderer = ObjectAudioRenderer(layout: layout, roles: block.roles) }
                    truthRenderer!.render(inputs: block.planes, frameCount: block.frameCount, updates: block.updates, outputs: outTruth)
                    for c in 0..<channels { queueTruth[c] += UnsafeBufferPointer(start: outTruth[c], count: block.frameCount) }
                }
                while let block = try decoder.nextBlock() {
                    guard let bed = block.bed else { continue }
                    if old == nil {
                        old = (ObjectAudioRenderer(layout: layout, roles: block.roles), BedSplitter(layout: layout, bedRoles: bed.roles))
                        new = (ObjectAudioRenderer(layout: layout, roles: block.roles), BedSplitter(layout: layout, bedRoles: bed.roles))
                    }
                    // Before: every update a jump, one snapshot at the block's end.
                    let jumps = block.updates.map { u -> ObjectAudioMetadataUpdate in var u = u; u.rampFrames = 0; return u }
                    old!.0.advance(frameCount: block.frameCount, updates: jumps)
                    old!.0.snapshot(into: &snapshot)
                    old!.1.setGains(snapshot)
                    let gotOld = old!.1.process(elements: block.planes, bed: bed.planes, frameCount: block.frameCount, output: outOld)
                    for c in 0..<channels { queueOld[c] += UnsafeBufferPointer(start: outOld[c], count: gotOld) }
                    // Now: ramps, a snapshot on each hop's last frame (as SpatialAudioBridge does).
                    var start = 0
                    while start < block.frameCount {
                        let count = min(block.frameCount - start, new!.1.framesUntilHop)
                        let last = start + count == block.frameCount
                        let updates = block.updates.filter { $0.frameOffset >= start && ($0.frameOffset < start + count || last) }
                            .map { u -> ObjectAudioMetadataUpdate in var u = u; u.frameOffset -= start; return u }
                        new!.0.advance(frameCount: count, updates: updates)
                        new!.0.snapshot(into: &snapshot)
                        new!.1.setGains(snapshot)
                        let got = new!.1.process(elements: block.planes.map { $0 + start }, bed: bed.planes.map { $0 + start },
                                                 frameCount: count, output: outNew)
                        for c in 0..<channels { queueNew[c] += UnsafeBufferPointer(start: outNew[c], count: got) }
                        start += count
                    }
                    collect()
                }
            }
        }
        let db = { (e: Double) in 10 * log10(max(e, 1e-20)) }
        print("[BedSplitGuide] per output: level change dB / difference below the signal dB / SNR to the exact render, before -> after")
        for (c, speaker) in layout.speakers.enumerated() where speaker != .lfe {
            print("[BedSplitGuide] \(speaker.rawValue): \(String(format: "%+.2f", db(energyNew[c]) - db(energyOld[c]))) / "
                  + String(format: "%.1f", db(energyOld[c]) - db(energyDiff[c])) + " / "
                  + String(format: "%.2f -> %.2f", db(energyTruth[c]) - db(errOld[c]), db(energyTruth[c]) - db(errNew[c])))
        }
        let positional = layout.speakers.indices.filter { layout.speakers[$0] != .lfe }
        let sum = { (e: [Double]) in positional.reduce(0) { $0 + e[$1] } }
        print("[BedSplitGuide] mean |level error| per speaker and window against the exact render: "
              + String(format: "%.3f -> %.3f dB over %d", levelErr.old / Double(max(levelErr.count, 1)),
                       levelErr.new / Double(max(levelErr.count, 1)), levelErr.count))
        print("[BedSplitGuide] all speakers SNR to the exact render: "
              + String(format: "%.2f -> %.2f dB", db(sum(energyTruth)) - db(sum(errOld)), db(sum(energyTruth)) - db(sum(errNew))))
        let total = { (e: [Double]) in e.reduce(0, +) }
        #expect(abs(db(total(energyNew)) - db(total(energyOld))) < 0.1, "the split still sums to the bed")
        // Measured (mean |level error| per speaker and 1024-frame window): Unfold 1.135 -> 0.940 dB,
        // Helicopter 0.441 -> 0.026, Furiosa and Dolby's 7.1.4 test unchanged.
        #expect(levelErr.new <= levelErr.old * 1.01 + 1e-3, "no further from the exact render than before")
    }
    #endif

    @Test("the bridge turns the whole sample into contiguous APAC packets in real time and then some")
    func bridgesToAPAC() throws {
        guard let data = Self.sample else { return }
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 48_000), layout: .l916, decoder: TrueHDObjectAudioDecoder())
        defer { bridge.close() }
        var pts: [Int64] = []
        var bytes = 0
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
                    pts.append(fp.pointee.pts); bytes += Int(fp.pointee.size)
                    var p: UnsafeMutablePointer<AVPacket>? = fp; trackedPacketFree(&p)
                }
                offset += n
            }
        }
        for fp in bridge.flush() {
            pts.append(fp.pointee.pts); bytes += Int(fp.pointee.size)
            var p: UnsafeMutablePointer<AVPacket>? = fp; trackedPacketFree(&p)
        }
        let elapsed = Date().timeIntervalSince(start)
        let seconds = Double(pts.count * 1024) / 48_000
        print("[TrueHDAtmosSample] 9.1.6 APAC: \(pts.count) packets, \(String(format: "%.2f", seconds)) s, "
              + "\(bytes * 8 / Int(seconds) / 1000) kbps, \(String(format: "%.1f", seconds / elapsed))x realtime (debug build)")
        #expect(pts.first == Int64(0))
        #expect(zip(pts, pts.dropFirst()).allSatisfy { $1 - $0 == 1024 })
        // Two packets of encoder priming, then the sample's 1,298,000 frames.
        #expect(pts.count == 2 + Int((1_298_000.0 / 1024).rounded(.up)))
    }
}
#endif
