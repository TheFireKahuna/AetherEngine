// The FEL overlay route: AVPlayer plays a Profile 7 FEL's base layer on the native route, and
// SoftwareOverlayRenderer shows FelCompositionSource's composition (the enhancement layer read by
// FelEnhancementTap) over its picture.
import AVFoundation
import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

@Suite("FEL overlay")
struct FelOverlayTests {

    @Test("the overlay is the default FEL route")
    func optionDefaultsOn() {
        #expect(LoadOptions().felOverlay == true)
    }
}

#if DualLayerDolbyVision
extension FelOverlayTests {

    /// A renderer over an idle tap, both closed by the caller.
    private func makeRenderer() throws -> (SoftwareOverlayRenderer, FelEnhancementTap) {
        let tap = FelEnhancementTap()
        let source = try #require(FelCompositionSource(tap: tap, baseLayerFullRange: false))
        return (SoftwareOverlayRenderer(item: AVPlayerItem(url: URL(fileURLWithPath: "/dev/null")), source: source), tap)
    }

    /// AVPlayerLayer builds its private sublayers at init: an intermediate layer holding the video
    /// container and `FigSubtitleCALayer`. This pins that shape, which `install(in:)` depends on.
    @Test("the overlay goes directly below AVPlayerLayer's subtitle layer")
    func installBelowSubtitles() throws {
        let playerLayer = AVPlayerLayer()
        playerLayer.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        let (renderer, tap) = try makeRenderer()
        defer { renderer.stop(); tap.close() }
        #expect(renderer.install(in: playerLayer))
        let host = try #require(renderer.layer.superlayer)
        let siblings = try #require(host.sublayers)
        let mine = try #require(siblings.firstIndex { $0 === renderer.layer })
        #expect(mine + 1 < siblings.count)
        if mine + 1 < siblings.count {
            #expect(String(describing: type(of: siblings[mine + 1])) == "FigSubtitleCALayer")
        }
        #expect(renderer.layer.frame == host.bounds)
        // It keeps the player layer's gravity, which a host's picture mode changes.
        playerLayer.videoGravity = .resizeAspectFill
        #expect(renderer.layer.videoGravity == .resizeAspectFill)
    }

    @Test("without that shape the overlay goes on top of the player layer")
    func installFallsBackToTop() throws {
        let playerLayer = AVPlayerLayer()
        playerLayer.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        playerLayer.sublayers?.forEach { $0.isHidden = true }
        let (renderer, tap) = try makeRenderer()
        defer { renderer.stop(); tap.close() }
        #expect(renderer.install(in: playerLayer) == false)
        #expect(renderer.layer.superlayer === playerLayer)
        #expect(renderer.layer.frame == playerLayer.bounds)
    }
}

/// On the real clips `DoviFelRealFileTests` uses (not checked in; every test skips without them).
@Suite(.offCooperativePoolOneLane)
struct FelOverlayRealFileTests {

