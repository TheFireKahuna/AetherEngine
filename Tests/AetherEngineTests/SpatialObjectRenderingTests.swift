// Only with the TrueHDObjectAudio or DTSXObjectAudio trait: the renderer is not built without one.
#if TrueHDObjectAudio || DTSXObjectAudio
import Testing
import Foundation
@testable import AetherEngine

/// TrueHD Atmos objects are rendered into a speaker bed by the engine, because Apple TV never
/// bitstreams and the receiver only ever sees what tvOS sends it as Dolby MAT. These pin the two
/// properties a renderer cannot get wrong without the room hearing it: an object at a speaker
/// comes out of that speaker alone, and moving an object never changes its loudness.
@Suite("Object audio renders into a speaker bed")
struct SpatialObjectRenderingTests {

    private func power(_ g: [Float]) -> Float { g.reduce(0) { $0 + $1 * $1 } }

    @Test("an object at a speaker's position plays from that speaker alone", arguments: SpatialSpeakerLayout.allCases)
    func objectAtSpeakerIsDiscrete(layout: SpatialSpeakerLayout) {
        let panner = AllocentricPanner(layout: layout)
        var gains: [Float] = []
        for (channel, speaker) in layout.speakers.enumerated() where !speaker.isLFE {
            panner.pointGains(speaker.position, into: &gains)
            #expect(abs(gains[channel] - 1) < 1e-5, "\(layout.rawValue) \(speaker)")
            #expect(abs(power(gains) - 1) < 1e-5)
        }
    }

    @Test("panning keeps unit power everywhere in the room and never feeds LFE", arguments: SpatialSpeakerLayout.allCases)
    func unitPower(layout: SpatialSpeakerLayout) {
        let panner = AllocentricPanner(layout: layout)
        var gains: [Float] = []
        let steps: [Float] = [0, 0.13, 0.25, 0.5, 0.61, 0.9, 1]
        for x in steps { for y in steps { for z in steps {
            panner.pointGains(SIMD3(x, y, z), into: &gains)
            #expect(abs(power(gains) - 1) < 1e-4, "\(layout.rawValue) at \(x),\(y),\(z)")
            #expect(gains[layout.lfeIndex] == 0)
        } } }
    }

    @Test("a position exactly on a speaker row or column gives that speaker all of it and the others nothing",
          arguments: SpatialSpeakerLayout.allCases + [.l20, .l51, .l71])
    func exactRowsAndColumns(layout: SpatialSpeakerLayout) {
        let panner = AllocentricPanner(layout: layout)
        var gains: [Float] = []
        for speaker in layout.speakers where !speaker.isLFE {
            panner.pointGains(speaker.position, into: &gains)
            let own = layout.speakers.firstIndex(of: speaker)!
            #expect(gains.indices.allSatisfy { gains[$0] == ($0 == own ? 1 : 0) }, "\(layout.rawValue) \(speaker): \(gains)")
        }
        for size: Float in [0.3, 0.9] {
            panner.objectGains(position: SIMD3(0, 0.5, 0), size: size, into: &gains)
            #expect(gains.allSatisfy { $0.isFinite && $0 >= 0 }, "\(layout.rawValue) size \(size)")
        }
    }

    @Test("an overhead object in the middle of the room splits evenly across the four tops")
    func overheadCentre() {
        let layout = SpatialSpeakerLayout.l714
        var gains: [Float] = []
        AllocentricPanner(layout: layout).pointGains(SIMD3(0.5, 0.5, 1), into: &gains)
        for (channel, speaker) in layout.speakers.enumerated() {
            #expect(abs(gains[channel] - (speaker.isHeight ? 0.5 : 0)) < 1e-5, "\(speaker)")
        }
    }

    @Test("ceiling speakers sit a quarter of the room in from the walls, as TS 103 448 places them")
    func ceilingTargetsAreInset() {
        let layout = SpatialSpeakerLayout.l714
        let panner = AllocentricPanner(layout: layout)
        let channel = { (speaker: SpatialSpeaker) in layout.speakers.firstIndex(of: speaker)! }
        var gains: [Float] = []
        // Out at the front-left ceiling corner, beyond the targets: the nearest top alone.
        panner.pointGains(SIMD3(0, 0, 1), into: &gains)
        #expect(abs(gains[channel(.topFrontLeft)] - 1) < 1e-5)
        // A third of the way back: mostly the front tops (93%), where corner targets gave 75%.
        panner.pointGains(SIMD3(0.5, 1 / 3, 1), into: &gains)
        let front = power([gains[channel(.topFrontLeft)], gains[channel(.topFrontRight)]])
        #expect(abs(front - 0.933) < 0.001)
    }

