// Only with the TrueHDObjectAudio trait (off by default), which links LibTrueHD.
#if TrueHDObjectAudio
import Foundation
import TrueHD

/// TrueHD object-presentation decoder over the LibTrueHD library (the Rust `truehd` crate behind
/// a C API): lossless decode of presentation 3, which for an Atmos stream is the bed plus up to 15
/// dynamic objects, together with the object audio metadata (OAMD) that positions them.
///
/// With `splitsBed` (the engine's TrueHD path, see `BedSplitter`) the decode is a different one:
/// the matrix interpolation values are discarded, so the object signals are approximate, every block
/// also carries the stream's channel-based presentation (Dolby's own 7.1 or 5.1 rendering of the mix)
/// from the same access unit, and elements are described as plain point sources: the bridge then
/// takes every output from that bed and only reads where the objects' energy lies.
///
/// The library's coordinates are OAMD room coordinates (ETSI TS 103 420 4.2.1): x left→right and
/// y front→back on 0...1, z −1 floor, 0 ear level, +1 ceiling. That is the renderer's own room
/// model above ear level; home Atmos keeps objects at z ≥ 0, and anything below is clamped to the
/// ear-level plane, which is the lowest a home bed has.
final class TrueHDObjectAudioDecoder: ObjectAudioDecoding {

    struct DecoderError: Error, CustomStringConvertible {
        let status: Int32
        let message: String
        var description: String { "TrueHDObjectAudioDecoder: status \(status) \(message)" }
    }

    private let handle: OpaquePointer
    private var roles: [ObjectAudioRole] = []
    private var rolesSerial: UInt32?
    private var planes: [UnsafePointer<Float>] = []
    let splitsBed: Bool
    /// Object output (`APACObjectOutput`): the elements and their full metadata, ramps included, go
    /// out as APAC objects. No bed companion.
    let objectOutput: Bool
    var playsBedOnly: Bool { splitsBed }
    private var bedRoles: [ObjectAudioRole] = []
    private var bedRolesSerial: UInt32?
    private var bedPlanes: [UnsafePointer<Float>] = []
    private(set) var selfResetCount = 0
    private var warpLogged = false
    /// Blocks between a reset and the first metadata, so objects play from the first frame (see
    /// `ObjectMetadataHold`), and the released block last handed out, whose planes it owns.
    private let hold = ObjectMetadataHold()
    private var lent: ObjectMetadataHold.Copy?
    /// A 96 or 192 kHz stream's elements and bed, brought to 48 kHz (`ObjectAudioDecimator`), and a
    /// discontinuity the decimator has not yet produced a block to carry.
    private var decimator: ObjectAudioDecimator?
    private var bedDecimator: ObjectAudioDecimator?
    private var discontinuityPending = false

    /// The listener's dialogue gain in dB (`LoadOptions.objectDialogueGain`), applied as
    /// `dialogueEnhancement(gain:maximum:)` has it.
    let dialogueGain: Float

    /// `splitsBed` is false only for the measurement reference (`TrueHDReferenceRender` trait).
    init(splitsBed: Bool = true, objectOutput: Bool = false, dialogueGain: Float = 0) throws {
        #if !TrueHDReferenceRender
        precondition(splitsBed || objectOutput, "the exact decode and mix are only built with the TrueHDReferenceRender trait")
        #endif
        #if !APACObjectOutput
        precondition(!objectOutput, "object output is only built with the APACObjectOutput trait")
        #endif
        precondition(!(splitsBed && objectOutput), "object output plays the elements, not the bed")
        guard let handle = truehd_atmos_decoder_create(TRUEHD_ATMOS_PRESENTATION_HIGHEST) else {
            throw DecoderError(status: TRUEHD_ATMOS_ERR_INVALID_ARGUMENT, message: "create failed")
        }
        self.handle = handle
        self.dialogueGain = dialogueGain
        self.splitsBed = splitsBed
        self.objectOutput = objectOutput
        if splitsBed {
            _ = truehd_atmos_decoder_set_bed_companion(handle, true)
            _ = truehd_atmos_decoder_set_ignore_interpolation(handle, true)
        }
        // Object output, like the reference render, leaves interpolation on (LibTrueHD's default):
        // with a LibTrueHD built with `matrix-interpolation` the elements decode exactly. With the
        // shipped binary they decode approximately, with crosstalk wherever the stream interpolates
        // (research notes §3.8), and object output is not worth listening to.
    }

