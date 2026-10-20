// Only with the APACObjectOutput trait (personal builds, off by default).
#if APACObjectOutput
import AudioToolbox
import simd
import Foundation

/// APAC with positioned objects: every TrueHD Atmos element except the LFE becomes an APAC object,
/// placed by metadata the encoder reads from a trailing PCM channel, and the LFE rides a channel bed.
/// tvOS renders the result itself, for whatever the output is (a 7.1.4 MAT bed over HDMI, binaural
/// on headphones).
///
/// None of this is public API. The encoder is driven through the AudioCodec API (an `AVAudioConverter`
/// cannot pass the scene description), with private properties and an undocumented metadata format,
/// all recovered from macOS 27's AudioCodecs and verified end to end on the Mac (research notes,
/// `apac-objects/README.md` §3, §3.20):
/// - `'cdrc'` = 0 (dynamic range control off, as `APACEncoder` has it) and `'mtdc'` = 1 (one
///   metadata channel after the audio), before initialising;
/// - the scene goes in `kAudioCodecPropertySettings` as a dictionary: a 7.1.4 channel bed, then
///   one Object component per object. Several objects in one component render only the first at its
///   position (the rest sit in the room's centre), and one component allows at most 7 objects;
/// - renderer type 3 (Atmos) on every object, so positions are allocentric room-cube coordinates,
///   which the system renderer pans exactly like `AllocentricPanner`;
/// - the bed carries the LFE alone. Other bed channels are re-panned by the renderer once objects are
///   present (a left bed channel comes out half left, half centre), while an object on a speaker's
///   position renders entirely to that speaker, so bed channels travel as fixed objects.
///
/// The scene is fixed when the encoder is built (`objectSlots` objects, used or silent, then the
/// speaker bus), because the magic cookie and with it the sample entry are needed before the first
/// block is decoded. Gains, trims included, are applied to the audio, not sent: the renderer rounds a
/// sent gain to 0.5 dB. Snap and the elevation switch are positions by the time an update gets here.
/// Zone masks and divergence have nothing that reaches the renderer with type 3 (README §3.20), so
/// an object carrying either is rendered here instead, by `ObjectAudioRenderer` as TS 103 448 has it,
/// onto the speaker bus: eleven fixed objects on the 7.1.4 speakers, each of which plays from its
/// speaker alone. An object moving between its slot and the bus crossfades over the update's ramp,
/// which is exactly the gain ramp Atmos specifies for it.
///
/// Atmos ramps speaker gains from the old pan to the new; the renderer ramps the position. For the
/// small steps of a moving object the two agree, but an object that jumps across the room would sweep
/// through speakers it is never meant to reach. For such an update the old pan fades out on the bus
/// while the slot jumps to the new position and fades in: the spec's ramp exactly, since the renderer
/// pans the slot as the bus does.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
final class APACObjectEncoder: APACChunkEncoding {

    enum EncoderError: Error, CustomStringConvertible {
        case codecUnavailable
        case property(String, OSStatus)
        case encode(String, OSStatus)

        var description: String {
            switch self {
            case .codecUnavailable: return "APACObjectEncoder: no APAC encoder component"
            case .property(let p, let s): return "APACObjectEncoder: setting \(p) failed (\(s))"
            case .encode(let what, let s): return "APACObjectEncoder: \(what) failed (\(s))"
            }
        }
    }

    /// TrueHD's object presentation holds at most 16 elements, one of them usually the LFE.
    static let objectSlots = 16
    /// The speaker bus: the layout tvOS renders object APAC to for an HDMI Atmos route, one fixed
    /// object per speaker after the slots.
    static let busLayout = SpatialSpeakerLayout.l714
    static let busSpeakers = busLayout.speakers.filter { !$0.isLFE }
    static let sceneObjects = objectSlots + busSpeakers.count
    /// The bed: the only one of its channels with signal is the LFE.
    static let bedLayout = SpatialSpeakerLayout.l714
    /// Planes the caller hands over per chunk: one per element of the decoded presentation.
    static let elementCapacity = objectSlots + 1

    let leadingFrames: Int
    let magicCookie: Data
    /// HLS `CODECS`, from the cookie: object APAC is profile 5 (low), not the channel profile 31.
    let hlsCodecs: String