    @Test("a 5.1 layout's surrounds sit halfway down the side walls, as TS 103 448 places them",
          arguments: [SpatialSpeakerLayout.l512, .l514])
    func fiveOneSurroundsOnTheSideWalls(layout: SpatialSpeakerLayout) {
        let panner = AllocentricPanner(layout: layout)
        let channel = { (speaker: SpatialSpeaker) in layout.speakers.firstIndex(of: speaker)! }
        var gains: [Float] = []
        // Halfway down the left wall, and at the back-left corner beyond it: the surround alone.
        for y: Float in [0.5, 1] {
            panner.pointGains(SIMD3(0, y, 0), into: &gains)
            #expect(abs(gains[channel(.surroundLeft)] - 1) < 1e-5)
        }
        // A quarter of the way back: an even split with the front, where corner surrounds gave 15%.
        panner.pointGains(SIMD3(0, 0.25, 0), into: &gains)
        #expect(abs(gains[channel(.surroundLeft)] * gains[channel(.surroundLeft)] - 0.5) < 1e-5)
    }

    @Test("height content with no ceiling to go to folds onto the floor")
    func heightFoldsWithoutTops() {
        let layout = SpatialSpeakerLayout.l714
        let tops = Set(layout.speakers.filter(\.isHeight))
        var gains: [Float] = []
        AllocentricPanner(layout: layout, excluded: tops).pointGains(SIMD3(0, 0, 1), into: &gains)
        #expect(abs(gains[layout.speakers.firstIndex(of: .left)!] - 1) < 1e-5)
        #expect(abs(power(gains) - 1) < 1e-5)
    }