    deinit { truehd_atmos_decoder_destroy(handle) }

    func push(_ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        let status = truehd_atmos_decoder_push(
            handle, base.assumingMemoryBound(to: UInt8.self), bytes.count, Int64.min)
        // BUFFER_FULL (8 MiB waiting) cannot happen behind the bridge, which drains every block after
        // each push; a panic resets for the same reason as in `nextBlock`.
        if status == TRUEHD_ATMOS_ERR_PANIC {
            let failure = error(status)
            reset()
            selfResetCount += 1
            throw failure
        }
        guard status == TRUEHD_ATMOS_OK else { throw error(status) }
    }

    func nextBlock() throws -> ObjectAudioDecodedBlock? {
        lent = nil
        while true {
            if let released = hold.nextReleased() {
                lent = released
                return released.block
            }
            guard let (block, firstStates) = try pull() else { return nil }
            if let block = hold.admit(block, firstStates: firstStates) { return block }
        }
    }

    /// The next block at 48 kHz, with every element's state as of its first metadata update.
    private func pull() throws -> (ObjectAudioDecodedBlock, [ObjectAudioElementState?]?)? {
        while let (block, firstStates) = try pullLibrary() {
            guard let factor = ObjectAudioDecimator.factor(from: block.sampleRate) else { return (block, firstStates) }
            if let decimated = decimate(block, factor: factor) { return (decimated, decimated.updates.first?.states) }
        }
        return nil
    }

    /// `block` at 48 kHz, nil while the decimator's look-ahead has taken all of it (a stream's first
    /// frames, a short final access unit).
    private func decimate(_ block: ObjectAudioDecodedBlock, factor: Int) -> ObjectAudioDecodedBlock? {
        if decimator?.factor != factor {
            decimator = ObjectAudioDecimator(factor: factor)
            bedDecimator = ObjectAudioDecimator(factor: factor)
        }
        guard let decimator, let bedDecimator else { return nil }
        if block.isDiscontinuity {
            decimator.reset()
            bedDecimator.reset()
            discontinuityPending = true
        }
        let main = decimator.process(planes: block.planes, frames: block.frameCount,
                                     inputStart: block.inputFrameOffset, updates: block.updates)
        var out = block
        if let bed = block.bed {
            let decimatedBed = bedDecimator.process(planes: bed.planes, frames: block.frameCount,
                                                    inputStart: block.inputFrameOffset, updates: [])
            out.bed = ObjectAudioBed(roles: bed.roles, planes: decimatedBed.planes)
        } else {
            bedDecimator.reset()
        }
        guard main.frames > 0 else { return nil }
        out.sampleRate = ObjectAudioRendering.sampleRate
        out.frameCount = main.frames
        out.inputFrameOffset = main.start
        out.planes = main.planes
        out.updates = main.updates
        out.isDiscontinuity = discontinuityPending
        discontinuityPending = false
        return out
    }