    private let codec: AudioComponentInstance
    private let bedChannels = APACObjectEncoder.bedLayout.channelCount
    private let lfeChannel = APACObjectEncoder.bedLayout.lfeIndex
    private let inputChannels: Int
    private var metadataChannel: Int { inputChannels - 1 }

    /// One packet of interleaved input being assembled, and how many of its frames are filled.
    private var staging: [Float]
    private var staged = 0
    /// Frames staged since the encoder was built: the clock the trajectories run on. Never reset, so
    /// a restart needs no rebasing.
    private var clock: Int64 = 0

    /// Per slot; `lfe` is the bed's LFE gain (its position is never used).
    private var slots: [APACObjectTrajectory]
    private var lfe: APACObjectTrajectory
    /// What each element of the current presentation feeds: a slot, the LFE (-1) or nothing (nil).
    private var roles: [ObjectAudioRole] = []
    private var route: [Int?] = []
    /// Slots an element feeds, and the bus's; the others get no metadata at all.
    private var used = APACObjectEncoder.busSlotsOnly
    /// The objects this encoder renders itself, into one plane per `busLayout` channel.
    private var bus: ObjectAudioRenderer
    private let busPlanes: [UnsafeMutablePointer<Float>]
    private var busInputs: [UnsafePointer<Float>] = []
    /// Each element's last object state, the pan a ramp starts from; nil after a gap or restart.
    private var lastStates: [ObjectAudioElementState?] = []
    /// Updates that sent an object to the bus, and ramps it crossfaded there, for the session log.
    private(set) var busUpdates = 0
    private(set) var busRamps = 0
    private var busUpdatesReported = 0
    private var busRampsReported = 0
    private var outputBuffer: [UInt8]
    private var ended = false