    private static func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    /// Feeds `seconds` of the clip through the tap the way the segment producer does (output timestamps
    /// equal source timestamps on these clips), returning the presentation times fed and whether every
    /// rewrite matched `convertPacketToProfile81` byte for byte.
    private static func feed(_ tap: FelEnhancementTap, clip: String, seconds: Double) throws -> (pts: [Double], rewritesMatch: Bool) {
        let demuxer = Demuxer()
        try demuxer.open(url: DoviFelRealFileTests.url(clip))
        defer { demuxer.close() }
        let index = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: index))
        let tb = stream.pointee.time_base
        var fed: [Double] = []
        var match = true
        while let packet = try demuxer.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            guard packet.pointee.stream_index == index else { continue }
            let t = Double(packet.pointee.pts) * av_q2d(tb)
            if t > seconds { break }
            let reference = try #require(av_packet_clone(packet))
            var referenceOwned: UnsafeMutablePointer<AVPacket>? = reference
            defer { trackedPacketFree(&referenceOwned) }
            _ = DoviRpuConverter.convertPacketToProfile81(reference)
            _ = tap.rewrite(packet, opensRun: fed.isEmpty,
                            served: ServedVideoTime(pts: packet.pointee.pts, dts: packet.pointee.dts, timeBase: tb),
                            framing: .lengthPrefixed(size: 4), chromaLocation: 0)
            if packet.pointee.size != reference.pointee.size
                || memcmp(packet.pointee.data, reference.pointee.data, Int(packet.pointee.size)) != 0 { match = false }
            fed.append(t)
        }
        return (fed, match)
    }

    @Test("the tap rewrites the base layer as the plain conversion does and decodes near the clock",
          .enabled(if: DoviFelRealFileTests.available("fel-clip-a.mkv"), DoviFelRealFileTests.needsClips))
    func decodesNearTheClock() throws {
        let tap = FelEnhancementTap()
        defer { tap.close() }
        let (fed, rewritesMatch) = try Self.feed(tap, clip: "fel-clip-a.mkv", seconds: 12)
        // What AVPlayer is served is the same as without a tap (FEL RPUs in the composed form either way).
        #expect(rewritesMatch)
        let first = try #require(fed.min())
        tap.advance(to: first + 1)
        let near = fed.filter { $0 >= first + 1 && $0 < first + 1.5 }
        #expect(!near.isEmpty)
        #expect(Self.waitUntil(5) { near.allSatisfy { tap.frame(at: $0)?.enhancement != nil } })
        // Nothing further than the decode window ahead is decoded.
        #expect(tap.held.decoded <= Int((FelEnhancementTap.decodeAheadSeconds + 1) * 60))
    }

    @Test("a far clock jump decodes from the keyframe before the target",
          .enabled(if: DoviFelRealFileTests.available("fel-clip-a.mkv"), DoviFelRealFileTests.needsClips))
    func jumpRestartsAtKeyframe() throws {
        let tap = FelEnhancementTap()
        defer { tap.close() }
        let (fed, _) = try Self.feed(tap, clip: "fel-clip-a.mkv", seconds: 12)
        let first = try #require(fed.min())
        tap.advance(to: first + 0.5)
        #expect(Self.waitUntil(5) { tap.held.decoded > 0 })
        let target = try #require(fed.filter { $0 >= first + 9 }.min())
        tap.advance(to: target)
        #expect(Self.waitUntil(5) { tap.frame(at: target)?.enhancement != nil })
        // Parameters exist for every fed frame whether or not its picture is decoded.
        #expect(fed.allSatisfy { tap.frame(at: $0) != nil })
    }

    /// Loads the clip with the overlay, plays it muted and attaches to the overlay once the engine has it.
    @MainActor
    private func play(_ clip: String) async throws -> (AetherEngine, SoftwareOverlayRenderer, OverlayPresentations) {
        let engine = try AetherEngine()
        var options = LoadOptions()
        options.felOverlay = true
        _ = try await engine.load(url: DoviFelRealFileTests.url(clip), options: options)
        let player = try #require(engine.currentAVPlayer, "a FEL with felOverlay plays on the native route")
        player.isMuted = true
        engine.play()
        // The overlay comes with the item, which the engine learns of on the main actor after the player has it.
        let deadline = Date().addingTimeInterval(15)
        while engine.softwareOverlay == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let renderer = try #require(engine.softwareOverlay)
        let timebase = try #require(player.currentItem?.timebase)
        return (engine, renderer, OverlayPresentations(renderer, timebase: timebase))
    }

    /// The clip's frame interval, from its container.
    private static func frameInterval(_ clip: String) throws -> Double {
        let demuxer = Demuxer()
        try demuxer.open(url: DoviFelRealFileTests.url(clip))
        defer { demuxer.close() }
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        let rate = stream.pointee.avg_frame_rate
        return Double(rate.den) / Double(rate.num)
    }

    @Test("a FEL loaded with felOverlay stays native and composes every frame once, in order, ahead of its time",
          .enabled(if: DoviFelRealFileTests.available("fel-clip-a.mkv"), DoviFelRealFileTests.needsClips))
    @MainActor
    func engineComposesOverAVPlayer() async throws {
        let interval = try Self.frameInterval("fel-clip-a.mkv")
        let (engine, renderer, presented) = try await play("fel-clip-a.mkv")
        defer { engine.stop() }
        let source = try #require(renderer.source as? FelCompositionSource)
        #expect(try await presented.wait(forPictureAt: 0))
        let first = try #require(presented.all.first?.time)
        #expect(try await presented.wait(forPictureAt: first + 3))
        let faults = OverlayPresentations.faults(in: presented.all[...], interval: interval, steadyFrom: first + 1)
        #expect(faults.isEmpty, "\(faults.count) faults: \(faults.prefix(8))")
        let counters = renderer.counters
        #expect(counters.failed == 0)
        // Past the first second the enhancement layer is decoded in time: the residual is on.
        #expect(source.residualOff < counters.presented / 4)
    }

    @Test("a FEL seek forward, back, and while paused presents its target and composes on from it",
          .enabled(if: DoviFelRealFileTests.available("fel-clip-a.mkv"), DoviFelRealFileTests.needsClips))
    @MainActor
    func seeks() async throws {
        let interval = try Self.frameInterval("fel-clip-a.mkv")
        let (engine, _, presented) = try await play("fel-clip-a.mkv")
        defer { engine.stop() }
        #expect(try await presented.wait(forPictureAt: 2))
        for target in [20.0, 5.0] {
            let before = presented.count
            await engine.seek(to: target)
            #expect(try await presented.wait(forPictureAt: target + 1.5, before: target + 3, after: before), "seek to \(target)")
            let run = presented.run(afterSeekTo: target, after: before, interval: interval)
            let start = try #require(run.first?.time, "a picture near \(target) after the seek")
            #expect(start >= target - interval - 0.002 && start <= target + interval + 0.002,
                    "the first picture after the seek to \(target) is at \(start)")
            let faults = OverlayPresentations.faults(in: run, interval: interval, steadyFrom: target + 1)
            #expect(faults.isEmpty, "after the seek to \(target), \(faults.count) faults: \(faults.prefix(8))")
        }
        engine.pause()
        try await Task.sleep(for: .milliseconds(300))
        let before = presented.count
        let target = 10.0
        await engine.seek(to: target)
        try await Task.sleep(for: .seconds(2))
        let shown = presented.all.dropFirst(before)
        #expect(shown.contains { $0.time >= target - interval - 0.002 && $0.time <= target + 0.002 },
                "paused, the seek to \(target) presents the frame there; presented \(shown.map(\.time).prefix(12))")
    }
}
extension FelOverlayTests {