    /// The library's next block, at the stream's rate.
    private func pullLibrary() throws -> (ObjectAudioDecodedBlock, [ObjectAudioElementState?]?)? {
        var block = TrueHDAtmosBlock()
        let status = truehd_atmos_decoder_pull(handle, &block)
        if status == TRUEHD_ATMOS_NEED_MORE_DATA { return nil }
        if status == TRUEHD_ATMOS_ERR_PANIC {
            // The handle refuses every call until it is reset. Reset it here, so the stream resumes
            // at the next major sync instead of staying silent for the rest of the session.
            let failure = error(status)
            reset()
            selfResetCount += 1
            throw failure
        }
        guard status == TRUEHD_ATMOS_OK else { throw error(status) }

        let channels = Int(block.channel_count)
        if rolesSerial != block.layout_serial {
            rolesSerial = block.layout_serial
            roles = (0..<channels).map { Self.role(forSpeaker: block.speakers[$0]) }
        }
        planes.removeAll(keepingCapacity: true)
        for c in 0..<channels { planes.append(UnsafePointer(block.channels[c]!)) }

        var bed: ObjectAudioBed?
        let bedChannels = Int(block.bed_channel_count)
        if bedChannels > 0, let channels = block.bed_channels, let speakers = block.bed_speakers {
            if bedRolesSerial != block.layout_serial || bedRoles.count != bedChannels {
                bedRolesSerial = block.layout_serial
                bedRoles = (0..<bedChannels).map { Self.role(forSpeaker: speakers[$0]) }
            }
            bedPlanes.removeAll(keepingCapacity: true)
            for c in 0..<bedChannels { bedPlanes.append(UnsafePointer(channels[c]!)) }
            bed = ObjectAudioBed(roles: bedRoles, planes: bedPlanes)
        }

        var updates: [ObjectAudioMetadataUpdate] = []
        var firstStates: [ObjectAudioElementState?]?
        if block.flags & TRUEHD_ATMOS_BLOCK_METADATA_UPDATED != 0, let metadata = block.metadata {
            let md = metadata.pointee
            let count = min(Int(md.element_count), channels)
            for u in 0..<Int(md.update_count) {
                let update = md.updates[u]
                // Trims and warp as of this update, which another update in the block may change. The
                // published LibTrueHD (API 2) has no per-update trims; its warp mode is the block's.
                #if TrueHDReferenceRender || APACObjectOutput
                let stream = streamMetadata(warpMode: update.warp_mode, trims: update.trims)
                #else
                let stream = streamMetadata(warpMode: md.warp_mode)
                #endif
                if u == 0 { firstStates = (0..<count).map { state(for: update.elements[$0], stream) } }
                // Every element, unchanged ones included: an update restarts every ramp (TS 103 448
                // pseudocode 19).
                let states: [ObjectAudioElementState?] = (0..<count).map { state(for: update.elements[$0], stream) }
                updates.append(ObjectAudioMetadataUpdate(
                    frameOffset: Int(update.frame_offset),
                    // Splitting the bed, each update is taken as it stands, without the ramp towards it.
                    rampFrames: splitsBed ? 0 : Int(update.ramp_frames), states: states))
            }
        }

        return (ObjectAudioDecodedBlock(
            sampleRate: Int(block.sample_rate),
            frameCount: Int(block.frame_count),
            inputFrameOffset: Int64(block.input_frame_offset),
            configurationGeneration: Int(block.layout_serial),
            isDiscontinuity: block.flags & TRUEHD_ATMOS_BLOCK_DISCONTINUITY != 0,
            roles: roles,
            planes: planes,
            updates: updates,
            bed: bed), firstStates)
    }

    func reset() {
        _ = truehd_atmos_decoder_reset(handle)
        hold.arm()
        lent = nil
        decimator?.reset()
        bedDecimator?.reset()
        discontinuityPending = false
    }

    func releaseHeldBlocks() {
        hold.releaseAll()
    }

    private func error(_ status: Int32) -> DecoderError {
        let message = truehd_atmos_decoder_last_error(handle).map { String(cString: $0) } ?? ""
        return DecoderError(status: status, message: message)
    }

    // MARK: - Mapping