    @Test("divergence splits an object either side of it along x; size spreads with unit power")
    func divergenceAndSize() {
        let layout = SpatialSpeakerLayout.l714
        let panner = AllocentricPanner(layout: layout)
        var gains: [Float] = []
        // TS 103 448 pseudocode 15: at the centre with divergence 1, halves at x = 0 and x = 1.
        panner.objectGains(position: SIMD3(0.5, 0, 0), size: 0, divergence: 1, into: &gains)
        let half = Float(0.5).squareRoot()
        #expect(abs(gains[layout.speakers.firstIndex(of: .left)!] - half) < 1e-5)
        #expect(abs(gains[layout.speakers.firstIndex(of: .right)!] - half) < 1e-5)
        #expect(gains[layout.speakers.firstIndex(of: .center)!] < 1e-6)
        // Near a wall the spread shrinks to keep both halves inside: at x = 0.1 it is 0.2.
        panner.objectGains(position: SIMD3(0.1, 0, 0), size: 0.5, divergence: 1, into: &gains)
        var reference: [Float] = []
        panner.pointGains(SIMD3(0, 0, 0), into: &reference)
        var other: [Float] = []
        panner.pointGains(SIMD3(0.2, 0, 0), into: &other)
        let sum = zip(reference, other).map(+)
        let norm = power(sum).squareRoot()
        for c in gains.indices { #expect(abs(gains[c] - sum[c] / norm) < 1e-5) }

        panner.objectGains(position: SIMD3(0.5, 0.5, 0.5), size: 0.6, into: &gains)
        #expect(abs(power(gains) - 1) < 1e-4)
        #expect(gains.filter { $0 > 0.01 }.count >= 10, "a large object reaches most of the room")
        #expect(gains[layout.lfeIndex] == 0)
    }

    @Test("size follows TS 103 448's size panner (pseudocodes 7-14), as the reference probe computes it")
    func sizePanner() {
        // probes/ts103448_size.py on 7.1.4, channel order L R C Ls Rs Lrs Rrs Vhl Vhr Ltr Rtr.
        let cases: [(SIMD3<Float>, Float, [Float])] = [
            (SIMD3(0.5, 0, 0), 0.25, [0.273602, 0.273602, 0.861703, 0.207717, 0.207717, 0, 0, 0.103585, 0.103585, 0, 0]),
            (SIMD3(0.25, 0.4, 0.6), 0.5, [0.304005, 0.169154, 0.265656, 0.346168, 0.203891, 0.218110, 0.180817,
                                          0.492804, 0.299801, 0.411259, 0.254663]),
            (SIMD3(0, 1, 0), 1, [0.225163, 0.196513, 0.245808, 0.348137, 0.316066, 0.327558, 0.300895,
                                 0.326882, 0.295649, 0.360861, 0.326882]),
            (SIMD3(0.5, 0.5, 1), 0.1, [0, 0, 0, 0, 0, 0, 0, 0.5, 0.5, 0.5, 0.5]),
        ]
        let layout = SpatialSpeakerLayout.l714
        let panner = AllocentricPanner(layout: layout)
        var gains: [Float] = []
        for (position, size, expected) in cases {
            panner.objectGains(position: position, size: size, into: &gains)
            let withoutLFE = gains.enumerated().filter { $0.offset != layout.lfeIndex }.map(\.element)
            for (got, want) in zip(withoutLFE, expected) { #expect(abs(got - want) < 1e-4, "\(position) size \(size)") }
        }
    }

    @Test("a size along each axis follows TS 103 448's size panner, as the reference probe computes it")
    func sizePannerPerAxis() {
        // probes/ts103448_size.py size_pan(x, y, z, wx, wy, wz) on 7.1.4, order L R C Ls Rs Lrs Rrs Vhl Vhr Ltr Rtr.
        let cases: [(SIMD3<Float>, SIMD3<Float>, [Float])] = [
            (SIMD3(0.5, 0, 0), SIMD3(0.6, 0.1, 0),
             [0.529456, 0.529456, 0.649200, 0.073168, 0.073168, 0, 0, 0.059937, 0.059937, 0, 0]),
            (SIMD3(0.25, 0.4, 0.6), SIMD3(0.1, 0.5, 0.3),
             [0.326264, 0, 0.321510, 0.325460, 0.277318, 0.291610, 0.248326, 0.489826, 0.234784, 0.336904, 0.228239]),
            (SIMD3(0.5, 0.5, 0), SIMD3(0, 0, 0.8),
             [0.004500, 0.004500, 0.063247, 0.632035, 0.632035, 0.044973, 0.044973, 0.219645, 0.219645, 0.219645, 0.219645]),
            (SIMD3(0.7, 0.2, 0.3), SIMD3(0.3, 0.9, 0.05),
             [0.098501, 0.413013, 0.486043, 0.172151, 0.227997, 0.272433, 0.455654, 0.167888, 0.306361, 0.157123, 0.270721]),
        ]
        let layout = SpatialSpeakerLayout.l714
        let panner = AllocentricPanner(layout: layout)
        var gains: [Float] = []
        for (position, size, expected) in cases {
            panner.objectGains(position: position, size: size, into: &gains)
            let withoutLFE = gains.enumerated().filter { $0.offset != layout.lfeIndex }.map(\.element)
            for (got, want) in zip(withoutLFE, expected) { #expect(abs(got - want) < 1e-4, "\(position) size \(size)") }
        }
    }

    @Test("default trims leave 7.1.4 alone and pull the back and top down on smaller layouts")
    func defaultTrim() {
        let trim = ObjectAudioTrim.defaults
        #expect(trim.gain(at: SIMD3(0, 1, 1), on: .l714) == 1)
        // 5.1.2: num_mid 2, num_top 2, max_trim = -4.5 + 1.5 + 0.75 = -2.25 dB (pseudocode 16).
        let back = 20 * log10(trim.gain(at: SIMD3(0.5, 1, 0), on: .l512))
        #expect(abs(back + 2.25) < 1e-4)
        #expect(trim.gain(at: SIMD3(0.5, 0, 0), on: .l512) == 1, "on the screen wall, at ear level")
        // Halfway to full effect in y (0.3 of 0.6): half the maximum.
        #expect(abs(20 * log10(trim.gain(at: SIMD3(0.5, 0.3, 0), on: .l512)) + 1.125) < 1e-4)
    }

    @Test("custom trims follow pseudocode 17 for the layout's trim configuration")
    func customTrim() {
        var configs = [ObjectAudioTrim.Mode](repeating: .default, count: 9)
        configs[4] = .custom(centre: 0, surround: -3, height: -6)   // 5.1.2: trim_cfg 4
        configs[8] = .disabled                                       // 7.1.4
        let trim = ObjectAudioTrim(configs: configs)
        #expect(trim.gain(at: SIMD3(0, 1, 1), on: .l714) == 1)
        #expect(abs(20 * log10(trim.gain(at: SIMD3(0.5, 1, 1), on: .l512)) + 9) < 1e-4)
        #expect(abs(20 * log10(trim.gain(at: SIMD3(0.5, 0.25, 0.5), on: .l512)) + 4.5) < 1e-4)
    }

    // MARK: - Renderer

    private func render(
        _ renderer: ObjectAudioRenderer, inputs: [[Float]], frames: Int, updates: [ObjectAudioMetadataUpdate]
    ) -> [[Float]] {
        var outputs = [[Float]](repeating: [Float](repeating: 0, count: frames), count: renderer.layout.channelCount)
        let inPtrs = inputs.map { buf -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            p.initialize(from: buf, count: frames)
            return p
        }
        let outPtrs = outputs.map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        renderer.render(inputs: inPtrs.map { UnsafePointer($0) }, frameCount: frames, updates: updates, outputs: outPtrs)
        for c in outputs.indices { outputs[c] = Array(UnsafeBufferPointer(start: outPtrs[c], count: frames)) }
        (inPtrs + outPtrs).forEach { $0.deallocate() }
        return outputs
    }

    @Test("bed channels and LFE pass straight through to their speakers")
    func bedPassthrough() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.bed(.left), .lfe, .bed(.topMiddleLeft)])
        let frames = 64
        let a = (0..<frames).map { Float($0) / 64 }
        let b = (0..<frames).map { Float(-$0) / 64 }
        let c = [Float](repeating: 0.25, count: frames)
        let out = render(renderer, inputs: [a, b, c], frames: frames, updates: [])
        #expect(out[layout.speakers.firstIndex(of: .left)!] == a)
        #expect(out[layout.lfeIndex] == b)
        // 7.1.4 has no top-middle pair: the bed's Ltm becomes a phantom between Ltf and Ltr.
        let ltf = out[layout.speakers.firstIndex(of: .topFrontLeft)!]
        let ltr = out[layout.speakers.firstIndex(of: .topRearLeft)!]
        #expect(abs(ltf[0] - 0.25 * cos(Float.pi / 4)) < 1e-5)
        #expect(abs(ltr[0] - 0.25 * cos(Float.pi / 4)) < 1e-5)
    }

