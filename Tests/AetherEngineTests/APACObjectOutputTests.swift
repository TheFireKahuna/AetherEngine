// Only with the APACObjectOutput trait (personal builds).
#if APACObjectOutput
import AudioToolbox
import Foundation
import Testing
@testable import AetherEngine

/// Object APAC is checked the way the research measured it: encode, then decode through an
/// `AudioConverter` asked for 7.1.4, which inserts the system's spatial renderer, and read where each
/// element's energy lands. Serialized: with several of these encodes and renders running at once in one
/// process, an element without metadata of its own now and then renders at the room's centre instead of its
/// position (1 run in 3 alongside the bridge suites, never alone); a session runs one encoder.
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
        Case(name: "snapping object near L goes to L", element: 2,
             state: ObjectAudioElementState(position: SIMD3(0.2, 0.1, 0), snap: true), expect: [.l]),
        Case(name: "snapping object up front left goes to the front left top", element: 2,
             state: ObjectAudioElementState(position: SIMD3(0.15, 0.2, 0.8), snap: true), expect: [.vhl]),
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

    @Test("an object without elevation stays at ear level")
    func elevationOff() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let heights = Set(SpatialSpeaker.allCases.filter(\.isHeight))
        let state = ObjectAudioElementState(position: SIMD3(0.25, 0.25, 1), excluded: heights)
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

    @Test("a ramp glides through the centre")
    func rampGlides() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let left = ObjectAudioElementState(position: SIMD3(0, 0, 0))
        let right = ObjectAudioElementState(position: SIMD3(1, 0, 0))
        // L until frame 8192, then over 16384 frames to R: halfway (frame 16384) it is at the centre.
        let out = try render(roles: [.object], signalOn: 0, frames: 48_000, updates: [
            .init(frameOffset: 0, rampFrames: 0, states: [left]),
            .init(frameOffset: 8192, rampFrames: 16_384, states: [right]),
        ])
        // Either timeline (see `jumpTiming`): the centre peaks at 16384 or 2048 later.
        let centre = [16_384, 16_384 + 2048].map { s -> Float in
            let all = (0..<12).reduce(Float(0)) { $0 + Self.power(out[$1], s - 256, s + 256) }
            return Self.power(out[Out.c.rawValue], s - 256, s + 256) / max(all, 1e-20)
        }
        #expect(centre.max()! > 0.9, "centre share at the ramp's middle: \(centre)")
        let early = Self.shares(out, from: 4096, to: 8192)
        #expect(early[Out.l.rawValue] > 0.97)
    }

    // MARK: - Trajectory

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
                        updates: [ObjectAudioMetadataUpdate], tone: Bool = false) throws -> [[Float]] {
        let encoder = try APACObjectEncoder(bitRate: 17 * 320_000)
        let chunk = 2048
        let buffer = APACEncodePipeline.PlaneBuffer(channels: APACObjectEncoder.elementCapacity, capacity: chunk)
        buffer.objectRoles = roles
        var seed: UInt64 = 1
        var packets: [Data] = []
        var start = 0
        while start < frames {
            let n = min(chunk, frames - start)
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
        return try Self.decode(packets, cookie: encoder.magicCookie)
    }

    /// Decode APAC packets through an AudioConverter asked for 7.1.4, which renders objects with the
    /// system renderer. One array per output channel.
    static func decode(_ packets: [Data], cookie: Data) throws -> [[Float]] {
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
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 12,
            mBitsPerChannel: 32, mReserved: 0)
        var converter: AudioConverterRef?
        try #require(AudioConverterNew(&input, &output, &converter) == 0)
        let conv = converter!
        defer { AudioConverterDispose(conv) }
        _ = cookieBytes.withUnsafeBytes {
            AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), $0.baseAddress!)
        }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Atmos_7_1_4
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
        var out = [[Float]](repeating: [], count: 12)
        let list = AudioBufferList.allocate(maximumBuffers: 12)
        defer { list.unsafeMutablePointer.deallocate() }
        let planes = (0..<12).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 1024) }
        defer { planes.forEach { $0.deallocate() } }
        while true {
            for c in 0..<12 { list[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 4096, mData: planes[c]) }
            var frames: UInt32 = 1024
            let status = AudioConverterFillComplexBuffer(conv, proc, Unmanaged.passUnretained(feed).toOpaque(),
                                                         &frames, list.unsafeMutablePointer, nil)
            if status != 0 || frames == 0 { break }
            for c in 0..<12 { out[c] += UnsafeBufferPointer(start: planes[c], count: Int(frames)) }
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