    /// Bed speakers the renderer's room model names route discretely; the other speaker codes
    /// (screen, centre back, top centre, surround direct) sit at their nominal position, so a
    /// channel-based presentation without metadata still plays them. Objects and unlabelled
    /// channels are positioned by metadata.
    static func role(forSpeaker code: UInt8) -> ObjectAudioRole {
        switch code {
        case TRUEHD_ATMOS_SPEAKER_LFE, TRUEHD_ATMOS_SPEAKER_LFE2: return .lfe
        case TRUEHD_ATMOS_SPEAKER_L: return .bed(.left)
        case TRUEHD_ATMOS_SPEAKER_R: return .bed(.right)
        case TRUEHD_ATMOS_SPEAKER_C: return .bed(.center)
        case TRUEHD_ATMOS_SPEAKER_LS: return .bed(.sideLeft)
        case TRUEHD_ATMOS_SPEAKER_RS: return .bed(.sideRight)
        case TRUEHD_ATMOS_SPEAKER_LB: return .bed(.rearLeft)
        case TRUEHD_ATMOS_SPEAKER_RB: return .bed(.rearRight)
        case TRUEHD_ATMOS_SPEAKER_LW: return .bed(.wideLeft)
        case TRUEHD_ATMOS_SPEAKER_RW: return .bed(.wideRight)
        case TRUEHD_ATMOS_SPEAKER_TFL: return .bed(.topFrontLeft)
        case TRUEHD_ATMOS_SPEAKER_TFR: return .bed(.topFrontRight)
        case TRUEHD_ATMOS_SPEAKER_TSL: return .bed(.topMiddleLeft)
        case TRUEHD_ATMOS_SPEAKER_TSR: return .bed(.topMiddleRight)
        case TRUEHD_ATMOS_SPEAKER_TBL: return .bed(.topRearLeft)
        case TRUEHD_ATMOS_SPEAKER_TBR: return .bed(.topRearRight)
        case TRUEHD_ATMOS_SPEAKER_LSC: return .fixed(SIMD3(0.25, 0, 0))
        case TRUEHD_ATMOS_SPEAKER_RSC: return .fixed(SIMD3(0.75, 0, 0))
        case TRUEHD_ATMOS_SPEAKER_CB: return .fixed(SIMD3(0.5, 1, 0))
        case TRUEHD_ATMOS_SPEAKER_LSD: return .fixed(SpatialSpeaker.sideLeft.position)
        case TRUEHD_ATMOS_SPEAKER_RSD: return .fixed(SpatialSpeaker.sideRight.position)
        case TRUEHD_ATMOS_SPEAKER_TC: return .fixed(SIMD3(0.5, 0.5, 1))
        case TRUEHD_ATMOS_SPEAKER_TFC: return .fixed(SIMD3(0.5, 0.25, 1))
        default: return .object
        }
    }

    private func state(for element: TrueHDAtmosElement, _ stream: StreamMetadata) -> ObjectAudioElementState {
        #if TrueHDReferenceRender || APACObjectOutput
        splitsBed ? Self.pointSource(for: element) : Self.state(for: element, stream: stream)
        #else
        Self.pointSource(for: element)
        #endif
    }

    /// What the stream signals for every element at once, as of a block's updates.
    struct StreamMetadata: Equatable {
        /// warp_mode 1 (TS 103 420 table 32).
        var warp = false
        var trim = ObjectAudioTrim.defaults
        /// The linear gain for elements the stream marks as dialogue (`dialogueEnhancement`).
        var dialogue: Float = 1
    }

    /// Dialogue enhancement as AC-4 specifies it for object audio (TS 103 190-2 V1.3.1 5.8.2.5): the
    /// objects marked as dialogue take 10^(G/20), G the listener's gain in dB, at most `maximum`, the
    /// most the stream allows. A stream that states no maximum allows none (G_max = 0 dB), so it can
    /// be turned down but not up. TrueHD carries the marks in OAMD element 4 (dialog 1) and no maximum
    /// anyone has decoded, and no film surveyed carries the element at all.
    static func dialogueEnhancement(gain: Float, maximum: Float = 0) -> Float {
        powf(10, min(gain, maximum) / 20)
    }

    #if TrueHDReferenceRender || APACObjectOutput
    private typealias UpdateTrims = UnsafePointer<TrueHDAtmosTrim>
    #else
    private typealias UpdateTrims = UnsafeRawPointer
    #endif

    private func streamMetadata(warpMode: Int32, trims updateTrims: UpdateTrims? = nil) -> StreamMetadata {
        var stream = StreamMetadata(warp: warpMode == TRUEHD_ATMOS_WARP_WARPING,
                                    dialogue: Self.dialogueEnhancement(gain: dialogueGain))
        if stream.warp, !warpLogged {
            warpLogged = true
            EngineLog.emit("[TrueHDObjectAudioDecoder] the stream signals warp_mode 1: object depth is doubled "
                           + "(TS 103 420 table 32)", category: .session)
        }
        #if TrueHDReferenceRender || APACObjectOutput
        if let updateTrims {
            let trims = UnsafeBufferPointer(start: updateTrims, count: Int(TRUEHD_ATMOS_TRIM_CONFIGS))
            stream.trim = ObjectAudioTrim(configs: trims.map { t in
                switch t.mode {
                case TRUEHD_ATMOS_TRIM_DISABLED: .disabled
                case TRUEHD_ATMOS_TRIM_CUSTOM: .custom(centre: t.centre_db, surround: t.surround_db, height: t.height_db,
                                                       balanceTop: t.balance_top, balanceListener: t.balance_listener)
                default: .default
                }
            })
        }
        #endif
        return stream
    }