    init(bitRate: Int, sampleRate: Double = Double(ObjectAudioRendering.sampleRate)) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioEncoderComponentType, componentSubType: kAudioFormatAPAC,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw EncoderError.codecUnavailable }
        var instance: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &instance) == 0, let codec = instance else {
            throw EncoderError.codecUnavailable
        }
        self.codec = codec
        inputChannels = Self.bedLayout.channelCount + Self.sceneObjects + 1
        staging = [Float](repeating: 0, count: 1024 * inputChannels)
        slots = (0..<Self.sceneObjects).map { _ in APACObjectTrajectory(Self.silent) }
        for (k, speaker) in Self.busSpeakers.enumerated() {
            slots[Self.objectSlots + k] = APACObjectTrajectory(.init(position: speaker.position, size: 0, gain: 1))
        }
        lfe = APACObjectTrajectory(Self.silent)
        bus = ObjectAudioRenderer(layout: Self.busLayout, roles: [])
        busPlanes = (0..<Self.busLayout.channelCount).map { _ in
            let plane = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
            plane.initialize(repeating: 0, count: 1024)
            return plane
        }
        outputBuffer = [UInt8](repeating: 0, count: 1 << 18)

        func set<T: BitwiseCopyable>(_ name: String, _ id: AudioCodecPropertyID, _ value: T) throws {
            var v = value
            let status = AudioCodecSetProperty(codec, id, UInt32(MemoryLayout<T>.size), &v)
            guard status == 0 else { throw EncoderError.property(name, status) }
        }
        do {
            try set("cdrc", Self.fourCC("cdrc"), UInt32(0))
            try set("mtdc", Self.fourCC("mtdc"), UInt32(1))
            let input = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(4 * inputChannels), mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(4 * inputChannels), mChannelsPerFrame: UInt32(inputChannels),
                mBitsPerChannel: 32, mReserved: 0)
            let output = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatAPAC, mFormatFlags: 0, mBytesPerPacket: 0,
                mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(inputChannels),
                mBitsPerChannel: 0, mReserved: 0)
            try set("input format", kAudioCodecPropertyCurrentInputFormat, input)
            try set("output format", kAudioCodecPropertyCurrentOutputFormat, output)
            // The input layout only labels the channels; the scene itself is the settings dictionary
            // below. (The encoder refuses an output layout for this input, 'nope'.)
            var layout = Self.inputChannelLayout(bed: Self.bedLayout, objects: Self.sceneObjects)
            let layoutStatus = layout.withUnsafeMutableBytes {
                AudioCodecSetProperty(codec, kAudioCodecPropertyCurrentInputChannelLayout, UInt32($0.count), $0.baseAddress!)
            }
            guard layoutStatus == 0 else { throw EncoderError.property("input layout", layoutStatus) }
            // The target rate only binds in constant bit rate mode. In the default (long-term average)
            // the encoder keeps its own rate whatever the target says, about 60 kbps per object, and
            // the decoded objects lose the top of the band (0.5 dB of white noise against the bed
            // encoder at 320 kbps a channel).
            try set("bit rate control mode", kAudioCodecPropertyBitRateControlMode,
                    UInt32(kAudioCodecBitRateControlMode_Constant))
            try set("bit rate", kAudioCodecPropertyCurrentTargetBitRate, UInt32(bitRate))
            var settings: Unmanaged<CFDictionary> = Unmanaged.passRetained(try Self.settings(codec: codec) as CFDictionary)
            defer { settings.release() }
            let status = AudioCodecSetProperty(
                codec, Self.fourCC("acs "), UInt32(MemoryLayout<UnsafeRawPointer>.size), &settings)
            guard status == 0 else { throw EncoderError.property("scene settings", status) }
            let initStatus = AudioCodecInitialize(codec, nil, nil, nil, 0)
            guard initStatus == 0 else { throw EncoderError.property("initialize", initStatus) }

            var size: UInt32 = 0
            AudioCodecGetPropertyInfo(codec, kAudioCodecPropertyMagicCookie, &size, nil)
            var cookie = [UInt8](repeating: 0, count: Int(size))
            let cookieStatus = AudioCodecGetProperty(codec, kAudioCodecPropertyMagicCookie, &size, &cookie)
            guard cookieStatus == 0, size > 0 else { throw EncoderError.property("magic cookie", cookieStatus) }
            magicCookie = Data(cookie.prefix(Int(size)))
            var prime = AudioCodecPrimeInfo()
            var primeSize = UInt32(MemoryLayout<AudioCodecPrimeInfo>.size)
            leadingFrames = AudioCodecGetProperty(codec, kAudioCodecPropertyPrimeInfo, &primeSize, &prime) == 0
                ? Int(prime.leadingFrames) : 2048
            hlsCodecs = APACSampleEntry.codecsString(magicCookie: magicCookie) ?? "apac.05.00"
        } catch {
            AudioComponentInstanceDispose(codec)
            busPlanes.forEach { $0.deallocate() }
            throw error
        }
    }

    deinit {
        AudioComponentInstanceDispose(codec)
        busPlanes.forEach { $0.deallocate() }
    }

    private static let silent = APACObjectTrajectory.Values(position: SIMD3(0.5, 0.5, 0), size: 0, gain: 0)
    private static let busSlotsOnly = (0..<sceneObjects).map { $0 >= objectSlots }

    // MARK: - APACChunkEncoding

    func encode(_ buffer: APACEncodePipeline.PlaneBuffer, frames: Int) throws -> [APACEncoder.Packet] {
        guard !ended else { throw APACEncoder.EncoderError.encodeAfterFlush }
        if buffer.objectRoles != roles { configure(buffer.objectRoles) }
        var packets: [APACEncoder.Packet] = []
        var events = buffer.objectUpdates.map { (offset: $0.frameOffset, update: Optional($0)) }
            + buffer.objectDiscontinuities.map { (offset: $0, update: Optional<ObjectAudioMetadataUpdate>.none) }
        // Discontinuities first at a shared offset: the update there describes the far side of the gap.
        events.sort { $0.offset != $1.offset ? $0.offset < $1.offset : ($0.update == nil && $1.update != nil) }
        var next = events.startIndex
        var cursor = 0
        while cursor < frames || (next < events.endIndex && events[next].offset <= cursor) {
            while next < events.endIndex, events[next].offset <= cursor {
                if let update = events[next].update { apply(update) } else { markDiscontinuity() }
                next += 1
            }
            guard cursor < frames else { break }
            let eventLimit = next < events.endIndex ? events[next].offset : frames
            let n = min(frames, eventLimit, cursor + (1024 - staged)) - cursor
            stage(buffer.planes, from: cursor, count: n)
            cursor += n
            if staged == 1024 { try finishPacket(into: &packets) }
        }
        // Stamped at or past the chunk's end: they take effect from here, as in `ObjectAudioRenderer`.
        for event in events[next...] {
            if let update = event.update { apply(update) } else { markDiscontinuity() }
        }
        return packets
    }

    func flush() throws -> [APACEncoder.Packet] {
        guard !ended else { return [] }
        ended = true
        // Also reached when the pipeline restarts the encoder mid-stream, so it reports what was
        // dropped since the last report, not a running total.
        if busUpdates > busUpdatesReported || busRamps > busRampsReported {
            EngineLog.emit("[APACObjectEncoder] \(busUpdates - busUpdatesReported) object updates rendered onto the "
                           + "speaker bus (zone mask or divergence), \(busRamps - busRampsReported) jumps crossfaded "
                           + "there", category: .session)
            busUpdatesReported = busUpdates
            busRampsReported = busRamps
        }
        var packets: [APACEncoder.Packet] = []
        // The partial packet, then silence until the encoder's look-ahead has come out.
        var padding = (staged > 0 ? 1024 - staged : 0) + leadingFrames
        while padding > 0 {
            let n = min(padding, 1024 - staged)
            for i in 0..<n { clearFrame(staged + i) }
            staged += n
            clock += Int64(n)
            padding -= n
            if staged == 1024 { try finishPacket(into: &packets) }
        }
        return packets
    }

    func reset() {
        AudioCodecReset(codec)
        staged = 0
        ended = false
        for i in slots.indices { slots[i].restart(at: clock) }
        lfe.restart(at: clock)
        lastStates = lastStates.map { _ in nil }
    }

    // MARK: - Scene

    /// Map a presentation's elements onto the fixed scene. Called when the elements change (a stream
    /// with a different object configuration): every slot starts over, beds sounding at once and
    /// objects silent until their first metadata, as `ObjectAudioRenderer` treats them.
    private func configure(_ newRoles: [ObjectAudioRole]) {
        roles = newRoles
        route = []
        lastStates = newRoles.map { _ in nil }
        used = Self.busSlotsOnly
        bus = ObjectAudioRenderer(layout: Self.busLayout, roles: newRoles.map { _ in .object })
        var nextSlot = 0
        for role in newRoles {
            switch role {
            case .lfe:
                route.append(-1)
            case .bed, .fixed, .object:
                if nextSlot < Self.objectSlots {
                    route.append(nextSlot)
                    used[nextSlot] = true
                    nextSlot += 1
                } else {
                    route.append(nil)
                }
            }
        }
        if nextSlot < newRoles.count - newRoles.filter({ $0 == .lfe }).count {
            EngineLog.emit("[APACObjectEncoder] \(newRoles.count) elements, only \(Self.objectSlots) object slots; "
                           + "the rest are dropped", category: .session)
        }
        for i in 0..<Self.objectSlots {
            slots[i] = APACObjectTrajectory(Self.silent)
            slots[i].restart(at: clock)
        }
        lfe = APACObjectTrajectory(Self.silent)
        for (element, role) in newRoles.enumerated() {
            guard let target = route[element] else { continue }
            let initial: APACObjectTrajectory.Values
            switch role {
            case .bed(let speaker): initial = .init(position: speaker.position, size: 0, gain: 1)
            case .fixed(let position): initial = .init(position: position, size: 0, gain: 1)
            case .lfe: initial = .init(position: SIMD3(0.5, 0, 0), size: 0, gain: 1)
            case .object: initial = Self.silent
            }
            if target < 0 {
                lfe = APACObjectTrajectory(initial)
                lfe.restart(at: clock)
            } else {
                slots[target] = APACObjectTrajectory(initial)
                slots[target].restart(at: clock)
            }
        }
    }

    private func apply(_ update: ObjectAudioMetadataUpdate) {
        var busStates = [ObjectAudioElementState?](repeating: nil, count: roles.count)
        var busFrom = busStates
        for (element, state) in update.states.enumerated() {
            guard let state, element < route.count, let target = route[element] else { continue }
            let values: APACObjectTrajectory.Values
            switch roles[element] {
            case .object:
                // Every object update reaches the bus too, silent unless the object is on it, so the
                // bus always has a state to ramp from when one moves over.
                let onBus = Self.needsBus(state)
                var busState = state
                let previous = lastStates[element]
                lastStates[element] = state
                if onBus {
                    busUpdates += 1
                } else if let previous, update.rampFrames > 0, !Self.needsBus(previous),
                          Self.rampsDiffer(from: previous, to: state) {
                    // The old pan takes over on the bus and fades there; the slot comes in where it goes.
                    busRamps += 1
                    busFrom[element] = previous
                    busState = previous
                    busState.gain = 0
                    slots[target].apply(.init(position: slots[target].value(at: clock).position, size: 0, gain: 0),
                                        at: clock, rampFrames: 0)
                } else {
                    busState.gain = 0
                }
                busStates[element] = busState
                let trim = state.trim?.gain(at: state.position, on: Self.busLayout) ?? 1
                values = .init(position: Self.objectPosition(state), size: state.size,
                               gain: onBus ? 0 : state.gain * trim)
            case .bed(let speaker): values = .init(position: speaker.position, size: 0, gain: state.gain)
            case .fixed(let position): values = .init(position: position, size: 0, gain: state.gain)
            case .lfe: values = .init(position: SIMD3(0.5, 0, 0), size: 0, gain: state.gain)
            }
            if target < 0 {
                lfe.apply(values, at: clock, rampFrames: update.rampFrames)
            } else {
                slots[target].apply(values, at: clock, rampFrames: update.rampFrames)
            }
        }
        if busFrom.contains(where: { $0 != nil }) {
            bus.advance(frameCount: 0, updates: [.init(frameOffset: 0, rampFrames: 0, states: busFrom)])
        }
        if busStates.contains(where: { $0 != nil }) {
            bus.advance(frameCount: 0, updates: [.init(frameOffset: 0, rampFrames: update.rampFrames, states: busStates)])
        }
    }

    private func markDiscontinuity() {
        lastStates = lastStates.map { _ in nil }
        for i in slots.indices { slots[i].markDiscontinuity() }
        lfe.markDiscontinuity()
        bus.markDiscontinuity()
    }

    private static let busFloor = Set(busSpeakers.filter { !$0.isHeight })

    /// Whether an object needs what the renderer will not do with type 3: a zone mask that takes
    /// away a 7.1.4 ear-level speaker, or divergence. Taking the heights away is already a position
    /// (the elevation switch put it at ear level).
    static func needsBus(_ state: ObjectAudioElementState) -> Bool {
        state.divergence > 0 || !state.excluded.isDisjoint(with: busFloor)
    }

    private static let busPanner = AllocentricPanner(layout: busLayout)

    /// Whether ramping an object's position from `previous` to `state` would sound different from
    /// Atmos's ramp of its speaker gains: halfway through, some speaker's gain differs by more than
    /// `rampTolerance`. Only a ramp between two sounding positions can; one to or from silence holds
    /// its position (`APACObjectTrajectory`).
    static func rampsDiffer(from previous: ObjectAudioElementState, to state: ObjectAudioElementState) -> Bool {
        guard previous.gain > 0, state.gain > 0 else { return false }
        let a = objectPosition(previous), b = objectPosition(state)
        guard a != b else { return false }
        var from: [Float] = [], to: [Float] = [], mid: [Float] = []
        busPanner.pointGains(a, into: &from)
        busPanner.pointGains(b, into: &to)
        busPanner.pointGains((a + b) / 2, into: &mid)
        return mid.indices.contains { abs((from[$0] + to[$0]) / 2 - mid[$0]) > rampTolerance }
    }

    /// 2% of full scale: the small steps of a moving object stay well under it, a jump between
    /// speakers is far over it.
    static let rampTolerance: Float = 0.02

    /// The position the renderer gets: inside its room, and at ear level for an object kept off the
    /// heights (TS 103 448 5.1.3.2), which is how type 3 hears an elevation switch.
    static func objectPosition(_ state: ObjectAudioElementState) -> SIMD3<Float> {
        var p = simd_clamp(state.position, SIMD3(repeating: 0), SIMD3(repeating: 1))
        if heights.isSubset(of: state.excluded) { p.z = 0 }
        return p
    }

    private static let heights = Set(SpatialSpeaker.allCases.filter(\.isHeight))

    /// Undoes the renderer's distance attenuation. It treats a point's distance from the centre of
    /// its −1…1 cube as a distance and attenuates 1/r beyond 1 (measured, README §3.20): a floor
    /// corner plays 3.0 dB low, a front top 1.8 dB, the ceiling's corners 4.8 dB. Atmos has no such
    /// thing for room positions, and neither has the engine's own render.
    static func distanceCompensation(_ position: SIMD3<Float>) -> Float {
        let p = APACObjectMetadata.point(position)
        return max(1, (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot())
    }

    /// The renderer plays an object stream's bed LFE 10 dB above the same channel in a channel bed
    /// (measured 9.96 dB against `APACEncoder`, a 50 Hz tone): the LFE's in-band gain, applied once
    /// more. The channel bed is the level the rest of the engine delivers, so the LFE goes in 10 dB down.
    static let lfeCompensation = Float(pow(10, -10.0 / 20))

    // MARK: - Staging

    private func clearFrame(_ frame: Int) {
        let base = frame * inputChannels
        for c in 0..<inputChannels { staging[base + c] = 0 }
    }

    /// `count` frames of `planes` from `start` into the staging packet, each element at its gain.
    private func stage(_ planes: [UnsafeMutablePointer<Float>], from start: Int, count: Int) {
        guard count > 0 else { return }
        for i in 0..<count { clearFrame(staged + i) }
        for (element, target) in route.enumerated() {
            guard let target, element < planes.count else { continue }
            let plane = planes[element] + start
            let channel = target < 0 ? lfeChannel : bedChannels + target
            for i in 0..<count {
                let t = clock + Int64(i)
                let g: Float
                if target < 0 {
                    g = lfe.value(at: t).gain * Self.lfeCompensation
                } else {
                    let v = slots[target].value(at: t)
                    g = v.gain * Self.distanceCompensation(v.position)
                }
                staging[(staged + i) * inputChannels + channel] = plane[i] * g
            }
        }
        if roles.count <= planes.count {
            busInputs.removeAll(keepingCapacity: true)
            for element in roles.indices { busInputs.append(UnsafePointer(planes[element] + start)) }
            bus.render(inputs: busInputs, frameCount: count, updates: [], outputs: busPlanes)
            for (k, speaker) in Self.busSpeakers.enumerated() {
                let plane = busPlanes[Self.busLayout.speakers.firstIndex(of: speaker)!]
                let channel = bedChannels + Self.objectSlots + k
                let g = Self.distanceCompensation(speaker.position)
                for i in 0..<count { staging[(staged + i) * inputChannels + channel] = plane[i] * g }
            }
        }
        staged += count
        clock += Int64(count)
    }

    /// The staging packet is full: write its metadata into the last channel, hand it to the codec,
    /// and collect what it produces.
    private func finishPacket(into packets: inout [APACEncoder.Packet]) throws {
        let packetStart = clock - 1024
        let map: (APACObjectTrajectory.Values) -> (APACObjectMetadata.Point, Float) = {
            (APACObjectMetadata.point($0.position), $0.size)
        }
        var packet: [UInt8]?
        for budget in [APACObjectMetadata.maxBlocks, 4, 2, 1] {
            let objects = slots.indices.map {
                used[$0] ? slots[$0].blocks(packetStart: packetStart, maxBlocks: budget, map: map) : []
            }
            if let p = APACObjectMetadata.packet(objects: objects) { packet = p; break }
        }
        for i in slots.indices { slots[i].finishPacket() }
        lfe.finishPacket()
        if let packet {
            let channel = metadataChannel, stride = inputChannels
            APACObjectMetadata.samples(of: packet) { frame, value in staging[frame * stride + channel] = value }
        }
        staged = 0
        // The codec takes what fits in its input buffer; the rest goes in after it has produced.
        let total = staging.count * 4
        var offset = 0
        var stalled = 0
        while offset < total {
            var bytes = UInt32(total - offset)
            var packetsIn: UInt32 = 0
            let status = staging.withUnsafeBytes {
                AudioCodecAppendInputData(codec, $0.baseAddress! + offset, &bytes, &packetsIn, nil)
            }
            guard status == 0 else { throw EncoderError.encode("append", status) }
            offset += Int(bytes)
            try produce(into: &packets)
            stalled = bytes == 0 ? stalled + 1 : 0
            if stalled > 1 { throw EncoderError.encode("append (no progress)", -1) }
        }
    }

    private func produce(into packets: inout [APACEncoder.Packet]) throws {
        while true {
            var size = UInt32(outputBuffer.count)
            var count: UInt32 = 1
            var description = AudioStreamPacketDescription()
            var status: UInt32 = 0
            let result = outputBuffer.withUnsafeMutableBytes {
                AudioCodecProduceOutputPackets(codec, $0.baseAddress!, &size, &count, &description, &status)
            }
            guard result == 0 else { throw EncoderError.encode("produce", result) }
            if count > 0, size > 0 {
                // With the converter's defaults every APAC packet is an Audio Sync Packet
                // (`APACEncoder`); this path sets nothing that changes that.
                packets.append(.init(data: Data(outputBuffer.prefix(Int(size))), isSync: true))
            }
            if status == kAudioCodecProduceOutputPacketNeedsMoreInputData || count == 0 { return }
        }
    }

    // MARK: - Configuration

    /// Bed channel labels, one Object label per slot, and an unused label for the metadata channel.
    private static func inputChannelLayout(bed: SpatialSpeakerLayout, objects: Int) -> Data {
        let labels = bed.speakers.map(\.channelLabel)
            + (0..<objects).map { kAudioChannelLabel_Object | AudioChannelLabel($0) }
            + [kAudioChannelLabel_Unused]
        let size = MemoryLayout<AudioChannelLayout>.size
            + (labels.count - 1) * MemoryLayout<AudioChannelDescription>.size
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            let acl = raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self)
            acl.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            acl.pointee.mNumberChannelDescriptions = UInt32(labels.count)
            let offset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions)!
            let descriptions = (raw.baseAddress! + offset).assumingMemoryBound(to: AudioChannelDescription.self)
            for (i, label) in labels.enumerated() { descriptions[i].mChannelLabel = label }
        }
        return data
    }

    /// The `kAudioCodecPropertySettings` dictionary (README §3.2): the bed's layout as an index into
    /// the codec's available output layouts (zero-channel tags removed), each object its own Object
    /// component with renderer type 3, and the static metadata blob.
    private static func settings(codec: AudioComponentInstance) throws -> NSDictionary {
        var size: UInt32 = 0
        AudioCodecGetPropertyInfo(codec, fourCC("aocl"), &size, nil)
        var tags = [AudioChannelLayoutTag](repeating: 0, count: Int(size) / 4)
        AudioCodecGetProperty(codec, fourCC("aocl"), &size, &tags)
        guard let bedIndex = tags.filter({ $0 & 0xFFFF != 0 }).firstIndex(of: bedLayout.channelLayoutTag) else {
            throw EncoderError.property("bed layout (not among the codec's layouts)", -50)
        }
        func channelMap(_ first: Int, _ last: Int) -> NSDictionary {
            ["key": "Channel Map", "current minimum range": first, "current maximum range": last]
        }
        let bedCount = bedLayout.channelCount
        var components: [NSDictionary] = [[
            "key": "Channel Bed",
            "Channel Bed": [["key": "ChannelLayoutTag", "current value": bedIndex], channelMap(0, bedCount - 1)],
        ]]
        for i in 0..<sceneObjects {
            components.append([
                "key": "Object",
                "Object": [
                    ["key": "Object Count", "current value": 1],
                    channelMap(bedCount + i, bedCount + i),
                    ["key": "Renderer Type", "RendererType": [["key": "Renderer Type Index", "current value": 3]]],
                ],
            ])
        }
        let blob = APACObjectMetadata.staticBlob(objects: sceneObjects)
        return [
            "version": 0,
            "sub version": 0,
            "parameters": [
                ["key": "Audio Scene Components", "ASComponents": components],
                ["key": "StaticMetadata", "StaticMetadata": blob.map { NSNumber(value: Int8(bitPattern: $0)) }],
            ],
        ]
    }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}
#endif
