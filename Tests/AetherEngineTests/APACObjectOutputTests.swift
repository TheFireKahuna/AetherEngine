// Only with the APACObjectOutput trait (personal builds).
#if APACObjectOutput
import Accelerate
import AudioToolbox
import Foundation
import Testing
@testable import AetherEngine

/// Object APAC is checked the way the research measured it: encode, then decode through an
/// `AudioConverter` asked for 7.1.4, which inserts the system's spatial renderer, and read where each
/// element's energy lands. Serialized, as a session runs one encoder.
@Suite("APAC object output", .serialized)
struct APACObjectOutputTests {

    /// 7.1.4 in the order the converter writes it.
    enum Out: Int { case l, r, c, lfe, ls, rs, lrs, rrs, vhl, vhr, ltr, rtr }

    // MARK: - Cookie

    @Test("the CODECS read from a bed encoder's cookie match the channel-count tier",
          arguments: [SpatialSpeakerLayout.l714, .l916])
    func codecsFromBedCookie(layout: SpatialSpeakerLayout) throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let encoder = try APACEncoder(layout: layout, bitRate: layout.channelCount * 320_000)
        #expect(APACSampleEntry.codecsString(magicCookie: encoder.magicCookie)
                == APACSampleEntry.codecsString(channelCount: layout.channelCount))
    }

    @Test("the object encoder opens: a dapa cookie, low profile, 2048 frames of priming")
    func opens() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let encoder = try APACObjectEncoder(bitRate: 17 * 320_000)
        let cookie = [UInt8](encoder.magicCookie)
        #expect(String(bytes: cookie[4..<8], encoding: .ascii) == "dapa")
        #expect(encoder.hlsCodecs == "apac.05.00")
        #expect(encoder.leadingFrames == 2048)
    }

    @Test("the object codec makes a sync packet every interval from its start, again after a reset; the stream says the same")
    func syncPackets() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let encoder = try APACObjectEncoder(bitRate: 17 * 320_000, output: .l714)
        let buffer = APACEncodePipeline.PlaneBuffer(channels: APACObjectEncoder.elementCapacity, capacity: 2048)
        buffer.objectRoles = Self.roles
        for plane in buffer.planes { for i in 0..<2048 { plane[i] = 0.1 * sin(Float(i) * 0.05) } }
        func run() throws -> [APACEncoder.Packet] {
            var packets: [APACEncoder.Packet] = []
            for chunk in 0..<((APACEncoder.syncPacketInterval * 2 + 8) / 2) {
                buffer.objectUpdates = chunk == 0 ? [.init(frameOffset: 0, rampFrames: 0, states: [nil, nil, nil, nil, nil])] : []
                packets += try encoder.encode(buffer, frames: 2048)
            }
            return packets
        }
        for pass in 0..<2 {
            let packets = try run()
            #expect(packets.indices.filter { packets[$0].isSync }
                    == Array(stride(from: 0, to: packets.count, by: APACEncoder.syncPacketInterval)), "pass \(pass)")
            #expect(packets.allSatisfy { $0.isSync == APACEncoderTests.headerSaysSync($0) }, "pass \(pass): the stream says the same")
            _ = try encoder.flush()
            encoder.reset()
        }
    }

    // MARK: - Placement

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let element: Int
        let state: ObjectAudioElementState?
        let expect: [Out]
        var testDescription: String { name }
    }

    static let roles: [ObjectAudioRole] = [.bed(.left), .lfe, .object, .bed(.topFrontRight), .fixed(SIMD3(0.5, 1, 0))]

    static let placements: [Case] = [
        Case(name: "bed left on L", element: 0, state: nil, expect: [.l]),
        Case(name: "LFE on the LFE", element: 1, state: nil, expect: [.lfe]),
        Case(name: "object on the left side", element: 2,
             state: ObjectAudioElementState(position: SIMD3(0, 0.5, 0)), expect: [.ls]),
        Case(name: "object in the rear right corner", element: 2,
             state: ObjectAudioElementState(position: SIMD3(1, 1, 0)), expect: [.rrs]),
        Case(name: "object kept out of the back plays from the sides (speaker bus)", element: 2,
             state: ObjectAudioElementState(position: SIMD3(0, 1, 0), excluded: [.rearLeft, .rearRight]), expect: [.ls]),
        Case(name: "screen-only object at the side plays from the front (speaker bus)", element: 2,
             state: ObjectAudioElementState(position: SIMD3(1, 0.5, 0),
                                            excluded: [.sideLeft, .sideRight, .rearLeft, .rearRight]), expect: [.r]),
        Case(name: "divergent object at the centre plays from L and R (speaker bus)", element: 2,
             state: ObjectAudioElementState(position: SIMD3(0.5, 0, 0), divergence: 1), expect: [.l, .r]),
        Case(name: "bed top front right on Vhr", element: 3, state: nil, expect: [.vhr]),
        Case(name: "centre back between the rears", element: 4, state: nil, expect: [.lrs, .rrs]),
    ]

    @Test("each element lands where it should", arguments: placements)
    func placement(_ c: Case) throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        var states = [ObjectAudioElementState?](repeating: nil, count: Self.roles.count)
        states[c.element] = c.state
        let out = try render(roles: Self.roles, signalOn: c.element, frames: 48_000,
                             updates: [.init(frameOffset: 0, rampFrames: 0, states: states)])
        let shares = Self.shares(out, from: 8192, to: 48_000)
        let expected = c.expect.reduce(Float(0)) { $0 + shares[$1.rawValue] }
        #expect(expected > 0.97, "shares \(Self.describe(shares))")
    }

    @Test("a bed stream ending as an object stream starts leaves the objects their positions",
          arguments: [false, true])
    func bedEndAtObjectStart(afterReset: Bool) throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        // A bed encoder running before the object codec is set up (or reset), ending its stream before
        // the object encoder codes its first frames: with the codec initialized in `init`, or kept
        // initialized over a reset, every stream lost its metadata (`APACCodecGate`).
        let bedPlanes = (0..<12).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 4096) }
        defer { bedPlanes.forEach { $0.deallocate() } }
        for p in bedPlanes { p.initialize(repeating: 0, count: 4096) }
        let bed = try APACEncoder(layout: .l714, bitRate: 12 * 320_000)
        _ = try bed.encode(planes: bedPlanes.map { UnsafePointer($0) }, frameCount: 4096)

        let encoder = try APACObjectEncoder(bitRate: 17 * 320_000, output: .l714)
        let buffer = APACEncodePipeline.PlaneBuffer(channels: APACObjectEncoder.elementCapacity, capacity: 2048)
        buffer.objectRoles = Self.roles
        var seed: UInt64 = 1
        func encode(chunks: Int) throws -> [Data] {
            var packets: [Data] = []
            for chunk in 0..<chunks {
                for (e, plane) in buffer.planes.enumerated() {
                    for i in 0..<2048 {
                        seed = seed &* 6364136223846793005 &+ 1442695040888963407
                        plane[i] = e == 0 ? 0.25 * (Float(seed >> 40) / Float(1 << 24) * 2 - 1) : 0
                    }
                }
                buffer.objectUpdates = chunk == 0 ? [.init(frameOffset: 0, rampFrames: 0, states: [nil, nil, nil, nil, nil])] : []
                packets += try encoder.encode(buffer, frames: 2048).map(\.data)
            }
            return packets + (try encoder.flush().map(\.data))
        }
        if afterReset {
            _ = try encode(chunks: 4)
            encoder.reset()
        }
        _ = try bed.flush()
        let out = try Self.decode(try encode(chunks: 8), cookie: encoder.magicCookie)
        let shares = Self.shares(out, from: 8192, to: 16_384)
        #expect(shares[Out.l.rawValue] > 0.97, "shares \(Self.describe(shares))")
    }

    @Test("an object without elevation stays at ear level")
    func elevationOff() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let heights = Set(SpatialSpeaker.allCases.filter(\.isHeight))
        let state = ObjectAudioElementState(position: SIMD3(0.25, 0.25, 1), excluded: heights, elevation: false)
        let out = try render(roles: Self.roles, signalOn: 2, frames: 48_000,
                             updates: [.init(frameOffset: 0, rampFrames: 0, states: [nil, nil, state, nil, nil])])
        let shares = Self.shares(out, from: 8192, to: 48_000)
        let up = [Out.vhl, .vhr, .ltr, .rtr].reduce(Float(0)) { $0 + shares[$1.rawValue] }
        #expect(up < 0.01, "shares \(Self.describe(shares))")
    }

    @Test("an element plays at its own level", arguments: [
        Case(name: "object", element: 2, state: ObjectAudioElementState(position: SIMD3(0.25, 0.25, 1)), expect: []),
        Case(name: "object on a speaker", element: 2, state: ObjectAudioElementState(position: SIMD3(0, 0, 0)), expect: []),
        Case(name: "bed channel", element: 0, state: nil, expect: []),
        Case(name: "LFE", element: 1, state: nil, expect: [.lfe]),
    ])
    func level(_ c: Case) throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        var states = [ObjectAudioElementState?](repeating: nil, count: Self.roles.count)
        states[c.element] = c.state
        let out = try render(roles: Self.roles, signalOn: c.element, frames: 48_000,
                             updates: [.init(frameOffset: 0, rampFrames: 0, states: states)], tone: true)
        // Against the same tone through the bed encoder on its left channel, which the engine's own
        // render is. A tone, since on white noise the object coding lands 0.3 dB below the bed's
        // (single tones from 14 to 21 kHz match within 0.25 dB, so it is not the band).
        let frames = 48_000 - 8192 - 4096
        let total = { (o: [[Float]]) in (0..<12).reduce(Float(0)) { $0 + Self.power(o[$1], 8192, 8192 + frames) } }
        let reference = try bedReference(frames: 48_000, channel: c.expect == [.lfe] ? Out.lfe.rawValue : 0)
        let db = 10 * log10(total(out) / total(reference))
        #expect(abs(db) < 0.25, "\(db) dB against the bed encoder")
    }

    /// Every bed channel of a 7.1.4 presentation, the centre among them, plays from its own speaker at the
    /// level the channel bed gives that channel: the renderer attenuates by distance from the room's
    /// centre (the corners 3 dB, the tops 1.8, the centre none), and the object carrying each bed
    /// channel undoes it (`distanceCompensation`), so no channel moves against the dialogue.
    @Test("each 7.1.4 bed channel plays on its speaker at the channel bed's level",
          arguments: SpatialSpeakerLayout.l714.speakers.filter { !$0.isLFE })
    func bedChannelLevel(_ speaker: SpatialSpeaker) throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let roles = SpatialSpeakerLayout.l714.speakers.map { $0.isLFE ? ObjectAudioRole.lfe : .bed($0) }
        let channel = SpatialSpeakerLayout.l714.speakers.firstIndex(of: speaker)!
        let out = try render(roles: roles, signalOn: channel, frames: 48_000, updates: [], tone: true)
        let reference = try bedReference(frames: 48_000, channel: channel)
        let (from, to) = (8192, 48_000 - 4096)
        let db = 10 * log10(Self.power(out[channel], from, to) / Self.power(reference[channel], from, to))
        let share = Self.shares(out, from: from, to: to)[channel]
        print(String(format: "[bedChannelLevel] %@ %+.2f dB against the channel bed, %.1f%% on its speaker",
                     speaker.rawValue, db, share * 100))
        #expect(abs(db) < 0.25, "\(db) dB against the channel bed")
        #expect(share > 0.99, "shares \(Self.describe(Self.shares(out, from: from, to: to)))")
    }

    /// The same 1 kHz tone on the left channel of a 7.1.4 bed through `APACEncoder`, decoded alike.
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func bedReference(frames: Int, channel: Int = 0) throws -> [[Float]] {
        let layout = SpatialSpeakerLayout.l714
        let encoder = try APACEncoder(layout: layout, bitRate: layout.channelCount * 320_000)
        let planes = (0..<layout.channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        defer { planes.forEach { $0.deallocate() } }
        for i in 0..<frames {
            for c in planes.indices { planes[c][i] = 0 }
            planes[channel][i] = 0.25 * sinf(Float(i) * 2 * .pi * Self.levelToneHz(channel) / 48_000)
        }
        var packets = try encoder.encode(planes: planes.map { UnsafePointer($0) }, frameCount: frames).map(\.data)
        packets += try encoder.flush().map(\.data)
        return try Self.decode(packets, cookie: encoder.magicCookie)
    }

    @Test("LFE and LFE2 both play from the LFE, summed, each at its own gain")
    func twoLFEs() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let tone = { (i: Int) in 0.25 * sinf(Float(i) * 2 * .pi * 50 / 48_000) }
        let one = try renderEach(roles: [.lfe], frames: 48_000, states: [nil]) { _, i in tone(i) }
        let both = try renderEach(roles: [.lfe, .lfe], frames: 48_000, states: [nil, nil]) { _, i in tone(i) }
        let halved = try renderEach(roles: [.lfe, .lfe], frames: 48_000,
                                    states: [nil, ObjectAudioElementState(gain: 0.5)]) { _, i in tone(i) }
        let lfe = { (o: [[Float]]) in Self.power(o[Out.lfe.rawValue], 8192, 40_000) }
        let db = { (a: Float, b: Float) in 10 * log10(a / b) }
        #expect(abs(db(lfe(both), lfe(one)) - 6.02) < 0.1, "\(db(lfe(both), lfe(one))) dB: the two add, in phase")
        #expect(abs(db(lfe(halved), lfe(one)) - 3.52) < 0.1, "\(db(lfe(halved), lfe(one))) dB: 1 + 0.5 of the tone")
    }

    @Test("on stereo the LFE is left out, as a 2.0 downmix has it, and the rest still plays")
    func stereoDropsLFE() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let tone = { (i: Int) in 0.25 * sinf(Float(i) * 2 * .pi * 50 / 48_000) }
        let lfeOnly = try renderEach(roles: [.lfe, .bed(.center)], frames: 48_000, states: [nil, nil],
                                     output: kAudioChannelLayoutTag_Stereo, renderedFor: .l20) { e, i in e == 0 ? tone(i) : 0 }
        let centre = try renderEach(roles: [.lfe, .bed(.center)], frames: 48_000, states: [nil, nil],
                                    output: kAudioChannelLayoutTag_Stereo, renderedFor: .l20) { e, i in e == 1 ? tone(i) : 0 }
        let total = { (o: [[Float]]) in o.reduce(Float(0)) { $0 + Self.power($1, 8192, 40_000) } }
        #expect(total(lfeOnly) < total(centre) * 1e-6, "the LFE is silent on stereo")
        #expect(APACObjectEncoder.dropsLFE(on: .l20) && !APACObjectEncoder.dropsLFE(on: .l51))
    }

    @Test("zone masks and divergence go to the speaker bus; an elevation switch alone does not")
    func busRouting() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let heights = Set(SpatialSpeaker.allCases.filter(\.isHeight))
        let encoder = try APACObjectEncoder(bitRate: 17 * 320_000)
        let buffer = APACEncodePipeline.PlaneBuffer(channels: APACObjectEncoder.elementCapacity, capacity: 1024)
        for plane in buffer.planes { plane.update(repeating: 0, count: 1024) }
        buffer.objectRoles = [.object, .object, .object]
        buffer.objectUpdates = [.init(frameOffset: 0, rampFrames: 0, states: [
            ObjectAudioElementState(excluded: heights, elevation: false),                                  // elevation off
            ObjectAudioElementState(excluded: heights.union([.sideLeft, .sideRight]), elevation: false),   // + no sides
            ObjectAudioElementState(divergence: 0.5),
        ])]
        _ = try encoder.encode(buffer, frames: 1024)
        #expect(encoder.busUpdates == 2)
    }

    @Test("an object moving onto the bus crossfades: no doubling, no gap")
    func busCrossfade() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        // On the left side as a plain object, then the same place with the back excluded: the bus
        // renders it there too, so the level holds through the 4096-frame crossfade.
        let free = ObjectAudioElementState(position: SIMD3(0, 0.5, 0))
        let zoned = ObjectAudioElementState(position: SIMD3(0, 0.5, 0), excluded: [.rearLeft, .rearRight])
        let out = try render(roles: [.object], signalOn: 0, frames: 48_000, updates: [
            .init(frameOffset: 0, rampFrames: 0, states: [free]),
            .init(frameOffset: 16_384, rampFrames: 4096, states: [zoned]),
        ])
        let level = { (s: Int) in (0..<12).reduce(Float(0)) { $0 + Self.power(out[$1], s, s + 1024) } }
        let before = level(8192)
        for s in stride(from: 12_288, to: 28_672, by: 1024) {
            let db = 10 * log10(level(s) / before)
            #expect(abs(db) < 0.5, "\(db) dB at frame \(s)")
        }
        #expect(Self.shares(out, from: 30_000, to: 48_000)[Out.ls.rawValue] > 0.97)
    }

    // MARK: - Motion

    @Test("a jump inside a packet lands on its frame")
    func jumpTiming() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let left = ObjectAudioElementState(position: SIMD3(0, 0, 0))
        let right = ObjectAudioElementState(position: SIMD3(1, 0, 0))
        let jumpAt = 10 * 1024 + 512
        let out = try render(roles: [.object], signalOn: 0, frames: 48_000, updates: [
            .init(frameOffset: 0, rampFrames: 0, states: [left]),
            .init(frameOffset: jumpAt, rampFrames: 0, states: [right]),
        ])
        // The first 64-frame window where R outweighs L. The converter keeps the encoder's priming,
        // so the decoded timeline may run 2048 frames late; anything else is a metadata misplacement.
        let window = 64
        let onset = stride(from: 4096, to: 40_000, by: window).first { s in
            Self.power(out[Out.r.rawValue], s, s + window) > Self.power(out[Out.l.rawValue], s, s + window)
        }
        let delay = try #require(onset) - jumpAt
        #expect([0, 2048].contains { abs(delay - $0) <= window }, "R takes over \(delay) frames after the jump")
    }

    @Test("a jump across the room ramps as Atmos does: out on the left, in on the right, never the centre")
    func rampCrossfades() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let left = ObjectAudioElementState(position: SIMD3(0, 0, 0))
        let right = ObjectAudioElementState(position: SIMD3(1, 0, 0))
        // L until frame 8192, then over 16384 frames to R. Atmos ramps the speaker gains, so halfway
        // (frame 16384) L and R each have half the amplitude: −3 dB, and nothing in the centre.
        let out = try render(roles: [.object], signalOn: 0, frames: 48_000, updates: [
            .init(frameOffset: 0, rampFrames: 0, states: [left]),
            .init(frameOffset: 8192, rampFrames: 16_384, states: [right]),
        ])
        let all = { (s: Int) in (0..<12).reduce(Float(0)) { $0 + Self.power(out[$1], s - 256, s + 256) } }
        let before = all(6144)
        // Either timeline (see `jumpTiming`): the middle is at 16384 or 2048 later.
        let middle = [16_384, 16_384 + 2048].map { s in
            (centre: Self.power(out[Out.c.rawValue], s - 256, s + 256) / max(all(s), 1e-20),
             db: 10 * log10(all(s) / before))
        }
        #expect(middle.allSatisfy { $0.centre < 0.02 }, "centre share at the ramp's middle: \(middle)")
        #expect(middle.contains { abs($0.db + 3) < 0.5 }, "level at the ramp's middle: \(middle)")
        #expect(Self.shares(out, from: 30_000, to: 48_000)[Out.r.rawValue] > 0.97)
    }

    /// The largest step in amplitude between neighbouring 256-frame windows over `range`, as a
    /// fraction of the loudest window's.
    static func largestStep(_ out: [[Float]], _ range: Range<Int>) -> Float {
        let amplitude = { (s: Int) in out.reduce(Float(0)) { $0 + Self.power($1, s, s + 256) }.squareRoot() }
        let windows = stride(from: range.lowerBound, to: range.upperBound, by: 256).map(amplitude)
        let full = windows.max()!
        return zip(windows, windows.dropFirst()).map { abs($1 - $0) / full }.max()!
    }

    @Test("a jump mid-fade hands over what is playing: no step in level", arguments: [false, true])
    func jumpMidRamp(twice: Bool) throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let left = ObjectAudioElementState(position: SIMD3(0, 0, 0))
        let right = ObjectAudioElementState(position: SIMD3(1, 0, 0))
        var silentLeft = left
        silentLeft.gain = 0
        // Fading in on the left over 16384 frames; halfway, a jump to the right. With `twice`, a jump
        // back to the left 1024 frames later, while the first one's fade-out is still running on the bus.
        var updates: [ObjectAudioMetadataUpdate] = [
            .init(frameOffset: 0, rampFrames: 0, states: [silentLeft]),
            .init(frameOffset: 8192, rampFrames: 16_384, states: [left]),
            .init(frameOffset: 16_384, rampFrames: 16_384, states: [right]),
        ]
        if twice { updates.append(.init(frameOffset: 17_408, rampFrames: 16_384, states: [left])) }
        let out = try render(roles: [.object], signalOn: 0, frames: 49_152, updates: updates, tone: true)
        // Either timeline (see `jumpTiming`). A ramp of 16384 frames moves the amplitude by under 0.02 of
        // full a window; handing over the fade's target instead of what plays would step it by 0.5.
        let step = Self.largestStep(out, 8192..<40_960)
        #expect(step < 0.05, "largest amplitude step around the jumps: \(step) of full")
    }

    @Test("on stereo a height bed channel folds as TS 103 448 table 6 has it, through the bus")
    func stereoHeightBed() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let out = try render(roles: [.bed(.topFrontLeft)], signalOn: 0, frames: 24_576, updates: [], tone: true,
                             output: kAudioChannelLayoutTag_Stereo, renderedFor: .l20)
        let shares = Self.shares(out, from: 8192, to: 24_576)
        // Tfl on 2.0: L alone, at 0.5.
        #expect(shares[0] > 0.98, "L share \(shares[0])")
    }

    @Test("only a ramp whose positions and gains part ways goes over the bus")
    func rampsDiffer() {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let at = { (x: Float, y: Float, gain: Float) in ObjectAudioElementState(position: SIMD3(x, y, 0), gain: gain) }
        #expect(APACObjectEncoder.rampsDiffer(from: at(0, 0, 1), to: at(1, 0, 1)))        // L to R
        #expect(APACObjectEncoder.rampsDiffer(from: at(0, 0, 1), to: at(1, 1, 1)))        // corner to corner
        #expect(!APACObjectEncoder.rampsDiffer(from: at(0.30, 0.6, 1), to: at(0.32, 0.6, 1)))  // a step
        #expect(!APACObjectEncoder.rampsDiffer(from: at(0, 0.5, 1), to: at(0, 0.5, 0.5)))  // gain only
        #expect(!APACObjectEncoder.rampsDiffer(from: at(0, 0, 0), to: at(1, 0, 1)))        // from silence
        #expect(!APACObjectEncoder.rampsDiffer(from: at(0, 0, 1), to: at(1, 0, 0)))        // to silence
    }

    /// Measurement, not a check: with APAC_LAYOUT_SWEEP=<file> set, one object visits a grid of
    /// positions, rendered by the system renderer to several output layouts; each position's
    /// per-channel power share is written to the file (layout, x, y, z, shares).
    @Test("sweep the system renderer over output layouts (APAC_LAYOUT_SWEEP)")
    func layoutSweep() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *),
              let path = ProcessInfo.processInfo.environment["APAC_LAYOUT_SWEEP"] else { return }
        let steps: [Float] = [0, 0.25, 0.5, 0.75, 1]
        var points: [SIMD3<Float>] = []
        for z in [Float(0), 0.5, 1] { for y in steps { for x in steps { points.append(SIMD3(x, y, z)) } } }
        let hold = 8192
        let updates = points.enumerated().map { i, p in
            ObjectAudioMetadataUpdate(frameOffset: i * hold, rampFrames: 0, states: [ObjectAudioElementState(position: p)])
        }
        let tags: [(String, AudioChannelLayoutTag)] = [
            ("2.0", kAudioChannelLayoutTag_Stereo), ("5.1", kAudioChannelLayoutTag_MPEG_5_1_A),
            ("7.1", kAudioChannelLayoutTag_MPEG_7_1_C), ("5.1.2", kAudioChannelLayoutTag_Atmos_5_1_2),
            ("7.1.2", kAudioChannelLayoutTag_Atmos_7_1_2), ("5.1.4", kAudioChannelLayoutTag_Atmos_5_1_4),
            ("7.1.4", kAudioChannelLayoutTag_Atmos_7_1_4),
        ]
        var lines: [String] = []
        for (name, tag) in tags {
            let out = try render(roles: [.object], signalOn: 0, frames: points.count * hold + 4096,
                                 updates: updates, output: tag)
            for (i, p) in points.enumerated() {
                // Skip the codec's 2048-frame priming either way: measure the hold's second half.
                let from = i * hold + hold / 2 + 1024, to = (i + 1) * hold
                let total = out.reduce(Float(0)) { $0 + Self.power($1, from, to) }
                let shares = out.map { Self.power($0, from, to) / max(total, 1e-20) }
                lines.append("\(name)\t\(p.x)\t\(p.y)\t\(p.z)\t\(10 * log10(max(total, 1e-20)))\t"
                             + shares.map { String(format: "%.4f", $0) }.joined(separator: ","))
            }
        }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Measurement, not a check: with APAC_TRACE=<oamd_trace.tsv> set, replay a stream's object
    /// metadata (60 s of it) through the encoder on silence and report how often a metadata packet did
    /// not fit and was written with fewer blocks.
    @Test("replay a metadata trace and count block-budget fallbacks (APAC_TRACE)")
    func traceBudget() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *),
              let path = ProcessInfo.processInfo.environment["APAC_TRACE"] else { return }
        var bySample: [Int: [(Int, SIMD3<Float>, Int)]] = [:]
        var first: Int?
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            let f = line.split(separator: "\t").map(String.init)
            guard f.count == 6, let at = Int(f[0]), let o = Int(f[1]), o < 16 else { continue }
            first = first ?? at
            let t = at - first!
            guard t < 60 * 48_000 else { break }
            bySample[t, default: []].append((o, SIMD3(Float(f[2])!, Float(f[3])!, Float(f[4])!), Int(f[5])!))
        }
        let encoder = try APACObjectEncoder(bitRate: 17 * 320_000)
        let chunk = 2048
        let buffer = APACEncodePipeline.PlaneBuffer(channels: APACObjectEncoder.elementCapacity, capacity: chunk)
        for plane in buffer.planes { plane.update(repeating: 0, count: chunk) }
        buffer.objectRoles = Array(repeating: .object, count: 16)
        let times = bySample.keys.sorted()
        var next = 0
        for start in stride(from: 0, to: 60 * 48_000, by: chunk) {
            var updates: [ObjectAudioMetadataUpdate] = []
            while next < times.count, times[next] < start + chunk {
                var states = [ObjectAudioElementState?](repeating: nil, count: 16)
                var ramp = 0
                for (o, p, r) in bySample[times[next]]! { states[o] = ObjectAudioElementState(position: p); ramp = r }
                updates.append(.init(frameOffset: times[next] - start, rampFrames: ramp, states: states))
                next += 1
            }
            buffer.objectUpdates = updates
            _ = try encoder.encode(buffer, frames: chunk)
        }
        print("APAC_TRACE \(path): \(encoder.metadataPackets) packets, \(encoder.budgetFallbacks) fallbacks, largest \(encoder.largestMetadataPacket) of \(APACObjectMetadata.packetCapacity) bytes, \(encoder.busRamps) jump crossfades")
    }

    // MARK: - Full-scene quality

    /// Measurement, not a check: AE_APAC_QUALITY=<file.thd> decodes the stream (exactly), renders it with `ObjectAudioRenderer` to 7.1.4 as the reference, and puts
    /// the same elements and metadata through the object encoder and the system renderer. The decoded
    /// 7.1.4 is compared with the reference, and so is the reference itself through the 7.1.4 bed
    /// encoder: the codec at its best on the same scene. AE_APAC_SECONDS (30), AE_APAC_RATE (bit/s);
    /// AE_APAC_OBJECT / AE_APAC_SCENE, JSON arrays of codec settings (`[]` for the codec's defaults);
    /// AE_APAC_STATIC=1 holds every element where its first metadata puts it, so the two renders
    /// cannot differ by motion and what is left is the codec.
    @Test("full-scene codec quality against the exact reference (AE_APAC_QUALITY)")
    func sceneQuality() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *),
              let path = ProcessInfo.processInfo.environment["AE_APAC_QUALITY"] else { return }
        let env = ProcessInfo.processInfo.environment
        let seconds = Int(env["AE_APAC_SECONDS"] ?? "") ?? 30
        let rate = Int(env["AE_APAC_RATE"] ?? "") ?? 17 * 320_000
        let limit = seconds * 48_000
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = try TrueHDObjectAudioDecoder(objectOutput: true)
        var roles: [ObjectAudioRole] = []
        var planes: [[Float]] = []
        var updates: [ObjectAudioMetadataUpdate] = []
        var frames = 0
        try data.withUnsafeBytes { raw in
            var offset = 0
            decoding: while offset < raw.count {
                let n = min(65_536, raw.count - offset)
                offset += n
                while let block = try decoder.nextBlock() {
                    if roles.isEmpty {
                        roles = block.roles
                        planes = roles.map { _ in [] }
                    }
                    guard block.roles == roles, frames < limit else { break decoding }
                    for e in roles.indices { planes[e] += UnsafeBufferPointer(start: block.planes[e], count: block.frameCount) }
                    for u in block.updates { var a = u; a.frameOffset += frames; updates.append(a) }
                    frames += block.frameCount
                }
            }
        }

        if env["AE_APAC_STATIC"] == "1" {
            var held = [ObjectAudioElementState?](repeating: nil, count: roles.count)
            for u in updates { for (e, state) in u.states.enumerated() where held[e] == nil { held[e] = state } }
            updates = [.init(frameOffset: 0, rampFrames: 0, states: held)]
        }
        let reference = Self.renderReference(planes: planes, roles: roles, updates: updates, frames: frames)

        // Objects through the object encoder. AE_APAC_OBJECT / AE_APAC_SCENE: JSON arrays of extra settings.
        func settings(_ name: String) -> [NSDictionary] {
            guard let json = env[name]?.data(using: .utf8) else { return [] }
            return (try? JSONSerialization.jsonObject(with: json)) as? [NSDictionary] ?? []
        }
        let encoder = try APACObjectEncoder(
            bitRate: rate, output: .l714,
            objectSettings: env["AE_APAC_OBJECT"] == nil ? APACObjectEncoder.defaultObjectSettings : settings("AE_APAC_OBJECT"),
            sceneSettings: settings("AE_APAC_SCENE"))
        let chunk = 2048
        let buffer = APACEncodePipeline.PlaneBuffer(channels: APACObjectEncoder.elementCapacity, capacity: chunk)
        buffer.objectRoles = roles
        var packets: [Data] = []
        var next = 0
        for start in stride(from: 0, to: frames, by: chunk) {
            let n = min(chunk, frames - start)
            for (e, plane) in buffer.planes.enumerated() {
                if e < roles.count {
                    planes[e].withUnsafeBufferPointer { plane.update(from: $0.baseAddress! + start, count: n) }
                } else {
                    plane.update(repeating: 0, count: n)
                }
            }
            var chunkUpdates: [ObjectAudioMetadataUpdate] = []
            while next < updates.count, updates[next].frameOffset < start + n {
                var u = updates[next]; u.frameOffset -= start; chunkUpdates.append(u); next += 1
            }
            buffer.objectUpdates = chunkUpdates
            packets += try encoder.encode(buffer, frames: n).map(\.data)
        }
        packets += try encoder.flush().map(\.data)
        let objects = try Self.decode(packets, cookie: encoder.magicCookie)
        let objectRate = Double(packets.reduce(0) { $0 + $1.count } * 8) / Double(frames) * 48_000
        // 47 packets make a second (1024 frames each): the busiest second's rate, for the playlist.
        let peak = stride(from: 0, to: max(packets.count - 47, 1), by: 1).map { i in
            packets[i..<min(i + 47, packets.count)].reduce(0) { $0 + $1.count } * 8
        }.max() ?? 0
        print("[sceneQuality] objects peak over one second: \(peak / 1000) kbps")

        // The reference through the bed encoder.
        let bed = try APACEncoder(layout: .l714, bitRate: 12 * 320_000)
        var bedPackets: [Data] = []
        for start in stride(from: 0, to: frames, by: 4096) {
            let n = min(4096, frames - start)
            let slice = reference.map { channel -> UnsafeMutablePointer<Float> in
                let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
                channel.withUnsafeBufferPointer { p.update(from: $0.baseAddress! + start, count: n) }
                return p
            }
            defer { slice.forEach { $0.deallocate() } }
            bedPackets += try bed.encode(planes: slice.map { UnsafePointer($0) }, frameCount: n).map(\.data)
        }
        bedPackets += try bed.flush().map(\.data)
        let bedDecoded = try Self.decode(bedPackets, cookie: bed.magicCookie)
        let bedRate = Double(bedPackets.reduce(0) { $0 + $1.count } * 8) / Double(frames) * 48_000

        for (name, decoded, kbps) in [("objects", objects, objectRate), ("bed    ", bedDecoded, bedRate)] {
            let q = Self.quality(decoded, against: reference, frames: frames)
            print(String(format: "[sceneQuality] %@ %6.0f kbps  SNR %5.1f dB  segmental median %5.1f p10 %5.1f  bands %@  per speaker %@  level %@",
                         name, kbps / 1000, q.snr, q.segmentalMedian, q.segmentalP10, q.bands, q.perSpeaker, q.levels))
        }
    }

    static func renderReference(planes: [[Float]], roles: [ObjectAudioRole], updates: [ObjectAudioMetadataUpdate],
                                frames: Int) -> [[Float]] {
        let renderer = ObjectAudioRenderer(layout: .l714, roles: roles)
        let out = (0..<12).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 4096) }
        defer { out.forEach { $0.deallocate() } }
        var reference = [[Float]](repeating: [], count: 12)
        var next = 0
        for start in stride(from: 0, to: frames, by: 4096) {
            let n = min(4096, frames - start)
            var chunk: [ObjectAudioMetadataUpdate] = []
            while next < updates.count, updates[next].frameOffset < start + n {
                var u = updates[next]; u.frameOffset = max(0, u.frameOffset - start); chunk.append(u); next += 1
            }
            let inputs = planes.map { plane in plane.withUnsafeBufferPointer { UnsafePointer($0.baseAddress! + start) } }
            renderer.render(inputs: inputs, frameCount: n, updates: chunk, outputs: out)
            for c in 0..<12 { reference[c] += UnsafeBufferPointer(start: out[c], count: n) }
        }
        return reference
    }

    /// `levels`: each speaker's energy against the reference's, in dB (L R C Ls Rs Lrs Rrs Vhl Vhr Ltr Rtr).
    struct Quality { var snr, segmentalMedian, segmentalP10: Double; var bands, perSpeaker, levels: String }

    /// `decoded` against `reference` (12 channels, LFE left out), after finding the codec's delay.
    static func quality(_ decoded: [[Float]], against reference: [[Float]], frames: Int) -> Quality {
        let speakers = (0..<12).filter { $0 != Out.lfe.rawValue }
        // The decoded timeline starts 0 or 2048 frames late (see `jumpTiming`); find it to the frame.
        let probe = (frames / 2)..<min(frames / 2 + 16_000, frames - 4096)
        let lag = (Array(0...64) + Array(1984...2112)).max { a, b in
            func corr(_ l: Int) -> Double {
                speakers.reduce(0) { sum, c in
                    sum + probe.reduce(0) { $0 + Double(reference[c][$1]) * Double(decoded[c][$1 + l]) }
                }
            }
            return corr(a) < corr(b)
        }!
        let count = min(frames, decoded[0].count - lag)
        func error(_ c: Int, _ i: Int) -> Double { Double(decoded[c][i + lag]) - Double(reference[c][i]) }
        var signal = 0.0, noise = 0.0
        var perSpeaker: [String] = [], levels: [String] = []
        for c in speakers {
            var s = 0.0, n = 0.0, d = 0.0
            for i in 0..<count {
                s += Double(reference[c][i] * reference[c][i]); let e = error(c, i); n += e * e
                d += Double(decoded[c][i + lag] * decoded[c][i + lag])
            }
            signal += s; noise += n
            perSpeaker.append(String(format: "%.0f", 10 * log10(s / max(n, 1e-30))))
            levels.append(String(format: "%+.2f", 10 * log10(max(d, 1e-30) / max(s, 1e-30))))
        }
        var segments: [Double] = []
        for w in stride(from: 0, to: count - 1024, by: 1024) {
            var s = 0.0, n = 0.0
            for c in speakers { for i in w..<w + 1024 { s += Double(reference[c][i] * reference[c][i]); let e = error(c, i); n += e * e } }
            if s / 1024 > 1e-6 { segments.append(10 * log10(s / max(n, 1e-30))) }
        }
        segments.sort()
        // Band SNRs from 2048-point spectra, Hann-windowed, summed over speakers and windows.
        let edges: [Double] = [0, 2000, 6000, 12_000, 16_000, 20_000, 24_000]
        var bandSignal = [Double](repeating: 0, count: edges.count - 1), bandNoise = bandSignal
        let fft = vDSP.FFT(log2n: 11, radix: .radix2, ofType: DSPSplitComplex.self)!
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 2048, isHalfWindow: false)
        func spectrum(_ x: [Float]) -> [Float] {
            var real = [Float](repeating: 0, count: 1024), imag = real
            let windowed = vDSP.multiply(x, window)
            real.withUnsafeMutableBufferPointer { r in imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, 1024) }
                fft.forward(input: split, output: &split)
            } }
            return (0..<1024).map { real[$0] * real[$0] + imag[$0] * imag[$0] }
        }
        for w in stride(from: 0, to: count - 2048, by: 8192) {
            for c in speakers {
                let r = Array(reference[c][w..<w + 2048])
                let e = (0..<2048).map { Float(error(c, w + $0)) }
                let (rs, es) = (spectrum(r), spectrum(e))
                for k in 1..<1024 {
                    let hz = Double(k) * 24_000 / 1024
                    let b = edges.lastIndex { $0 <= hz }!
                    if b < bandSignal.count { bandSignal[b] += Double(rs[k]); bandNoise[b] += Double(es[k]) }
                }
            }
        }
        let bands = (0..<bandSignal.count).map {
            String(format: "%.0f-%.0fk %.1f", edges[$0] / 1000, edges[$0 + 1] / 1000, 10 * log10(bandSignal[$0] / max(bandNoise[$0], 1e-30)))
        }.joined(separator: ", ")
        return Quality(snr: 10 * log10(signal / max(noise, 1e-30)),
                       segmentalMedian: segments.isEmpty ? 0 : segments[segments.count / 2],
                       segmentalP10: segments.isEmpty ? 0 : segments[segments.count / 10],
                       bands: "[" + bands + "]", perSpeaker: "[" + perSpeaker.joined(separator: " ") + "]",
                       levels: "[" + levels.joined(separator: " ") + "]")
    }

    // MARK: - Outputs

    static let outputs: [(SpatialSpeakerLayout, AudioChannelLayoutTag)] = [
        (.l20, kAudioChannelLayoutTag_Stereo), (.l51, kAudioChannelLayoutTag_MPEG_5_1_A),
        (.l71, kAudioChannelLayoutTag_MPEG_7_1_C), (.l714, kAudioChannelLayoutTag_Atmos_7_1_4),
    ]
    static let testPoints: [SIMD3<Float>] = [
        SIMD3(0.25, 0, 0), SIMD3(0, 0.5, 0), SIMD3(0.75, 0.75, 0), SIMD3(0.25, 0.25, 1),
        SIMD3(0.5, 0.5, 0.5), SIMD3(1, 1, 1),
    ]

    /// Each point's speaker gains on `layout` as the renderer has them, default trims included: one
    /// frame of unit input through the renderer.
    static func reference(_ p: SIMD3<Float>, on layout: SpatialSpeakerLayout) -> [Float] {
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.object])
        var one: Float = 1
        let outputs = (0..<layout.channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 1) }
        defer { outputs.forEach { $0.deallocate() } }
        withUnsafePointer(to: &one) { input in
            renderer.render(inputs: [input], frameCount: 1, updates: [.init(frameOffset: 0, rampFrames: 0, states: [
                ObjectAudioElementState(position: p, trim: .defaults)])], outputs: outputs)
        }
        return outputs.map { $0.pointee }
    }

    @Test("on every output tvOS renders to, an object plays as TS 103 448 renders it there, trims included",
          arguments: outputs.map(\.0))
    func outputRendersTheSpec(_ layout: SpatialSpeakerLayout) throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let tag = Self.outputs.first { $0.0 == layout }!.1
        let hold = 8192
        let updates = Self.testPoints.enumerated().map { i, p in
            ObjectAudioMetadataUpdate(frameOffset: i * hold, rampFrames: 0,
                                      states: [ObjectAudioElementState(position: p, trim: .defaults)])
        }
        let out = try render(roles: [.object], signalOn: 0, frames: Self.testPoints.count * hold + 4096,
                             updates: updates, tone: true, output: tag, renderedFor: layout)
        let toneTone: Float = 0.25 * 0.25 / 2
        for (i, p) in Self.testPoints.enumerated() {
            // Either timeline (see `jumpTiming`): the hold's second half is inside it.
            let from = i * hold + hold / 2 + 1024, to = (i + 1) * hold
            let expected = Array(Self.reference(p, on: layout).prefix(out.count))
            let power = out.map { Self.power($0, from, to) / Float(to - from) }
            let total = power.reduce(0, +), expectedTotal = expected.reduce(0) { $0 + $1 * $1 } * toneTone
            #expect(abs(10 * log10(total / expectedTotal)) < 0.5, "\(layout.rawValue) \(p): level \(10 * log10(total / expectedTotal)) dB")
            for c in out.indices {
                let share = power[c] / total, want = expected[c] * expected[c] * toneTone / expectedTotal
                #expect(abs(share - want) < 0.015, "\(layout.rawValue) \(p) channel \(c): \(share) against \(want)")
            }
        }
    }

    @Test("a route change renders what follows for the new output")
    func outputFollowsTheRoute() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        // On the ceiling, rendered for 7.1.4 and then for 5.1, decoded to 5.1 throughout: before the
        // change the system renderer folds the height in its own way, after it the level is the spec's.
        let p = SIMD3<Float>(0.25, 0.25, 1)
        let out = try render(roles: [.object], signalOn: 0, frames: 65_536, updates: [
            .init(frameOffset: 0, rampFrames: 0, states: [ObjectAudioElementState(position: p, trim: .defaults)]),
        ], tone: true, output: kAudioChannelLayoutTag_MPEG_5_1_A, renderedFor: .l714, switchTo: (32_768, .l51))
        let expected = Self.reference(p, on: .l51).reduce(0) { $0 + $1 * $1 } * 0.25 * 0.25 / 2
        let level = { (from: Int, to: Int) in
            10 * log10(out.reduce(Float(0)) { $0 + Self.power($1, from, to) } / Float(to - from) / expected)
        }
        #expect(abs(level(45_056, 65_536)) < 0.5, "after the change: \(level(45_056, 65_536)) dB")
        #expect(abs(level(8192, 28_672)) > 1, "before it, still rendered for 7.1.4: \(level(8192, 28_672)) dB")
    }

    // MARK: - Trajectory

    @Test("an object fading to silence stays where it was, and one fading in starts where it is going")
    func trajectoryFadesInPlace() {
        var t = APACObjectTrajectory(.init(position: SIMD3(0, 0, 0), size: 0, gain: 1))
        t.apply(.init(position: SIMD3(0, 0, 0), size: 0.2, gain: 1), at: 0, rampFrames: 0)
        // Switched off: Atmos's default position is the room's centre, which it must not glide to.
        t.apply(.init(position: SIMD3(0.5, 0.5, 0), size: 0, gain: 0), at: 100, rampFrames: 200)
        // The gain ramps as Atmos's do: 201 steps, the first on the update's frame (101 by frame 200).
        #expect(t.value(at: 200) == .init(position: SIMD3(0, 0, 0), size: 0.2, gain: 1 - Float(101) / 201))
        t.apply(.init(position: SIMD3(1, 1, 0), size: 0, gain: 1), at: 1000, rampFrames: 200)
        #expect(t.value(at: 1100) == .init(position: SIMD3(1, 1, 0), size: 0, gain: Float(101) / 201))
    }

    @Test("a slot's gain steps with the speaker bus's: a fade out there and in here always sum to the whole")
    func gainRampMatchesTheBus() {
        let renderer = ObjectAudioRenderer(layout: .l714, roles: [.object])
        let left = ObjectAudioElementState(position: SIMD3(0, 0, 0))
        var silent = left
        silent.gain = 0
        let frames = 320
        let ones = [Float](repeating: 1, count: frames)
        let outputs = (0..<12).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        defer { outputs.forEach { $0.deallocate() } }
        ones.withUnsafeBufferPointer { input in
            renderer.render(inputs: [input.baseAddress!], frameCount: frames, updates: [
                .init(frameOffset: 0, rampFrames: 0, states: [left]),
                .init(frameOffset: 10, rampFrames: 300, states: [silent]),
            ], outputs: outputs)
        }
        var t = APACObjectTrajectory(.init(position: SIMD3(1, 0, 0), size: 0, gain: 0))
        t.apply(.init(position: SIMD3(1, 0, 0), size: 0, gain: 0), at: 10, rampFrames: 0)
        t.apply(.init(position: SIMD3(1, 0, 0), size: 0, gain: 1), at: 10, rampFrames: 300)
        for frame in 10..<frames {
            #expect(abs(outputs[0][frame] + t.value(at: Int64(frame)).gain - 1) < 1e-5, "frame \(frame)")
        }
    }

    @Test("a fade restated mid-ramp steps on from the frame before it, as the speaker bus does (pseudocode 19)")
    func restartedRampMatchesTheBus() {
        let renderer = ObjectAudioRenderer(layout: .l714, roles: [.object])
        let left = ObjectAudioElementState(position: SIMD3(0, 0, 0))
        var silent = left
        silent.gain = 0
        let frames = 400
        let ones = [Float](repeating: 1, count: frames)
        let outputs = (0..<12).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        defer { outputs.forEach { $0.deallocate() } }
        ones.withUnsafeBufferPointer { input in
            renderer.render(inputs: [input.baseAddress!], frameCount: frames, updates: [
                .init(frameOffset: 0, rampFrames: 0, states: [left]),
                .init(frameOffset: 10, rampFrames: 200, states: [silent]),
                .init(frameOffset: 110, rampFrames: 200, states: [silent]),
            ], outputs: outputs)
        }
        // Updated as the encoder updates it, each when its frame comes.
        var t = APACObjectTrajectory(.init(position: SIMD3(0, 0, 0), size: 0, gain: 1))
        let updates: [Int: (gain: Float, ramp: Int)] = [0: (1, 0), 10: (0, 200), 110: (0, 200)]
        for frame in 0..<frames {
            if let u = updates[frame] {
                t.apply(.init(position: SIMD3(0, 0, 0), size: 0, gain: u.gain), at: Int64(frame), rampFrames: u.ramp)
            }
            #expect(abs(outputs[0][frame] - t.value(at: Int64(frame)).gain) < 1e-5, "frame \(frame)")
        }
    }

    @Test("a size that differs along its axes goes to the bus: the renderer takes the largest for all three")
    func anisotropicSizeNeedsBus() {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        #expect(APACObjectEncoder.needsBus(ObjectAudioElementState(size: SIMD3(0.4, 0.1, 0)), on: .l714))
        #expect(APACObjectEncoder.needsBus(ObjectAudioElementState(size: SIMD3(0, 0, 0.2)), on: .l51))
        #expect(!APACObjectEncoder.needsBus(ObjectAudioElementState(size: SIMD3(repeating: 0.4)), on: .l714))
        #expect(!APACObjectEncoder.needsBus(ObjectAudioElementState(), on: .l714))
    }

    @Test("a sized object without elevation goes to the bus where there are heights to keep off")
    func sizedElevationOffNeedsBus() {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let heights = Set(SpatialSpeaker.allCases.filter(\.isHeight))
        let sized = ObjectAudioElementState(size: SIMD3(repeating: 0.3), excluded: heights, elevation: false)
        #expect(APACObjectEncoder.needsBus(sized, on: .l714))
        #expect(!APACObjectEncoder.needsBus(sized, on: .l51))
        #expect(!APACObjectEncoder.needsBus(ObjectAudioElementState(excluded: heights, elevation: false), on: .l714))
    }

    @Test("a packet too busy for the metadata channel still goes out, its busiest objects simplified")
    func budgetOverflow() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        // Every object jumping between the side walls every 64 frames: 16 boundaries each per packet.
        let encoder = try APACObjectEncoder(bitRate: 17 * 320_000)
        let buffer = APACEncodePipeline.PlaneBuffer(channels: APACObjectEncoder.elementCapacity, capacity: 2048)
        for plane in buffer.planes { plane.update(repeating: 0, count: 2048) }
        buffer.objectRoles = Array(repeating: .object, count: 16)
        buffer.objectUpdates = stride(from: 0, to: 2048, by: 64).map { t in
            .init(frameOffset: t, rampFrames: 0, states: (0..<16).map { _ in
                ObjectAudioElementState(position: SIMD3(t % 128 == 0 ? 0 : 1, 0.5, 0)) })
        }
        _ = try encoder.encode(buffer, frames: 2048)
        #expect(encoder.metadataPackets == 2)
        #expect(encoder.budgetFallbacks > 0)
        #expect(encoder.largestMetadataPacket <= APACObjectMetadata.packetCapacity)
    }

    @Test("restating where an object already is adds no block")
    func trajectoryRestatement() {
        var t = APACObjectTrajectory(.init(position: SIMD3(0, 0, 0), size: 0, gain: 1))
        t.apply(.init(position: SIMD3(0.5, 0, 0), size: 0, gain: 1), at: 0, rampFrames: 0)
        t.finishPacket()
        t.apply(.init(position: SIMD3(0.5, 0, 0), size: 0, gain: 1), at: 1536, rampFrames: 1536)
        #expect(t.blocks(packetStart: 1024, maxBlocks: 8, map: Self.map).count == 1)
    }

    @Test("a still object is one block over the packet")
    func trajectoryStill() {
        var t = APACObjectTrajectory(.init(position: SIMD3(0, 0, 0), size: 0, gain: 1))
        t.apply(.init(position: SIMD3(1, 0, 0), size: 0, gain: 1), at: 0, rampFrames: 0)
        var blocks = t.blocks(packetStart: 0, maxBlocks: 8, map: Self.map)
        #expect(blocks == [.init(start: 0, interpolation: 0, position: .init(x: 1, y: 1, z: 0), size: 0)],
                "the first packet opens with a jump")
        t.finishPacket()
        blocks = t.blocks(packetStart: 1024, maxBlocks: 8, map: Self.map)
        #expect(blocks == [.init(start: 0, interpolation: 1024, position: .init(x: 1, y: 1, z: 0), size: 0)])
    }

    @Test("a jump inside a packet becomes a block at its frame")
    func trajectoryJump() {
        var t = APACObjectTrajectory(.init(position: SIMD3(0, 0, 0), size: 0, gain: 1))
        t.apply(.init(position: SIMD3(0, 0, 0), size: 0, gain: 1), at: 0, rampFrames: 0)
        t.finishPacket()
        t.apply(.init(position: SIMD3(1, 0, 0), size: 0, gain: 1), at: 1024 + 300, rampFrames: 0)
        let blocks = t.blocks(packetStart: 1024, maxBlocks: 8, map: Self.map)
        #expect(blocks == [
            .init(start: 0, interpolation: 300, position: .init(x: -1, y: 1, z: 0), size: 0),
            .init(start: 300, interpolation: 0, position: .init(x: 1, y: 1, z: 0), size: 0),
        ])
    }

    @Test("a ramp across packets ends each packet where it has got to")
    func trajectoryRamp() {
        var t = APACObjectTrajectory(.init(position: SIMD3(0, 0, 0), size: 0, gain: 1))
        t.apply(.init(position: SIMD3(0, 0, 0), size: 0, gain: 1), at: 0, rampFrames: 0)
        t.finishPacket()
        // From 1024 + 512 to 1024 + 512 + 2048: half of it in this packet's remainder and the next.
        t.apply(.init(position: SIMD3(1, 0, 0), size: 0, gain: 1), at: 1536, rampFrames: 2048)
        let first = t.blocks(packetStart: 1024, maxBlocks: 8, map: Self.map)
        #expect(first.count == 2)
        #expect(first[1].start == 512 && first[1].interpolation == 512)
        #expect(abs(first[1].position.x - (-0.5)) < 1e-5, "a quarter of the way at the packet's end")
        t.finishPacket()
        let second = t.blocks(packetStart: 2048, maxBlocks: 8, map: Self.map)
        #expect(second.count == 1)
        #expect(abs(second[0].position.x - 0.5) < 1e-5, "three quarters at the next packet's end")
        t.finishPacket()
        let third = t.blocks(packetStart: 3072, maxBlocks: 8, map: Self.map)
        #expect(third.count == 2, "the ramp ends at 3584, inside the third packet")
        #expect(third[0].start == 0 && third[0].interpolation == 512 && third[0].position.x == 1)
    }

    // MARK: - Helpers

    static func map(_ v: APACObjectTrajectory.Values) -> (APACObjectMetadata.Point, Float) {
        (APACObjectMetadata.point(v.position), v.size)
    }

    /// Encode `frames` frames of noise (or a 1 kHz tone) on element `signalOn` (the others silent) through the object
    /// encoder, in 2048-frame chunks the way the bridge hands them over, and decode to 7.1.4.
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func render(roles: [ObjectAudioRole], signalOn: Int, frames: Int,
                        updates: [ObjectAudioMetadataUpdate], tone: Bool = false,
                        output: AudioChannelLayoutTag = kAudioChannelLayoutTag_Atmos_7_1_4,
                        renderedFor: SpatialSpeakerLayout = .l714,
                        switchTo: (frame: Int, output: SpatialSpeakerLayout)? = nil) throws -> [[Float]] {
        let encoder = try APACObjectEncoder(bitRate: 17 * 320_000, output: renderedFor)
        let chunk = 2048
        let buffer = APACEncodePipeline.PlaneBuffer(channels: APACObjectEncoder.elementCapacity, capacity: chunk)
        buffer.objectRoles = roles
        var seed: UInt64 = 1
        var packets: [Data] = []
        var start = 0
        while start < frames {
            let n = min(chunk, frames - start)
            if let switchTo, switchTo.frame == start { encoder.requestOutput(switchTo.output) }
            for (e, plane) in buffer.planes.enumerated() {
                for i in 0..<n {
                    if e == signalOn {
                        seed = seed &* 6364136223846793005 &+ 1442695040888963407
                        plane[i] = tone ? 0.25 * sinf(Float(start + i) * 2 * .pi * Self.levelToneHz(roles[e] == .lfe ? Out.lfe.rawValue : 0) / 48_000)
                            : 0.25 * (Float(seed >> 40) / Float(1 << 24) * 2 - 1)
                    } else {
                        plane[i] = 0
                    }
                }
            }
            buffer.objectUpdates = updates.compactMap { u in
                guard u.frameOffset >= start, u.frameOffset < start + n else { return nil }
                var shifted = u
                shifted.frameOffset -= start
                return shifted
            }
            packets += try encoder.encode(buffer, frames: n).map(\.data)
            start += n
        }
        packets += try encoder.flush().map(\.data)
        return try Self.decode(packets, cookie: encoder.magicCookie, output: output)
    }

    /// Like `render`, but every element plays `signal(element, frame)`, and `states` go out at frame 0.
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func renderEach(roles: [ObjectAudioRole], frames: Int, states: [ObjectAudioElementState?],
                            output: AudioChannelLayoutTag = kAudioChannelLayoutTag_Atmos_7_1_4,
                            renderedFor: SpatialSpeakerLayout = .l714,
                            signal: (Int, Int) -> Float) throws -> [[Float]] {
        let encoder = try APACObjectEncoder(bitRate: 17 * 320_000, output: renderedFor)
        let chunk = 2048
        let buffer = APACEncodePipeline.PlaneBuffer(channels: APACObjectEncoder.elementCapacity, capacity: chunk)
        buffer.objectRoles = roles
        var packets: [Data] = []
        var start = 0
        while start < frames {
            let n = min(chunk, frames - start)
            for (e, plane) in buffer.planes.enumerated() {
                for i in 0..<n { plane[i] = e < roles.count ? signal(e, start + i) : 0 }
            }
            buffer.objectUpdates = start == 0 ? [.init(frameOffset: 0, rampFrames: 0, states: states)] : []
            packets += try encoder.encode(buffer, frames: n).map(\.data)
            start += n
        }
        packets += try encoder.flush().map(\.data)
        return try Self.decode(packets, cookie: encoder.magicCookie, output: output)
    }

    /// Decode APAC packets through an AudioConverter asked for `output` (7.1.4 unless said), which
    /// renders objects with the system renderer. One array per output channel.
    static func decode(_ packets: [Data], cookie: Data,
                       output outputTag: AudioChannelLayoutTag = kAudioChannelLayoutTag_Atmos_7_1_4) throws -> [[Float]] {
        let channels = Int(AudioChannelLayoutTag_GetNumberOfChannels(outputTag))
        var input = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatAPAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 0, mBitsPerChannel: 0, mReserved: 0)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let cookieBytes = [UInt8](cookie)
        _ = cookieBytes.withUnsafeBytes {
            AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, UInt32(cookie.count), $0.baseAddress, &size, &input)
        }
        var output = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        var converter: AudioConverterRef?
        try #require(AudioConverterNew(&input, &output, &converter) == 0)
        let conv = converter!
        defer { AudioConverterDispose(conv) }
        _ = cookieBytes.withUnsafeBytes {
            AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), $0.baseAddress!)
        }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = outputTag
        try #require(AudioConverterSetProperty(conv, kAudioConverterOutputChannelLayout,
                                               UInt32(MemoryLayout<AudioChannelLayout>.size), &layout) == 0)

        final class Feed {
            var packets: [Data]; var next = 0; var bytes: [UInt8] = []; var description = AudioStreamPacketDescription()
            init(_ p: [Data]) { packets = p }
        }
        let feed = Feed(packets)
        let proc: AudioConverterComplexInputDataProc = { _, count, data, descriptions, user in
            let f = Unmanaged<Feed>.fromOpaque(user!).takeUnretainedValue()
            guard f.next < f.packets.count else { count.pointee = 0; return 0 }
            f.bytes = [UInt8](f.packets[f.next]); f.next += 1
            f.description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                         mDataByteSize: UInt32(f.bytes.count))
            data.pointee.mNumberBuffers = 1
            data.pointee.mBuffers.mData = f.bytes.withUnsafeMutableBytes { $0.baseAddress }
            data.pointee.mBuffers.mDataByteSize = UInt32(f.bytes.count)
            data.pointee.mBuffers.mNumberChannels = 0
            count.pointee = 1
            if let descriptions { descriptions.pointee = withUnsafeMutablePointer(to: &f.description) { $0 } }
            return 0
        }
        var out = [[Float]](repeating: [], count: channels)
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        defer { list.unsafeMutablePointer.deallocate() }
        let planes = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 1024) }
        defer { planes.forEach { $0.deallocate() } }
        while true {
            for c in 0..<channels { list[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 4096, mData: planes[c]) }
            var frames: UInt32 = 1024
            let status = AudioConverterFillComplexBuffer(conv, proc, Unmanaged.passUnretained(feed).toOpaque(),
                                                         &frames, list.unsafeMutablePointer, nil)
            if status != 0 || frames == 0 { break }
            for c in 0..<channels { out[c] += UnsafeBufferPointer(start: planes[c], count: Int(frames)) }
        }
        return out
    }

    /// 1 kHz, or 50 Hz for the LFE, whose channel the codec band-limits.
    static func levelToneHz(_ channel: Int) -> Float { channel == Out.lfe.rawValue ? 50 : 1000 }

    static func power(_ x: [Float], _ from: Int, _ to: Int) -> Float {
        guard from < to, from >= 0, to <= x.count else { return 0 }
        return x[from..<to].reduce(0) { $0 + $1 * $1 }
    }

    static func shares(_ out: [[Float]], from: Int, to: Int) -> [Float] {
        let p = out.map { power($0, from, to) }
        let total = max(p.reduce(0, +), 1e-20)
        return p.map { $0 / total }
    }

    static func describe(_ shares: [Float]) -> String {
        let names = ["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs", "Vhl", "Vhr", "Ltr", "Rtr"]
        return zip(names, shares).filter { $0.1 > 0.005 }.map { String(format: "%@ %.1f%%", $0.0, $0.1 * 100) }
            .joined(separator: " ")
    }
}
#endif