    @Test("every packet the tap serves carries a composed-form RPU, a borrowing one the last it served")
    func servedRpuIsTheComposedOne() throws {
        typealias R = DoviComposedFrameRpuTests
        let tap = FelEnhancementTap()
        defer { tap.close() }
        let noResidual = try #require(R.felNoResidualNAL)
        // A residual-off RPU, then one that fails to convert, then none: the last two borrow the first's parameters.
        let units: [[[UInt8]]] = [[R.slice, noResidual, R.enhancement], [R.slice, R.corruptNAL, R.enhancement], [R.slice, R.enhancement]]
        var first: [UInt8]?
        for (i, nals) in units.enumerated() {
            let pkt = R.avcc(nals)
            defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
            pkt.pointee.pts = Int64(i * 40)
            pkt.pointee.dts = Int64(i * 40)
            if i == 0 { pkt.pointee.flags |= AV_PKT_FLAG_KEY }
            _ = tap.rewrite(pkt, opensRun: i == 0,
                            served: ServedVideoTime(pts: pkt.pointee.pts, dts: pkt.pointee.dts,
                                                    timeBase: AVRational(num: 1, den: 1000)),
                            framing: .lengthPrefixed(size: 4), chromaLocation: 0)
            #expect(tap.frame(at: Double(i) * 0.04) != nil, "unit \(i)")
            let served = R.nals(of: pkt)
            #expect(served.count == 2 && served.first == R.slice, "unit \(i)")
            let rpu = try #require(served.last, "unit \(i)")
            let snapshot = try #require(R.snapshot(ofNAL: rpu))
            #expect(snapshot.isIdentityMapping, "unit \(i)")
            if let first { #expect(rpu == first, "unit \(i) borrows the first unit's RPU") } else { first = rpu }
        }
    }
}
#endif