    /// An element as a point at its position: no size, snap, zone exclusion, screen anchoring or
    /// elevation switch. ISF elements, whose positions the library does not decode, sit in the room's
    /// centre.
    static func pointSource(for element: TrueHDAtmosElement) -> ObjectAudioElementState {
        let active = element.flags & TRUEHD_ATMOS_ELEMENT_ACTIVE != 0
        let p = element.kind == TRUEHD_ATMOS_ELEMENT_ISF ? (Float(0.5), Float(0.5), Float(0.5)) : element.position
        return ObjectAudioElementState(position: SIMD3(p.0, p.1, max(0, p.2)), gain: active ? element.gain : 0)
    }

    #if TrueHDReferenceRender || APACObjectOutput
    /// An element as TS 103 420 decodes it and TS 103 448 prepares it for panning, which the
    /// reference render and object output share. In order: the room position (distance, screen
    /// anchoring), warp, the elevation switch, snap; zones, trims and the elevation switch's ear-level
    /// position, which depends on the layout, travel on to the panner.
    static func state(for element: TrueHDAtmosElement, stream: StreamMetadata = .init()) -> ObjectAudioElementState {
        let active = element.flags & TRUEHD_ATMOS_ELEMENT_ACTIVE != 0
        var p = SIMD3(element.position.0, element.position.1, element.position.2)
        var size = max(element.size.0, element.size.1, element.size.2)
        var divergence = element.flags & TRUEHD_ATMOS_ELEMENT_DIVERGENCE != 0 ? element.divergence : 0
        var excluded = excludedSpeakers(zone: element.zone)
        let isObject = element.kind == TRUEHD_ATMOS_ELEMENT_OBJECT
        if element.kind == TRUEHD_ATMOS_ELEMENT_ISF {
            // The library does not decode ISF (intermediate spatial format) positions, and no home
            // content carrying them was found. Spread it over the room rather than pin it to
            // whatever position value is left in the struct.
            p = SIMD3(0.5, 0.5, 0.5)
            size = 1
        } else if element.flags & TRUEHD_ATMOS_ELEMENT_SCREEN_REF != 0 {
            p = roomPosition(screenAnchored: p, screenFactor: element.screen_factor,
                             depthFactor: element.depth_factor, screen: .frontWall)
        } else if element.flags & TRUEHD_ATMOS_ELEMENT_DISTANCE != 0 {
            p = beyondTheRoom(p)
        }
        if isObject, stream.warp { p.y = min(1, 2 * p.y) }
        let elevation = !isObject || element.flags & TRUEHD_ATMOS_ELEMENT_ELEVATION != 0
        // TS 103 448 5.1.3.2: no height speakers (`ObjectAudioRenderer.renderPosition` puts it at ear
        // level where there are some to keep off).
        if !elevation { excluded.formUnion(heights) }
        // TS 103 448 5.1.2.2: a screen-anchored object does not snap.
        let screenAnchored = element.flags & TRUEHD_ATMOS_ELEMENT_SCREEN_REF != 0
        if isObject, element.flags & TRUEHD_ATMOS_ELEMENT_SNAP != 0, !screenAnchored {
            p = snapped(p, zone: element.zone, elevation: element.flags & TRUEHD_ATMOS_ELEMENT_ELEVATION != 0)
            size = 0
            divergence = 0
        }
        let bypassTrim = !isObject || element.flags & TRUEHD_ATMOS_ELEMENT_TRIM_BYPASS != 0
        let dialogue = element.dialog == TRUEHD_ATMOS_DIALOG_DIALOGUE ? stream.dialogue : 1
        return ObjectAudioElementState(
            position: SIMD3(p.x, p.y, max(0, p.z)),
            gain: active ? element.gain * dialogue : 0,
            size: size,
            divergence: divergence,
            excluded: excluded,
            elevation: elevation,
            trim: bypassTrim ? nil : stream.trim)
    }

