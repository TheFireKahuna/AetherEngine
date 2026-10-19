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
    /// Blocks between a reset and the first metadata, so objects play from the first frame (see
    /// `ObjectMetadataHold`), and the released block last handed out, whose planes it owns.
    private let hold = ObjectMetadataHold()
    private var lent: ObjectMetadataHold.Copy?

    /// `splitsBed` is false only for the measurement reference (`TrueHDReferenceRender` trait).
    init(splitsBed: Bool = true, objectOutput: Bool = false) throws {
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

    /// The library's next block, with every element's state as of its first metadata update.
    private func pull() throws -> (ObjectAudioDecodedBlock, [ObjectAudioElementState?]?)? {
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
                if u == 0 { firstStates = (0..<count).map { state(for: update.elements[$0]) } }
                var states: [ObjectAudioElementState?] = []
                states.reserveCapacity(count)
                for e in 0..<count {
                    let element = update.elements[e]
                    states.append(element.flags & TRUEHD_ATMOS_ELEMENT_CHANGED != 0
                                  ? state(for: element) : nil)
                }
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

    private func state(for element: TrueHDAtmosElement) -> ObjectAudioElementState {
        #if TrueHDReferenceRender || APACObjectOutput
        splitsBed ? Self.pointSource(for: element) : Self.state(for: element)
        #else
        Self.pointSource(for: element)
        #endif
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
    // The reference render's mapping: size, snap, zones, screen anchoring and the elevation switch.
    // Object output uses it as well.
    static func state(for element: TrueHDAtmosElement) -> ObjectAudioElementState {
        let active = element.flags & TRUEHD_ATMOS_ELEMENT_ACTIVE != 0
        var p = element.position
        var size = max(element.size.0, element.size.1, element.size.2)
        if element.kind == TRUEHD_ATMOS_ELEMENT_ISF {
            // The library does not decode ISF (intermediate spatial format) positions, and no home
            // content carrying them was found. Spread it over the room rather than pin it to
            // whatever position value is left in the struct.
            p = (0.5, 0.5, 0.5)
            size = 1
        } else if element.flags & TRUEHD_ATMOS_ELEMENT_SCREEN_REF != 0 {
            let room = roomPosition(screenAnchored: SIMD3(p.0, p.1, p.2), screenFactor: element.screen_factor,
                                    depthFactor: element.depth_factor, screen: .frontWall)
            p = (room.x, room.y, room.z)
        }
        var excluded = excludedSpeakers(zone: element.zone)
        if element.kind == TRUEHD_ATMOS_ELEMENT_OBJECT, element.flags & TRUEHD_ATMOS_ELEMENT_ELEVATION == 0 {
            excluded.formUnion(heights)
        }
        return ObjectAudioElementState(
            position: SIMD3(p.0, p.1, max(0, p.2)),
            gain: active ? element.gain : 0,
            size: size,
            snap: element.flags & TRUEHD_ATMOS_ELEMENT_SNAP != 0,
            excluded: excluded)
    }

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