    @Test("an object is silent until its first metadata, then follows its ramps")
    func objectRamps() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.object])
        let ones = [Float](repeating: 1, count: 100)
        #expect(render(renderer, inputs: [ones], frames: 100, updates: []).allSatisfy { $0.allSatisfy { $0 == 0 } })

        let left = ObjectAudioElementState(position: SIMD3(0, 0, 0))
        let right = ObjectAudioElementState(position: SIMD3(1, 0, 0))
        let l = layout.speakers.firstIndex(of: .left)!, r = layout.speakers.firstIndex(of: .right)!
        var out = render(renderer, inputs: [ones], frames: 100,
                         updates: [.init(frameOffset: 10, rampFrames: 0, states: [left])])
        #expect(out[l][9] == 0 && out[l][10] == 1 && out[r][50] == 0)

        // A 100-frame ramp to the right, split across two blocks: halfway through, the gains are
        // halfway, and the ramp resumes where it left off in the next block.
        out = render(renderer, inputs: [ones], frames: 100,
                     updates: [.init(frameOffset: 50, rampFrames: 100, states: [right])])
        #expect(out[l][49] == 1)
        #expect(abs(out[l][99] - 0.5) < 0.02 && abs(out[r][99] - 0.5) < 0.02)
        out = render(renderer, inputs: [ones], frames: 100, updates: [])
        // ramp_duration + 1 frames: the last step lands 100 frames after the update's.
        #expect(abs(out[l][50]) < 1e-5 && abs(out[r][50] - 1) < 1e-5)
        #expect(abs(out[r][99] - 1) < 1e-5)
    }

    @Test("an object's first metadata is a jump even when it asks for a ramp, so nothing fades in after a seek")
    func firstMetadataJumps() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.object])
        let ones = [Float](repeating: 1, count: 64)
        let l = layout.speakers.firstIndex(of: .left)!
        var out = render(renderer, inputs: [ones], frames: 64, updates: [
            .init(frameOffset: 0, rampFrames: 1536, states: [ObjectAudioElementState(position: SIMD3(0, 0, 0))])])
        #expect(out[l][0] == 1)
        renderer.reset()
        out = render(renderer, inputs: [ones], frames: 64, updates: [
            .init(frameOffset: 0, rampFrames: 1536, states: [ObjectAudioElementState(position: SIMD3(0, 0, 0))])])
        #expect(out[l][0] == 1, "reset forgets the position, so the next first update jumps again")
    }

    @Test("after a resync an object holds its place and jumps to its next position instead of sweeping there")
    func discontinuityJumps() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.object])
        let ones = [Float](repeating: 1, count: 64)
        let l = layout.speakers.firstIndex(of: .left)!, r = layout.speakers.firstIndex(of: .right)!
        _ = render(renderer, inputs: [ones], frames: 64, updates: [
            .init(frameOffset: 0, rampFrames: 0, states: [ObjectAudioElementState(position: SIMD3(0, 0, 0))])])
        renderer.markDiscontinuity()
        var out = render(renderer, inputs: [ones], frames: 64, updates: [])
        #expect(out[l][0] == 1, "holds its last position until metadata arrives")
        out = render(renderer, inputs: [ones], frames: 64, updates: [
            .init(frameOffset: 0, rampFrames: 1536, states: [ObjectAudioElementState(position: SIMD3(1, 0, 0))])])
        #expect(out[r][0] == 1 && out[l][0] == 0)
    }

    @Test("an unchanged element in an update keeps its ramp running")
    func unchangedElementKeepsRamp() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.object, .object])
        let ones = [Float](repeating: 1, count: 200)
        let r = layout.speakers.firstIndex(of: .right)!
        let left = ObjectAudioElementState(position: SIMD3(0, 0, 0))
        let right = ObjectAudioElementState(position: SIMD3(1, 0, 0))
        let out = render(renderer, inputs: [ones, [Float](repeating: 0, count: 200)], frames: 200, updates: [
            .init(frameOffset: 0, rampFrames: 0, states: [left, left]),
            .init(frameOffset: 0, rampFrames: 199, states: [right, nil]),
            // Element 0 restated as unchanged halfway: its ramp must not restart.
            .init(frameOffset: 100, rampFrames: 0, states: [nil, right]),
        ])
        #expect(abs(out[r][149] - 0.75) < 0.02)
        #expect(abs(out[r][199] - 1) < 1e-5)
    }

    @Test("an update restating an element restarts its ramp from where it has got to (pseudocode 19)")
    func restatementRestartsRamp() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.object])
        let ones = [Float](repeating: 1, count: 300)
        let r = layout.speakers.firstIndex(of: .right)!
        let left = ObjectAudioElementState(position: SIMD3(0, 0, 0))
        let right = ObjectAudioElementState(position: SIMD3(1, 0, 0))
        let out = render(renderer, inputs: [ones], frames: 300, updates: [
            .init(frameOffset: 0, rampFrames: 0, states: [left]),
            .init(frameOffset: 0, rampFrames: 199, states: [right]),
            // Restated at frame 100, halfway, over another 200 frames: from 0.5, a quarter of the way on at 149.
            .init(frameOffset: 100, rampFrames: 199, states: [right]),
        ])
        #expect(abs(out[r][149] - 0.625) < 0.01)
        #expect(abs(out[r][299] - 1) < 1e-5)
    }

    @Test("a snapshot mid-ramp reports the object where its ramp has got to, position and gain as its gains")
    func snapshotFollowsTheRamp() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.object])
        var snapshot = ObjectAudioGainSnapshot()
        renderer.advance(frameCount: 100, updates: [
            .init(frameOffset: 0, rampFrames: 0, states: [ObjectAudioElementState(position: SIMD3(0, 0, 0), gain: 1)]),
            .init(frameOffset: 0, rampFrames: 199, states: [ObjectAudioElementState(position: SIMD3(1, 0, 0), gain: 0.5)]),
        ])
        renderer.snapshot(into: &snapshot)
        // 100 of the ramp's 200 steps.
        #expect(abs(snapshot.positions[0]!.x - 0.5) < 1e-6)
        #expect(abs(snapshot.gains[0] - 0.75) < 1e-6)
        renderer.advance(frameCount: 100, updates: [])
        renderer.snapshot(into: &snapshot)
        #expect(snapshot.positions[0] == SIMD3(1, 0, 0) && snapshot.gains[0] == 0.5)
    }

    @Test("a custom trim's balance fades the far end of the room (TS 103 420 5.6.5.9-12)")
    func trimBalance() {
        // Towards the back by 0.5 at ear level: the front wall at half its level, the back untouched.
        #expect(ObjectAudioTrim.balanceGain(at: SIMD3(0.5, 0, 0), top: 0, listener: 0.5) == 0.5)
        #expect(ObjectAudioTrim.balanceGain(at: SIMD3(0.5, 1, 0), top: 0, listener: 0.5) == 1)
        // Towards the front by 1 overhead: the back of the ceiling silent, halfway up half of it.
        #expect(ObjectAudioTrim.balanceGain(at: SIMD3(0.5, 1, 1), top: -1, listener: 0) == 0)
        #expect(ObjectAudioTrim.balanceGain(at: SIMD3(0.5, 1, 0.5), top: -1, listener: 0) == 0.5)
        var configs = [ObjectAudioTrim.Mode](repeating: .default, count: 9)
        configs[1] = .custom(centre: 0, surround: 0, height: 0, balanceTop: 0, balanceListener: 0.5)   // 5.1: trim_cfg 1
        #expect(abs(ObjectAudioTrim(configs: configs).gain(at: SIMD3(0.5, 0, 0), on: .l51) - 0.5) < 1e-6)
    }

    @Test("a new target mid-ramp starts from where the ramp had got to")
    func retargetMidRamp() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.object])
        let ones = [Float](repeating: 1, count: 200)
        let l = layout.speakers.firstIndex(of: .left)!, r = layout.speakers.firstIndex(of: .right)!
        let out = render(renderer, inputs: [ones], frames: 200, updates: [
            .init(frameOffset: 0, rampFrames: 0, states: [ObjectAudioElementState(position: SIMD3(0, 0, 0))]),
            .init(frameOffset: 0, rampFrames: 100, states: [ObjectAudioElementState(position: SIMD3(1, 0, 0))]),
            .init(frameOffset: 50, rampFrames: 0, states: [ObjectAudioElementState(position: SIMD3(0, 0, 0))]),
        ])
        #expect(abs(out[l][49] - 0.51) < 0.02 && out[r][49] > 0.4)
        #expect(out[l][50] == 1 && out[r][50] == 0)
    }

    // MARK: - Review round 1 (#731)

    @Test("a ramp of d lands frame by frame on (k + 1) / (d + 1) of the way, and finishes on the target")
    func rampIsExactPerFrame() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.object])
        let ones = [Float](repeating: 1, count: 100)
        let l = layout.speakers.firstIndex(of: .left)!, r = layout.speakers.firstIndex(of: .right)!
        _ = render(renderer, inputs: [ones], frames: 100, updates: [
            .init(frameOffset: 0, rampFrames: 0, states: [ObjectAudioElementState(position: SIMD3(0, 0, 0))])])
        // Spread over three blocks of 40 frames, so the ramp crosses two block boundaries.
        var left: [Float] = [], right: [Float] = []
        for block in 0..<3 {
            let updates: [ObjectAudioMetadataUpdate] = block == 0
                ? [.init(frameOffset: 0, rampFrames: 100, states: [ObjectAudioElementState(position: SIMD3(1, 0, 0))])]
                : []
            let out = render(renderer, inputs: [[Float](repeating: 1, count: 40)], frames: 40, updates: updates)
            left += out[l]; right += out[r]
        }
        // TS 103 448 pseudocode 19: ramp_duration + 1 steps, the first on the update's frame.
        for k in 0...100 {
            let t = Float(k + 1) / 101
            #expect(abs(left[k] - (1 - t)) < 1e-5, "frame \(k)")
            #expect(abs(right[k] - t) < 1e-5, "frame \(k)")
        }
        #expect(left[101...].allSatisfy { abs($0) < 1e-6 } && right[101...].allSatisfy { abs($0 - 1) < 1e-6 })
    }

    @Test("a resync mid-ramp freezes the object where the ramp had got to")
    func discontinuityMidRampHolds() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.object])
        let ones = [Float](repeating: 1, count: 50)
        let l = layout.speakers.firstIndex(of: .left)!, r = layout.speakers.firstIndex(of: .right)!
        _ = render(renderer, inputs: [ones], frames: 50, updates: [
            .init(frameOffset: 0, rampFrames: 0, states: [ObjectAudioElementState(position: SIMD3(0, 0, 0))]),
            .init(frameOffset: 0, rampFrames: 99, states: [ObjectAudioElementState(position: SIMD3(1, 0, 0))])])
        renderer.markDiscontinuity()
        let out = render(renderer, inputs: [ones], frames: 50, updates: [])
        #expect(abs(out[l][0] - 0.5) < 1e-5 && abs(out[l][49] - 0.5) < 1e-5)
        #expect(abs(out[r][0] - 0.5) < 1e-5 && abs(out[r][49] - 0.5) < 1e-5)
    }

    @Test("a reset in the middle of a bed fade brings the bed back at unit gain")
    func resetRestoresBedGain() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.bed(.left)])
        let ones = [Float](repeating: 1, count: 50)
        let l = layout.speakers.firstIndex(of: .left)!
        _ = render(renderer, inputs: [ones], frames: 50, updates: [
            .init(frameOffset: 0, rampFrames: 100, states: [ObjectAudioElementState(gain: 0)])])
        renderer.reset()
        let out = render(renderer, inputs: [ones], frames: 50, updates: [])
        #expect(out[l].allSatisfy { $0 == 1 })
    }

    @Test("a block from another configuration renders silence instead of trapping")
    func configurationMismatchIsSilent() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.bed(.left), .bed(.right)])
        let out = render(renderer, inputs: [[Float](repeating: 1, count: 32)], frames: 32, updates: [])
        #expect(out.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    /// One bed channel's gains on `layout`, the rest of a `bed` silent.
    private func bedGains(_ speaker: SpatialSpeaker, of bed: [SpatialSpeaker], on layout: SpatialSpeakerLayout) -> [Float] {
        let renderer = ObjectAudioRenderer(layout: layout, roles: bed.map { .bed($0) })
        let inputs = bed.map { [Float](repeating: $0 == speaker ? 1 : 0, count: 4) }
        return render(renderer, inputs: inputs, frames: 4, updates: []).map { $0[0] }
    }

    private static let bed712: [SpatialSpeaker] = [.left, .right, .center, .sideLeft, .sideRight, .rearLeft, .rearRight,
                                                   .topMiddleLeft, .topMiddleRight]
    private static let bed514: [SpatialSpeaker] = [.left, .right, .center, .sideLeft, .sideRight,
                                                   .topFrontLeft, .topFrontRight, .topRearLeft, .topRearRight]

    @Test("TS 103 448 table 6: a 7.1 bed's sides and backs fold onto 5.1's surrounds at -3 dB each, never into the front",
          arguments: [SpatialSpeakerLayout.l51, .l512, .l514])
    func bedSurroundsFoldOnFiveOne(layout: SpatialSpeakerLayout) {
        let m = Float(0.5).squareRoot()
        for (speaker, target) in [(SpatialSpeaker.sideLeft, SpatialSpeaker.surroundLeft), (.rearRight, .surroundRight)] {
            let g = bedGains(speaker, of: Self.bed712, on: layout)
            #expect(abs(g[layout.speakers.firstIndex(of: target)!] - m) < 1e-6, "\(speaker)")
            #expect(abs(power(g) - 0.5) < 1e-6, "\(speaker) only there")
        }
        // A 5.1 bed has no backs: its surrounds go straight through (g = 1).
        let g = bedGains(.sideLeft, of: Self.bed514, on: layout)
        #expect(g[layout.speakers.firstIndex(of: .surroundLeft)!] == 1)
    }

    @Test("TS 103 448 table 6 on stereo: centre and surrounds at -3 dB, backs, tops and wides at -6 dB")
    func bedOnStereo() {
        let m = Float(0.5).squareRoot()
        let (l, r) = (0, 1)
        let centre = bedGains(.center, of: Self.bed712, on: .l20)
        #expect(abs(centre[l] - m) < 1e-6 && abs(centre[r] - m) < 1e-6)
        // With backs, g = m: a side surround at g * m.
        #expect(abs(bedGains(.sideRight, of: Self.bed712, on: .l20)[r] - 0.5) < 1e-6)
        #expect(abs(bedGains(.sideRight, of: Self.bed514, on: .l20)[r] - m) < 1e-6)
        for speaker in [SpatialSpeaker.rearLeft, .topMiddleLeft] {
            let g = bedGains(speaker, of: Self.bed712, on: .l20)
            #expect(g[l] == 0.5 && g[r] == 0, "\(speaker)")
        }
        #expect(bedGains(.topFrontRight, of: Self.bed514, on: .l20) == [0, 0.5, 0])
    }

    @Test("TS 103 448 table 6: top channels a layout lacks fold onto the surrounds or split between the tops it has")
    func bedTopsFold() {
        let m = Float(0.5).squareRoot()
        // 7.1.2's top middles on 7.1.4: half the power to the front and back tops.
        let onAtmos = bedGains(.topMiddleLeft, of: Self.bed712, on: .l714)
        #expect(abs(onAtmos[SpatialSpeakerLayout.l714.speakers.firstIndex(of: .topFrontLeft)!] - m) < 1e-6)
        #expect(abs(onAtmos[SpatialSpeakerLayout.l714.speakers.firstIndex(of: .topRearLeft)!] - m) < 1e-6)
        // On 7.1, onto the sides at -3 dB; on 5.1, onto the surrounds.
        let onSeven = bedGains(.topRearRight, of: Self.bed514, on: .l71)
        #expect(abs(onSeven[SpatialSpeakerLayout.l71.speakers.firstIndex(of: .sideRight)!] - m) < 1e-6)
        #expect(abs(power(onSeven) - 0.5) < 1e-6)
        // 5.1.4's tops on 7.1.2: onto the top middles at -3 dB.
        let onTwo = bedGains(.topFrontLeft, of: Self.bed514, on: .l712)
        #expect(abs(onTwo[SpatialSpeakerLayout.l712.speakers.firstIndex(of: .topMiddleLeft)!] - m) < 1e-6)
    }

    @Test("a 5.1 bed's surrounds land on a 7.1 layout's sides")
    func fiveOneSurroundsOnSevenOne() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.bed(.surroundLeft)])
        let ones = [Float](repeating: 1, count: 16)
        let out = render(renderer, inputs: [ones], frames: 16, updates: [])
        #expect(out[layout.speakers.firstIndex(of: .sideLeft)!] == ones)
    }

    @Test("a bed channel at a position the room names no speaker for plays without any metadata")
    func fixedBedPlaysWithoutMetadata() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.fixed(SIMD3(0.5, 1, 0))])
        let ones = [Float](repeating: 1, count: 16)
        let out = render(renderer, inputs: [ones], frames: 16, updates: [])
        let half = cos(Float.pi / 4)
        #expect(abs(out[layout.speakers.firstIndex(of: .rearLeft)!][0] - half) < 1e-5)
        #expect(abs(out[layout.speakers.firstIndex(of: .rearRight)!][0] - half) < 1e-5)
        #expect(abs(power(out.map { $0[0] }) - 1) < 1e-5)
    }

    @Test("objects keep unit power with size and every zone mask, on every layout",
          arguments: SpatialSpeakerLayout.allCases)
    func unitPowerWithSizeAndZones(layout: SpatialSpeakerLayout) {
        let masks: [Set<SpatialSpeaker>] = [
            [], [.rearLeft, .rearRight, .surroundLeft, .surroundRight], [.sideLeft, .sideRight, .wideLeft, .wideRight],
            [.left, .right, .wideLeft, .wideRight, .sideLeft, .sideRight],
            Set(SpatialSpeaker.allCases.filter(\.isHeight)),
        ]
        var gains: [Float] = []
        for mask in masks {
            let panner = AllocentricPanner(layout: layout, excluded: mask)
            for size: Float in [0, 0.1, 0.5, 1] {
                for p in [SIMD3<Float>(0.1, 0.9, 0.7), SIMD3(0.5, 0.5, 0), SIMD3(1, 0, 1)] {
                    panner.objectGains(position: p, size: size, into: &gains)
                    #expect(abs(power(gains) - 1) < 1e-4, "\(layout.rawValue) size \(size) at \(p)")
                    #expect(gains[layout.lfeIndex] == 0)
                }
            }
        }
    }
}
#endif