    /// TS 103 420 5.2.1.2: an object with a distance lies outside the room, distance_factor times
    /// as far from the room's centre O = (0.5, 0.5, 0) as the boundary point I on the ray from O
    /// through its position. Every factor is above 1 (table 15) and a speaker layout ends at the
    /// boundary, so it renders at I, in the direction it was placed.
    static func beyondTheRoom(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let o = SIMD3<Float>(0.5, 0.5, 0)
        let d = c - o
        // The room is x, y in 0...1 and z in -1...1: half-extents 0.5, 0.5, 1 about O.
        let half = SIMD3<Float>(0.5, 0.5, 1)
        var t = Float.infinity
        for axis in 0..<3 where d[axis] != 0 { t = min(t, half[axis] / abs(d[axis])) }
        return t.isFinite ? o + t * d : c
    }

    /// TS 103 448 5.1.4: the panner target of the 22.2 layout nearest the position by the
    /// weighted distance of pseudocode 2, among those the zone mask and the elevation switch
    /// leave (5.1.3 applied to 22.2), the ties going as the clause orders the list.
    static func snapped(_ p: SIMD3<Float>, zone: UInt8, elevation: Bool) -> SIMD3<Float> {
        let weights = SIMD3<Float>(1.0 / 16, 4, 32)
        var best = p, bestDistance = Float.infinity
        for target in snapTargets where elevation || target.position.z == 0 {
            if target.excludedBy.contains(zone) { continue }
            let d = target.position - p
            let distance = (weights * d * d).sum()
            if distance < bestDistance {
                bestDistance = distance
                best = target.position
            }
        }
        return best
    }

    /// TS 103 448 table A.9 (22.2) with the zone masks of table 4 that remove each target, ordered
    /// as 5.1.4.2 orders the snap list: the three centre-line targets first, then by z and y
    /// descending and x ascending. LFEs are no targets.
    private static let snapTargets: [(position: SIMD3<Float>, excludedBy: Set<UInt8>)] = {
        let (noBack, noSides, centreBack, screen, surround) = (TRUEHD_ATMOS_ZONE_NO_BACK, TRUEHD_ATMOS_ZONE_NO_SIDES,
            TRUEHD_ATMOS_ZONE_CENTER_BACK, TRUEHD_ATMOS_ZONE_SCREEN_ONLY, TRUEHD_ATMOS_ZONE_SURROUND_ONLY)
        let table: [(SIMD3<Float>, Set<UInt8>)] = [
            (SIMD3(0, 0, 0), [centreBack, surround]),                  // L
            (SIMD3(1, 0, 0), [centreBack, surround]),                  // R
            (SIMD3(0.5, 0, 0), [surround]),                            // C
            (SIMD3(0, 0.5, 0), [noSides, centreBack, screen]),         // Lss
            (SIMD3(1, 0.5, 0), [noSides, centreBack, screen]),         // Rss
            (SIMD3(0, 1, 0), [noBack, screen]),                        // Lb
            (SIMD3(1, 1, 0), [noBack, screen]),                        // Rb
            (SIMD3(0.25, 0.25, 1), []), (SIMD3(0.75, 0.25, 1), []),    // Tfl, Tfr
            (SIMD3(0.25, 0.75, 1), []), (SIMD3(0.75, 0.75, 1), []),    // Tbl, Tbr
            (SIMD3(0.25, 0.5, 1), []), (SIMD3(0.75, 0.5, 1), []),      // Tsl, Tsr
            (SIMD3(0.5, 0.25, 1), []), (SIMD3(0.5, 0.75, 1), []),      // Tfc, Tbc
            (SIMD3(0.5, 0.5, 1), []),                                  // Tc
            (SIMD3(0, 0, -1), []), (SIMD3(1, 0, -1), []),              // Bfl, Bfr
            (SIMD3(0.5, 0, -1), []),                                   // Bfc
            (SIMD3(0.5, 1, 0), [noBack, screen]),                      // Cb
            (SIMD3(0, 0.2929, 0), [noSides, centreBack, screen, surround]),  // Lw
            (SIMD3(1, 0.2929, 0), [noSides, centreBack, screen, surround]),  // Rw
        ]
        let first: [SIMD3<Float>] = [SIMD3(0.5, 0, 0), SIMD3(0.5, 0, 1), SIMD3(0.5, 0, -1)]
        return table.sorted { a, b in
            let (ia, ib) = (first.firstIndex(of: a.0) ?? 3, first.firstIndex(of: b.0) ?? 3)
            if ia != ib { return ia < ib }
            if a.0.z != b.0.z { return a.0.z > b.0.z }
            if a.0.y != b.0.y { return a.0.y > b.0.y }
            return a.0.x < b.0.x
        }.map { (position: $0.0, excludedBy: $0.1) }
    }()

