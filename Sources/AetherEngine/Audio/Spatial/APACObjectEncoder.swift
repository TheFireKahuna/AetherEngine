// Only with the APACObjectOutput trait (personal builds, off by default).
#if APACObjectOutput
import AudioToolbox
import simd
import Foundation
#if os(iOS) || os(tvOS)
import AVFoundation
#endif

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
/// sent gain to 0.5 dB. Snap is a position by the time an update gets here, and the elevation switch
/// becomes one here (an object kept off the heights is sent at ear level).
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
///
/// tvOS renders the scene to 7.1.4 for an HDMI Atmos route and for headphones, and to the route's own
/// layout otherwise: 7.1, 5.1 or stereo (`currentOutput()`). On 5.1, 7.1 and the Atmos layouts its
/// panner is TS 103 448's to the position (measured: 0.0 points on all 75 test points), so the
/// bus sits on that output's speakers and trims are that layout's. Without height speakers it lowers
/// an object by its height (2 dB at the ceiling on 5.1), where TS 103 448 pans and trims without
/// regard to it, so objects go to it at ear level. Its stereo pan law is not TS 103 448's (an object a
/// quarter of the way across plays 99% left, not 85%), so on stereo every object is rendered onto the
/// bus. The output is followed as the route changes, from the next audio encoded.
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
    /// The speaker bus: one fixed object per speaker of the output tvOS renders to, after the slots,
    /// with room for 7.1.4's eleven, the largest output it renders object APAC to.
    static let busCapacity = SpatialSpeakerLayout.l714.channelCount - 1
    static let sceneObjects = objectSlots + busCapacity
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
    /// What tvOS renders the scene to, and the bus's speakers on it.
    private(set) var output: SpatialSpeakerLayout
    private var busSpeakers: [SpatialSpeaker]
    /// A route change waiting for the next `encode`, which runs on the encode queue.
    private let outputLock = NSLock()
    private var pendingOutput: SpatialSpeakerLayout?
    private var routeObservers: [NSObjectProtocol] = []
    /// The objects this encoder renders itself, into one plane per `output` channel.
    private var bus: ObjectAudioRenderer
    private let busPlanes: [UnsafeMutablePointer<Float>]
    private var busInputs: [UnsafePointer<Float>] = []
    /// Each element's last state; nil after a gap or restart.
    private var lastStates: [ObjectAudioElementState?] = []
    /// Whether the bed has the back pair, which sets how TS 103 448 table 6 folds its channels.
    private var bedHasBacks = false
    /// Where each object's current slot ramp started (its state, unprojected) and over which frames,
    /// to know where it is when a jump hands it to the bus mid-ramp. nil when the slot is not moving.
    private var rampFrom: [ObjectAudioElementState?] = []
    private var rampStart: [Int64] = []
    private var rampLength: [Int] = []
    /// Two bus voices per element (voice v of element e is bus element v * roles.count + e), so a
    /// fade-out can finish on one while the next starts on the other. `busVoice` is the one in use;
    /// a voice is busy until its fade-out ends.
    private var busVoice: [Int] = []
    private var voiceSounding: [Bool] = []
    private var voiceFadeEnds: [Int64] = []
    /// Updates that sent an object to the bus, and ramps it crossfaded there, for the session log.
    private(set) var busUpdates = 0
    private(set) var busRamps = 0
    /// Metadata packets written, and how many times one did not fit and was retried with fewer blocks.
    private(set) var metadataPackets = 0
    private(set) var budgetFallbacks = 0
    private(set) var largestMetadataPacket = 0
    private var busUpdatesReported = 0
    private var busRampsReported = 0
    private var outputBuffer: [UInt8]
    private var ended = false
    /// Whether the codec is initialized for coding: not until the first encode (`APACCodecGate`).
    private var started = false
    /// Frames still to code under `APACCodecGate` since the codec started or was reset.
    private var gatedFramesLeft = APACObjectEncoder.gatedFrames
    static let gatedFrames = 4096

    /// `output` is what the scene is rendered to, `currentOutput()` unless given; `followRoute()`
    /// keeps it up to date. `objectSettings` go into every Object component and `sceneSettings`
    /// among the top-level parameters (measuring the codec's options).
    init(bitRate: Int, sampleRate: Double = Double(ObjectAudioRendering.sampleRate),
         output: SpatialSpeakerLayout = APACObjectEncoder.currentOutput(),
         objectSettings: [NSDictionary] = APACObjectEncoder.defaultObjectSettings,
         sceneSettings: [NSDictionary] = []) throws {
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
        self.output = output
        busSpeakers = output.speakers.filter { !$0.isLFE }
        slots = (0..<Self.sceneObjects).map { _ in APACObjectTrajectory(Self.silent) }
        for (k, speaker) in busSpeakers.enumerated() {
            slots[Self.objectSlots + k] = APACObjectTrajectory(.init(position: speaker.position, size: 0, gain: 1))
        }
        lfe = APACObjectTrajectory(Self.silent)
        bus = ObjectAudioRenderer(layout: output, roles: [])
        busPlanes = (0..<SpatialSpeakerLayout.l714.channelCount).map { _ in
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
            var settings: Unmanaged<CFDictionary> = Unmanaged.passRetained(
                try Self.settings(codec: codec, objectSettings: objectSettings, sceneSettings: sceneSettings) as CFDictionary)
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
            // Initialized again by the first encode, under `APACCodecGate`.
            AudioCodecUninitialize(codec)
        } catch {
            AudioComponentInstanceDispose(codec)
            busPlanes.forEach { $0.deallocate() }
            throw error
        }
    }

    deinit {
        routeObservers.forEach(NotificationCenter.default.removeObserver)
        AudioComponentInstanceDispose(codec)
        busPlanes.forEach { $0.deallocate() }
    }

    private static let silent = APACObjectTrajectory.Values(position: SIMD3(0.5, 0.5, 0), size: 0, gain: 0)
    private static let busSlotsOnly = (0..<sceneObjects).map { $0 >= objectSlots }

    // MARK: - APACChunkEncoding

    func encode(_ buffer: APACEncodePipeline.PlaneBuffer, frames: Int) throws -> [APACEncoder.Packet] {
        guard !ended else { throw APACEncoder.EncoderError.encodeAfterFlush }
        let gated = gatedFramesLeft > 0
        if gated {
            APACCodecGate.lock.lock()
            gatedFramesLeft -= frames
        }
        defer { if gated { APACCodecGate.lock.unlock() } }
        try start()
        if buffer.objectRoles != roles { configure(buffer.objectRoles) }
        outputLock.lock()
        let requested = pendingOutput
        pendingOutput = nil
        outputLock.unlock()
        if let requested, requested != output { switchOutput(to: requested) }
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

    /// Initialize the codec for coding, the first time only. Not in `init`: a bed encoder that was
    /// already running when this codec was initialized, ending its stream before this one codes its
    /// first frames, leaves the whole stream without metadata (`APACCodecGate`).
    private func start() throws {
        guard !started else { return }
        let status = AudioCodecInitialize(codec, nil, nil, nil, 0)
        guard status == 0 else { throw EncoderError.property("initialize", status) }
        started = true
    }

    func flush() throws -> [APACEncoder.Packet] {
        guard !ended else { return [] }
        ended = true
        try APACCodecGate.lock.withLock { try start() }
        // Also reached when the pipeline restarts the encoder mid-stream, so it reports what was
        // dropped since the last report, not a running total.
        if busUpdates > busUpdatesReported || busRamps > busRampsReported {
            EngineLog.emit("[APACObjectEncoder] \(busUpdates - busUpdatesReported) object updates rendered onto the "
                           + "speaker bus (zone mask or divergence), \(busRamps - busRampsReported) jumps crossfaded "
                           + "there", category: .session)
            busUpdatesReported = busUpdates
            busRampsReported = busRamps
        }
        if metadataPackets > 0 {
            EngineLog.emit("[APACObjectEncoder] metadata: \(metadataPackets) packets, largest \(largestMetadataPacket) of "
                           + "\(APACObjectMetadata.packetCapacity) bytes, \(budgetFallbacks) object budgets halved to fit",
                           category: .session)
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
        // Initialized again by the next encode, as at the start (`start()`): a reset codec is as open
        // to a bed stream's end as a new one.
        if started { AudioCodecUninitialize(codec) }
        started = false
        staged = 0
        ended = false
        gatedFramesLeft = Self.gatedFrames
        for i in slots.indices { slots[i].restart(at: clock) }
        lfe.restart(at: clock)
        lastStates = lastStates.map { _ in nil }
        rampFrom = rampFrom.map { _ in nil }
    }

    // MARK: - Scene

    /// Map a presentation's elements onto the fixed scene. Called when the elements change (a stream
    /// with a different object configuration): every slot starts over, beds sounding at once and
    /// objects silent until their first metadata, as `ObjectAudioRenderer` treats them.
    private func configure(_ newRoles: [ObjectAudioRole]) {
        roles = newRoles
        route = []
        lastStates = newRoles.map { _ in nil }
        bedHasBacks = ObjectAudioRenderer.bedHasBacks(newRoles)
        resetMotion()
        used = Self.busSlotsOnly
        bus = Self.busRenderer(output, roles: newRoles)
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
            case .fixed(let position): initial = .init(position: Self.position(position, on: output), size: 0, gain: 1)
            case .lfe: initial = .init(position: SIMD3(0.5, 0, 0), size: 0, gain: 1)
            case .bed, .object: initial = Self.silent
            }
            if target < 0 {
                lfe = APACObjectTrajectory(initial)
                lfe.restart(at: clock)
            } else {
                slots[target] = APACObjectTrajectory(initial)
                slots[target].restart(at: clock)
            }
        }
        // Beds sound from the start, from their slots or the bus.
        apply(.init(frameOffset: 0, rampFrames: 0, states: newRoles.map(Self.bedDefault)))
    }

    private static func bedDefault(_ role: ObjectAudioRole) -> ObjectAudioElementState? {
        switch role {
        case .bed, .fixed: return ObjectAudioElementState()
        case .object, .lfe: return nil
        }
    }

    /// Two voices per element: a bed channel's first is the bed channel itself, routed by TS 103 448
    /// table 6, and silent until it is sent a gain; the others are objects.
    private static func busRenderer(_ output: SpatialSpeakerLayout, roles: [ObjectAudioRole]) -> ObjectAudioRenderer {
        let voices: [ObjectAudioRole] = roles.map { if case .bed = $0 { $0 } else { .object } }
            + roles.map { _ in .object }
        let bus = ObjectAudioRenderer(layout: output, roles: voices)
        let silent = voices.map { role -> ObjectAudioElementState? in
            if case .bed = role { ObjectAudioElementState(gain: 0) } else { nil }
        }
        bus.advance(frameCount: 0, updates: [.init(frameOffset: 0, rampFrames: 0, states: silent)])
        return bus
    }

    private func resetMotion() {
        rampFrom = roles.map { _ in nil }
        rampStart = roles.map { _ in 0 }
        rampLength = roles.map { _ in 0 }
        busVoice = roles.map { _ in 0 }
        voiceSounding = Array(repeating: false, count: 2 * roles.count)
        voiceFadeEnds = Array(repeating: 0, count: 2 * roles.count)
    }

    private func apply(_ update: ObjectAudioMetadataUpdate) {
        let n = roles.count
        var busStates = [ObjectAudioElementState?](repeating: nil, count: 2 * n)
        var busFrom = busStates
        let ramp = update.rampFrames
        func send(_ voice: Int, _ state: ObjectAudioElementState) {
            busStates[voice] = state
            if voiceSounding[voice], state.gain == 0 { voiceFadeEnds[voice] = clock + Int64(ramp) + 1 }
            voiceSounding[voice] = state.gain > 0
        }
        /// The element's voice in use, or its other one while that is still fading out.
        func freeVoice(_ element: Int) -> Int {
            let v = busVoice[element] * n + element
            busVoice[element] = clock < voiceFadeEnds[v] ? 1 - busVoice[element] : busVoice[element]
            return busVoice[element] * n + element
        }
        for (element, state) in update.states.enumerated() {
            guard let state, element < route.count, let target = route[element] else { continue }
            let previous = lastStates[element]
            lastStates[element] = state
            let values: APACObjectTrajectory.Values
            switch roles[element] {
            case .object:
                let onBus = Self.needsBus(state, on: output)
                var moving: ObjectAudioElementState?
                if onBus {
                    if output != .l20 { busUpdates += 1 }
                    send(freeVoice(element), state)
                } else if let previous, ramp > 0, !Self.needsBus(previous, on: output),
                          Self.rampsDiffer(from: previous, to: state, on: output) {
                    // What the slot plays now takes over on the bus and fades there; the slot comes in
                    // where it goes. At this frame, mid-ramp or not: the position its ramp has reached
                    // and its gain, the trim taken back out for the bus to apply.
                    busRamps += 1
                    var now = current(element, previous: previous)
                    let trim = now.trim?.gain(at: ObjectAudioRenderer.renderPosition(now, on: output), on: output) ?? 1
                    now.gain = trim > 0 ? slots[target].gain(before: clock) / trim : 0
                    let voice = freeVoice(element)
                    busFrom[voice] = now
                    voiceSounding[voice] = now.gain > 0
                    var fading = now
                    fading.gain = 0
                    send(voice, fading)
                    slots[target].apply(.init(position: slots[target].value(at: clock).position, size: 0, gain: 0),
                                        at: clock, rampFrames: 0)
                } else {
                    // Silent on the bus, so the bus has a state to ramp from if the object moves onto it;
                    // a voice still fading out is left to finish.
                    var silent = state
                    silent.gain = 0
                    for v in [element, n + element] where clock >= voiceFadeEnds[v] { send(v, silent) }
                    if let previous, previous.gain > 0, state.gain > 0 { moving = current(element, previous: previous) }
                }
                rampFrom[element] = moving
                rampStart[element] = clock
                rampLength[element] = ramp
                let trim = state.trim?.gain(at: ObjectAudioRenderer.renderPosition(state, on: output), on: output) ?? 1
                // Even along every axis here: one that is not goes to the bus (`needsBus`).
                values = .init(position: Self.objectPosition(state, on: output), size: state.size.max(),
                               gain: onBus ? 0 : state.gain * trim)
            case .bed, .fixed:
                // A bed channel table 6 sends to one speaker plays from its slot there; one it splits
                // between two plays from the bus. On stereo, whose pan law is not TS 103 448's,
                // everything is rendered on the bus.
                let (position, placed): (SIMD3<Float>, (position: SIMD3<Float>, gain: Float)?)
                switch roles[element] {
                case .bed(let speaker): (position, placed) = (speaker.position, Self.placement(of: speaker, on: output, bedHasBacks: bedHasBacks))
                case .fixed(let p): (position, placed) = (p, (Self.position(p, on: output), 1))
                case .object, .lfe: continue
                }
                let onBus = output == .l20 || placed == nil
                if onBus || voiceSounding[element] {
                    send(element, ObjectAudioElementState(position: position, gain: onBus ? state.gain : 0))
                }
                values = .init(position: placed?.position ?? position, size: 0,
                               gain: onBus ? 0 : state.gain * (placed?.gain ?? 1))
            case .lfe: values = .init(position: SIMD3(0.5, 0, 0), size: 0, gain: state.gain)
            }
            if target < 0 {
                lfe.apply(values, at: clock, rampFrames: ramp)
            } else {
                slots[target].apply(values, at: clock, rampFrames: ramp)
            }
        }
        if busFrom.contains(where: { $0 != nil }) {
            bus.advance(frameCount: 0, updates: [.init(frameOffset: 0, rampFrames: 0, states: busFrom)])
        }
        if busStates.contains(where: { $0 != nil }) {
            bus.advance(frameCount: 0, updates: [.init(frameOffset: 0, rampFrames: ramp, states: busStates)])
        }
    }

    /// An object's state where its slot ramp has got to now (`previous` once the ramp is over).
    private func current(_ element: Int, previous: ObjectAudioElementState) -> ObjectAudioElementState {
        guard let from = rampFrom[element], rampLength[element] > 0,
              clock < rampStart[element] + Int64(rampLength[element]) else { return previous }
        let f = Float(clock - rampStart[element]) / Float(rampLength[element])
        var now = previous
        now.position = from.position + (previous.position - from.position) * f
        now.size = from.size + (previous.size - from.size) * f
        return now
    }

    private func markDiscontinuity() {
        lastStates = lastStates.map { _ in nil }
        rampFrom = rampFrom.map { _ in nil }
        for i in slots.indices { slots[i].markDiscontinuity() }
        lfe.markDiscontinuity()
        bus.markDiscontinuity()
    }

    /// Whether an object needs what the renderer will not do with type 3: a zone mask that takes
    /// away one of the output's ear-level speakers, or divergence; or any object at all on stereo,
    /// whose pan law is not TS 103 448's. Taking the heights away from a point is already a position
    /// (the elevation switch put it at ear level), but a size spreads in three dimensions and nothing
    /// tells the renderer to keep it off the heights, so a sized object without elevation is rendered
    /// here on an output that has them. And the renderer takes one size for every axis, the largest
    /// (README §3.6), so an object sized differently along its axes is rendered here too.
    static func needsBus(_ state: ObjectAudioElementState, on output: SpatialSpeakerLayout) -> Bool {
        output == .l20 || state.divergence > 0
            || output.speakers.contains { !$0.isLFE && !$0.isHeight && state.excluded.contains($0) }
            || (!state.elevation && state.size.max() > 0 && output.isBed)
            || state.size.max() != state.size.min()
    }

    private static let outputPanners = Dictionary(uniqueKeysWithValues: [SpatialSpeakerLayout.l20, .l51, .l71, .l714].map {
        ($0, AllocentricPanner(layout: $0))
    })

    /// Whether ramping an object's position from `previous` to `state` would sound different from
    /// Atmos's ramp of its speaker gains on `output`: halfway through, some speaker's gain differs by
    /// more than `rampTolerance`. Only a ramp between two sounding positions can; one to or from
    /// silence holds its position (`APACObjectTrajectory`).
    static func rampsDiffer(from previous: ObjectAudioElementState, to state: ObjectAudioElementState,
                            on output: SpatialSpeakerLayout = .l714) -> Bool {
        guard previous.gain > 0, state.gain > 0 else { return false }
        let a = objectPosition(previous, on: output), b = objectPosition(state, on: output)
        guard a != b else { return false }
        let panner = outputPanners[output] ?? AllocentricPanner(layout: output)
        var from: [Float] = [], to: [Float] = [], mid: [Float] = []
        panner.pointGains(a, into: &from)
        panner.pointGains(b, into: &to)
        panner.pointGains((a + b) / 2, into: &mid)
        return mid.indices.contains { abs((from[$0] + to[$0]) / 2 - mid[$0]) > rampTolerance }
    }

    /// 2% of full scale: the small steps of a moving object stay well under it, a jump between
    /// speakers is far over it.
    static let rampTolerance: Float = 0.02

    /// The position the renderer gets: inside its room, and at ear level for an object kept off the
    /// heights (TS 103 448 5.1.3.2), which is how type 3 hears an elevation switch, or for any object
    /// on an output without heights, where TS 103 448 pans by x and y alone.
    static func objectPosition(_ state: ObjectAudioElementState, on output: SpatialSpeakerLayout) -> SIMD3<Float> {
        var p = position(simd_clamp(state.position, SIMD3(repeating: 0), SIMD3(repeating: 1)), on: output)
        if !state.elevation { p.z = 0 }
        return p
    }

    /// A fixed position as the output pans it: at ear level when it has no heights.
    static func position(_ p: SIMD3<Float>, on output: SpatialSpeakerLayout) -> SIMD3<Float> {
        output.isBed ? p : SIMD3(p.x, p.y, 0)
    }

    /// Where a bed channel plays on the output and at what gain, as `ObjectAudioRenderer` routes it
    /// (TS 103 448 table 6): on its own speaker or the one the table folds it to, or panned from its
    /// position where the table has no row for it. Nil where the table splits it between speakers,
    /// which one object cannot do exactly.
    static func placement(of speaker: SpatialSpeaker, on output: SpatialSpeakerLayout,
                          bedHasBacks: Bool) -> (position: SIMD3<Float>, gain: Float)? {
        guard let routes = ObjectAudioRenderer.speakerAnchoredRoutes(speaker, in: output, bedHasBacks: bedHasBacks) else {
            return (position(speaker.position, on: output), 1)
        }
        guard routes.count == 1 else { return nil }
        return (output.speakers[routes[0].channel].position, routes[0].gain)
    }

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

    /// On stereo the renderer plays an object at a speaker's position into the other speaker too, in
    /// phase, at 0.041 of its amplitude (−27.7 dB; measured as 99.83/0.17 power on a hard-left object,
    /// and as the 2-point shift it gives a pan between the two). The bus inverts that mix before it.
    static let stereoCrosstalk: Float = 0.041

    static func cancelStereoCrosstalk(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int) {
        let e = stereoCrosstalk, scale = 1 / (1 - e * e)
        for i in 0..<count {
            let (l, r) = (left[i], right[i])
            left[i] = (l - e * r) * scale
            right[i] = (r - e * l) * scale
        }
    }

    // MARK: - Output

    /// What tvOS renders object APAC to on the current route: 7.1.4 for Dolby Atmos over HDMI and
    /// for spatial audio on headphones (README §5), otherwise the route's own channels as 7.1, 5.1
    /// or stereo. 7.1.4 where there is no audio session.
    static func currentOutput() -> SpatialSpeakerLayout {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        switch session.renderingMode {
        case .dolbyAtmos, .spatialAudio: return .l714
        case .monoStereo: return .l20
        default:
            let channels = session.outputNumberOfChannels
            return channels >= 12 ? .l714 : channels >= 8 ? .l71 : channels >= 6 ? .l51 : .l20
        }
        #else
        return .l714
        #endif
    }

    /// Render the audio encoded from the next chunk on for `output`. Thread-safe.
    func requestOutput(_ output: SpatialSpeakerLayout) {
        outputLock.lock()
        pendingOutput = output
        outputLock.unlock()
    }

    /// Follow the audio route from here on (route and rendering-mode changes).
    func followRoute() {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        for name in [AVAudioSession.routeChangeNotification, AVAudioSession.renderingModeChangeNotification] {
            routeObservers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) {
                [weak self] _ in self?.requestOutput(Self.currentOutput())
            })
        }
        #endif
    }

    /// Render for `next` from here on: the bus moves to its speakers, and every element is placed and
    /// trimmed for it again from its last state. Audio already encoded keeps the old output, so the
    /// change is heard as far behind the route change as the stream is buffered ahead of playback.
    private func switchOutput(to next: SpatialSpeakerLayout) {
        EngineLog.emit("[APACObjectEncoder] output \(output.rawValue) -> \(next.rawValue)", category: .session)
        output = next
        busSpeakers = next.speakers.filter { !$0.isLFE }
        for k in 0..<Self.busCapacity {
            let values = k < busSpeakers.count
                ? APACObjectTrajectory.Values(position: busSpeakers[k].position, size: 0, gain: 1) : Self.silent
            slots[Self.objectSlots + k].apply(values, at: clock, rampFrames: 0)
        }
        bus = Self.busRenderer(next, roles: roles)
        let states = lastStates
        lastStates = states.map { _ in nil }
        resetMotion()
        let restated = roles.indices.map { element in states[element] ?? Self.bedDefault(roles[element]) }
        apply(ObjectAudioMetadataUpdate(frameOffset: 0, rampFrames: 0, states: restated))
    }

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
            for _ in 0..<2 {
                for element in roles.indices { busInputs.append(UnsafePointer(planes[element] + start)) }
            }
            bus.render(inputs: busInputs, frameCount: count, updates: [], outputs: Array(busPlanes.prefix(output.channelCount)))
            if output == .l20 { Self.cancelStereoCrosstalk(busPlanes[0], busPlanes[1], count: count) }
            for (k, speaker) in busSpeakers.enumerated() {
                let plane = busPlanes[output.speakers.firstIndex(of: speaker)!]
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
        // Over the metadata channel's capacity, the object with the most blocks gives up half its
        // budget, and so on until the packet fits: only the busiest objects lose timing detail.
        var budgets = [Int](repeating: APACObjectMetadata.maxBlocks, count: slots.count)
        var packet: [UInt8]?
        while true {
            let objects = slots.indices.map {
                used[$0] ? slots[$0].blocks(packetStart: packetStart, maxBlocks: budgets[$0], map: map) : []
            }
            if let p = APACObjectMetadata.packet(objects: objects) {
                packet = p
                largestMetadataPacket = max(largestMetadataPacket, p.count)
                break
            }
            guard let busiest = objects.indices.max(by: { objects[$0].count < objects[$1].count }),
                  objects[busiest].count > 1 else { break }
            budgets[busiest] = max(min(budgets[busiest], objects[busiest].count) / 2, 1)
            budgetFallbacks += 1
        }
        metadataPackets += 1
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
    /// Each object's own bit rate. Without one the encoder codes every object at 128 kbit/s whatever
    /// the stream's target, and a full scene through the system renderer comes back at 24–28 dB SNR
    /// against the exact objects, its top octave gone. The Object component's `Bit Rate` is honoured
    /// although the codec lists it as not allowed in an input setting. Up to about 520 kbit/s it is a
    /// constant rate per object (51 dB at 15 Mbit/s for 27 objects); 576 kbit/s fails; from 600 kbit/s
    /// the encoder codes to quality instead (600 kbit/s and 1 Mbit/s give the same stream): 50–52 dB,
    /// flat to 24 kHz, at 1.5 Mbit/s for Helicopter and 7.5 Mbit/s (10.3 at peak) for Unfold.
    /// Measured by `APACObjectOutputTests.sceneQuality`; the 7.1.4 bed encoder gets 55–65 dB.
    static let objectBitRate = 1_000_000
    static var defaultObjectSettings: [NSDictionary] { [["key": "Bit Rate", "current value": objectBitRate]] }

    private static func settings(codec: AudioComponentInstance, objectSettings: [NSDictionary],
                                 sceneSettings: [NSDictionary]) throws -> NSDictionary {
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
                ] + objectSettings,
            ])
        }
        let blob = APACObjectMetadata.staticBlob(objects: sceneObjects)
        return [
            "version": 0,
            "sub version": 0,
            "parameters": [
                ["key": "Audio Scene Components", "ASComponents": components],
                ["key": "StaticMetadata", "StaticMetadata": blob.map { NSNumber(value: Int8(bitPattern: $0)) }],
            ] + sceneSettings,
        ]
    }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}
#endif