    /// The playback screen in room coordinates (TS 103 420 4.2.1: x 0…1 left to right, z −1…1 floor to
    /// ceiling): its bottom-left corner and its size. The stream does not carry it. Without one the
    /// screen fills the front wall, which makes the screen-anchored mapping the identity.
    struct PlaybackScreen: Equatable {
        var origin: SIMD3<Float>
        var width: Float
        var height: Float
        static let frontWall = PlaybackScreen(origin: SIMD3(0, 0, -1), width: 1, height: 2)
    }

    /// TS 103 420 5.2.1.3: a screen-anchored position (x across the screen, z −1…1 over its height,
    /// y room depth) as a room position. At the front wall it sits on the screen; deeper in the room it
    /// moves toward the raw coordinates by `screenFactor`, weighted by depth to the power `depthFactor`.
    static func roomPosition(screenAnchored p: SIMD3<Float>, screenFactor: Float, depthFactor: Float,
                             screen: PlaybackScreen) -> SIMD3<Float> {
        let onScreen = SIMD3(screen.origin.x + screen.width * p.x, p.y,
                             screen.origin.z + screen.height / 2 * (p.z + 1))          // C_R
        let blend = screenFactor * p + (1 - screenFactor) * onScreen                    // M1 C_S + (I - M1) C_R
        let weight = pow(max(p.y, 0), depthFactor)                                      // y^depth_factor
        let mixed = weight * blend + (1 - weight) * onScreen                            // M2 (…) + (I - M2) C_R
        return SIMD3(mixed.x, p.y, mixed.z)
    }

    /// Built once: they run per changed element on every metadata update.
    private static let heights = Set(SpatialSpeaker.allCases.filter(\.isHeight))
    /// A 5.1 layout's surrounds are in neither zone: TS 103 448 table 4 excludes nothing for those
    /// two masks on a 3/2 floor, and only screen-only takes the surrounds away.
    private static let noBack: Set<SpatialSpeaker> = [.rearLeft, .rearRight]
    private static let noSides: Set<SpatialSpeaker> = [.sideLeft, .sideRight, .wideLeft, .wideRight]
    private static let screenOnly = noSides.union(noBack).union([.surroundLeft, .surroundRight])
    private static let surroundOnly: Set<SpatialSpeaker> = [.left, .right, .center, .wideLeft, .wideRight]
    /// Centre and back zones only: off the front pair, the wides and the sides.
    private static let centerBack: Set<SpatialSpeaker> = [.left, .right, .wideLeft, .wideRight, .sideLeft, .sideRight]

    /// OAMD horizontal zone constraints (TS 103 420 table 20) as speakers the object may not use.
    static func excludedSpeakers(zone: UInt8) -> Set<SpatialSpeaker> {
        switch zone {
        case TRUEHD_ATMOS_ZONE_NO_BACK: return noBack
        case TRUEHD_ATMOS_ZONE_NO_SIDES: return noSides
        case TRUEHD_ATMOS_ZONE_CENTER_BACK: return centerBack
        case TRUEHD_ATMOS_ZONE_SCREEN_ONLY: return screenOnly
        case TRUEHD_ATMOS_ZONE_SURROUND_ONLY: return surroundOnly
        default: return []
        }
    }
    #endif
}
#endif
