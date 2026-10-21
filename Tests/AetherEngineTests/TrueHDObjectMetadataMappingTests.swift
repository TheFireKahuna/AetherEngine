// Only with the TrueHDObjectAudio trait (off by default): the decoder and its library are not built without it.
#if TrueHDObjectAudio
import Testing
import Foundation
import simd
import TrueHD
@testable import AetherEngine

/// The TrueHD decoder reports OAMD as the bitstream states it; `TrueHDObjectAudioDecoder` turns
/// that into what the renderer acts on (#731). These pin the translations a listener would hear
/// wrong: a bed channel on the wrong speaker, a floor-only object in the ceiling, a zone mask
/// that does not keep an object off the speakers it names.
@Suite("TrueHD object metadata maps onto the renderer's room")
struct TrueHDObjectMetadataMappingTests {

    private func element(
        kind: UInt8 = TRUEHD_ATMOS_ELEMENT_OBJECT,
        flags: UInt32 = TRUEHD_ATMOS_ELEMENT_ACTIVE | TRUEHD_ATMOS_ELEMENT_ELEVATION,
        position: (Float, Float, Float) = (0.25, 0.5, 0.75),
        gain: Float = 0.5,
        size: (Float, Float, Float) = (0, 0, 0),
        zone: UInt8 = TRUEHD_ATMOS_ZONE_ALL
    ) -> TrueHDAtmosElement {
        var e = TrueHDAtmosElement()
        e.kind = kind
        e.speaker = TRUEHD_ATMOS_SPEAKER_OBJECT
        e.zone = zone
        e.flags = flags
        e.position = position
        e.gain = gain
        e.size = size
        return e
    }

    @Test("bed speaker codes route to the matching speaker, LFE to LFE, the rest are positioned")
    func speakerRoles() {
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_L) == .bed(.left))
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_LS) == .bed(.sideLeft))
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_RB) == .bed(.rearRight))
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_TSR) == .bed(.topMiddleRight))
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_LFE) == .lfe)
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_LFE2) == .lfe)
        // No home layout has the screen, centre back or top centre channels; they sit at their
        // nominal position so a presentation without metadata still plays them.
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_TC) == .fixed(SIMD3(0.5, 0.5, 1)))
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_TFC) == .fixed(SIMD3(0.5, 0.25, 1)))
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_CB) == .fixed(SIMD3(0.5, 1, 0)))
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_LSC) == .fixed(SIMD3(0.25, 0, 0)))
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_OBJECT) == .object)
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_UNKNOWN) == .object)
    }

    @Test("splitting the bed, an element is a point at its position with its gain, and nothing else")
    func pointSource() {
        let flags = TRUEHD_ATMOS_ELEMENT_ACTIVE | TRUEHD_ATMOS_ELEMENT_SNAP | TRUEHD_ATMOS_ELEMENT_SCREEN_REF
        let state = TrueHDObjectAudioDecoder.pointSource(
            for: element(flags: flags, position: (0.8, 0.6, 1), size: (0.4, 0.4, 0.4), zone: TRUEHD_ATMOS_ZONE_NO_BACK))
        #expect(state == ObjectAudioElementState(position: SIMD3(0.8, 0.6, 1), gain: 0.5))
        #expect(TrueHDObjectAudioDecoder.pointSource(for: element(flags: 0)).gain == 0)
        #expect(TrueHDObjectAudioDecoder.pointSource(for: element(position: (0.5, 0.5, -0.6))).position.z == 0)
        #expect(TrueHDObjectAudioDecoder.pointSource(for: element(kind: TRUEHD_ATMOS_ELEMENT_ISF)).position
                == SIMD3(0.5, 0.5, 0.5))
    }

    #if TrueHDReferenceRender
    @Test("an active elevated object keeps its position, gain and largest size dimension")
    func plainObject() {
        let state = TrueHDObjectAudioDecoder.state(for: element(size: (0.1, 0.3, 0.2)))
        #expect(state.position == SIMD3(0.25, 0.5, 0.75))
        #expect(state.gain == 0.5)
        #expect(state.size == 0.3)
        #expect(state.excluded.isEmpty)
        #expect(state.divergence == 0)
    }

    @Test("an inactive object is silent")
    func inactiveObject() {
        let state = TrueHDObjectAudioDecoder.state(for: element(flags: TRUEHD_ATMOS_ELEMENT_ELEVATION))
        #expect(state.gain == 0)
    }

    @Test("an object without elevation stays off every height speaker, and comes down to ear level only where there are some")
    func noElevation() {
        let state = TrueHDObjectAudioDecoder.state(for: element(flags: TRUEHD_ATMOS_ELEMENT_ACTIVE))
        let heights = Set(SpatialSpeaker.allCases.filter(\.isHeight))
        #expect(heights.isSubset(of: state.excluded))
        #expect(!state.excluded.contains(.left))
        #expect(!state.elevation)
        // TS 103 448 table 5 lists the layouts with heights only: elsewhere the height stays, for the trim.
        #expect(ObjectAudioRenderer.renderPosition(state, on: .l714).z == 0)
        #expect(ObjectAudioRenderer.renderPosition(state, on: .l51).z == 0.75)
        #expect(ObjectAudioRenderer.renderPosition(state, on: .l20).z == 0.75)
    }

    @Test("a position below the ear-level plane is clamped to it")
    func belowEarLevel() {
        let state = TrueHDObjectAudioDecoder.state(for: element(position: (0.5, 0.5, -0.6)))
        #expect(state.position.z == 0)
    }

    @Test("a screen-anchored object keeps its room depth, and with no screen known plays where it is")
    func screenReference() {
        let flags = TRUEHD_ATMOS_ELEMENT_ACTIVE | TRUEHD_ATMOS_ELEMENT_ELEVATION | TRUEHD_ATMOS_ELEMENT_SCREEN_REF
        // Only x and z are screen-anchored; y is still depth, so an object flying from the screen to
        // the back wall travels (review of eae933d0 found it pinned to the front wall). The playback
        // screen defaults to the whole front wall, where TS 103 420 5.2.1.3 is the identity.
        var e = element(flags: flags, position: (0.8, 0.6, 1))
        e.screen_factor = 0.5
        e.depth_factor = 0.25
        let position = TrueHDObjectAudioDecoder.state(for: e).position
        #expect(simd_distance(position, SIMD3(0.8, 0.6, 1)) < 1e-6)
    }

    @Test("TS 103 420 5.2.1.3: on the screen at the front wall, toward the raw position deeper in")
    func screenAnchoredFormula() {
        // A TV a third of the wall wide, centred, from z = -0.4 to 0.2.
        let tv = TrueHDObjectAudioDecoder.PlaybackScreen(origin: SIMD3(1.0 / 3, 0, -0.4), width: 1.0 / 3, height: 0.6)
        let at = { (p: SIMD3<Float>, sf: Float, df: Float) in
            TrueHDObjectAudioDecoder.roomPosition(screenAnchored: p, screenFactor: sf, depthFactor: df, screen: tv)
        }
        let near = { (a: SIMD3<Float>, b: SIMD3<Float>) in simd_distance(a, b) < 1e-5 }
        // At the front wall the factors do not matter: the screen's centre and its top right corner.
        #expect(near(at(SIMD3(0.5, 0, 0), 1, 0.25), SIMD3(0.5, 0, -0.1)))
        #expect(near(at(SIMD3(1, 0, 1), 0.125, 2), SIMD3(2.0 / 3, 0, 0.2)))
        // At the back wall (weight 1) screen_factor blends: 1 is the raw position, 0.5 halfway.
        #expect(near(at(SIMD3(1, 1, 1), 1, 1), SIMD3(1, 1, 1)))
        #expect(near(at(SIMD3(1, 1, 1), 0.5, 1), SIMD3(5.0 / 6, 1, 0.6)))
        // Halfway into the room the weight is y^depth_factor: 0.5^2 = 0.25 of the way to the raw x.
        #expect(near(at(SIMD3(1, 0.5, 0), 1, 2), SIMD3(2.0 / 3 + 0.25 / 3, 0.5, -0.075)))
    }

    @Test("an ISF object, whose position is not decoded, is spread over the room")
    func isfSpread() {
        let state = TrueHDObjectAudioDecoder.state(for: element(kind: TRUEHD_ATMOS_ELEMENT_ISF, position: (0, 0, 0)))
        #expect(state.position == SIMD3(0.5, 0.5, 0.5))
        #expect(state.size == 1)
    }

    @Test("snap moves the object onto the nearest 22.2 target by TS 103 448's weighted distance")
    func snap() {
        let flags = TRUEHD_ATMOS_ELEMENT_ACTIVE | TRUEHD_ATMOS_ELEMENT_ELEVATION | TRUEHD_ATMOS_ELEMENT_SNAP
        let nearL = TrueHDObjectAudioDecoder.state(for: element(flags: flags, position: (0.2, 0.1, 0), size: (0.3, 0.3, 0.3)))
        #expect(nearL.position == SIMD3(0, 0, 0))
        #expect(nearL.size == 0)
        #expect(TrueHDObjectAudioDecoder.state(for: element(flags: flags, position: (0.15, 0.2, 0.8))).position
                == SIMD3(0.25, 0.25, 1))
        // Surround only and no elevation: the front three, the wides and every height are gone.
        let constrained = element(flags: TRUEHD_ATMOS_ELEMENT_ACTIVE | TRUEHD_ATMOS_ELEMENT_SNAP, position: (0.2, 0.1, 0.8),
                                  zone: TRUEHD_ATMOS_ZONE_SURROUND_ONLY)
        #expect(TrueHDObjectAudioDecoder.state(for: constrained).position == SIMD3(0, 0.5, 0))
    }

    @Test("dialogue enhancement as AC-4 5.8.2.5: G up to the stream's maximum, which is 0 dB when it states none")
    func dialogueEnhancementRule() {
        let db = { (g: Float) in 20 * log10(g) }
        #expect(abs(db(TrueHDObjectAudioDecoder.dialogueEnhancement(gain: 6)) - 0) < 1e-5, "no maximum stated: no boost")
        #expect(abs(db(TrueHDObjectAudioDecoder.dialogueEnhancement(gain: -6)) + 6) < 1e-5, "a cut always applies")
        #expect(abs(db(TrueHDObjectAudioDecoder.dialogueEnhancement(gain: 6, maximum: 9)) - 6) < 1e-5)
        #expect(abs(db(TrueHDObjectAudioDecoder.dialogueEnhancement(gain: 12, maximum: 9)) - 9) < 1e-5)
    }

    @Test("only an element marked as dialogue takes the dialogue gain")
    func dialogueOnlyOnMarkedElements() {
        let stream = TrueHDObjectAudioDecoder.StreamMetadata(dialogue: 0.5)
        var e = element()
        for (dialog, expected) in [(TRUEHD_ATMOS_DIALOG_DIALOGUE, Float(0.25)), (2, 0.5), (3, 0.5), (0, 0.5), (255, 0.5)] {
            e.dialog = dialog
            #expect(TrueHDObjectAudioDecoder.state(for: e, stream: stream).gain == expected, "dialog \(dialog)")
        }
    }

    @Test("a screen-anchored object does not snap (TS 103 448 5.1.2.2)")
    func screenAnchoredDoesNotSnap() {
        var e = element(flags: TRUEHD_ATMOS_ELEMENT_ACTIVE | TRUEHD_ATMOS_ELEMENT_ELEVATION | TRUEHD_ATMOS_ELEMENT_SNAP
                            | TRUEHD_ATMOS_ELEMENT_SCREEN_REF, position: (0.2, 0.1, 0), size: (0.3, 0.3, 0.3))
        e.screen_factor = 1
        e.depth_factor = 1
        let state = TrueHDObjectAudioDecoder.state(for: e)
        // Where it is (the screen fills the front wall), not on the nearest target, L.
        #expect(simd_distance(state.position, SIMD3(0.2, 0.1, 0)) < 1e-6)
        #expect(state.size == 0.3)
    }

    @Test("a distance puts the object on the room boundary along its ray from the centre")
    func distance() {
        #expect(TrueHDObjectAudioDecoder.beyondTheRoom(SIMD3(0.75, 0.5, 0)) == SIMD3(1, 0.5, 0))
        #expect(TrueHDObjectAudioDecoder.beyondTheRoom(SIMD3(0.5, 0.75, 0.5)) == SIMD3(0.5, 1, 1))
        #expect(TrueHDObjectAudioDecoder.beyondTheRoom(SIMD3(0.5, 0.5, 0)) == SIMD3(0.5, 0.5, 0))
        var e = element(flags: TRUEHD_ATMOS_ELEMENT_ACTIVE | TRUEHD_ATMOS_ELEMENT_ELEVATION | TRUEHD_ATMOS_ELEMENT_DISTANCE,
                        position: (0.25, 0.5, 0))
        e.distance = 2
        #expect(TrueHDObjectAudioDecoder.state(for: e).position == SIMD3(0, 0.5, 0))
    }

    @Test("warp mode 1 doubles an object's depth, and leaves the beds alone")
    func warp() {
        let stream = TrueHDObjectAudioDecoder.StreamMetadata(warp: true)
        #expect(TrueHDObjectAudioDecoder.state(for: element(position: (0.5, 0.3, 0)), stream: stream).position.y == 0.6)
        #expect(TrueHDObjectAudioDecoder.state(for: element(position: (0.5, 0.8, 0)), stream: stream).position.y == 1)
        let bed = element(kind: TRUEHD_ATMOS_ELEMENT_BED, position: (0, 0.5, 0))
        #expect(TrueHDObjectAudioDecoder.state(for: bed, stream: stream).position.y == 0.5)
    }

    @Test("objects carry the stream's trims unless they bypass them; beds never trim")
    func trims() {
        var configs = [ObjectAudioTrim.Mode](repeating: .default, count: 9)
        configs[8] = .custom(centre: 0, surround: -3, height: 0)
        let stream = TrueHDObjectAudioDecoder.StreamMetadata(trim: ObjectAudioTrim(configs: configs))
        #expect(TrueHDObjectAudioDecoder.state(for: element(), stream: stream).trim == stream.trim)
        let bypass = TRUEHD_ATMOS_ELEMENT_ACTIVE | TRUEHD_ATMOS_ELEMENT_ELEVATION | TRUEHD_ATMOS_ELEMENT_TRIM_BYPASS
        #expect(TrueHDObjectAudioDecoder.state(for: element(flags: bypass), stream: stream).trim == nil)
        #expect(TrueHDObjectAudioDecoder.state(for: element(kind: TRUEHD_ATMOS_ELEMENT_BED), stream: stream).trim == nil)
    }

    @Test("divergence passes through, and a snapped object has none")
    func divergence() {
        var e = element(flags: TRUEHD_ATMOS_ELEMENT_ACTIVE | TRUEHD_ATMOS_ELEMENT_ELEVATION | TRUEHD_ATMOS_ELEMENT_DIVERGENCE)
        e.divergence = 0.6
        #expect(TrueHDObjectAudioDecoder.state(for: e).divergence == 0.6)
        e.flags |= TRUEHD_ATMOS_ELEMENT_SNAP
        #expect(TrueHDObjectAudioDecoder.state(for: e).divergence == 0)
    }

    @Test("zone masks keep an object off the speakers they name")
    func zoneMasks() {
        let noBack = TrueHDObjectAudioDecoder.excludedSpeakers(zone: TRUEHD_ATMOS_ZONE_NO_BACK)
        #expect(noBack.isSuperset(of: [.rearLeft, .rearRight]))
        #expect(!noBack.contains(.sideLeft))
        // TS 103 448 table 4: on a 3/2 floor neither no-back nor no-sides removes the surrounds.
        #expect(!noBack.contains(.surroundLeft) && !noBack.contains(.surroundRight))

        let noSides = TrueHDObjectAudioDecoder.excludedSpeakers(zone: TRUEHD_ATMOS_ZONE_NO_SIDES)
        #expect(noSides.isSuperset(of: [.sideLeft, .sideRight]))
        #expect(!noSides.contains(.rearLeft) && !noSides.contains(.surroundLeft))

        let screen = TrueHDObjectAudioDecoder.excludedSpeakers(zone: TRUEHD_ATMOS_ZONE_SCREEN_ONLY)
        #expect(!screen.contains(.left) && !screen.contains(.center) && !screen.contains(.right))
        #expect(screen.isSuperset(of: [.sideLeft, .rearRight, .surroundLeft, .surroundRight]))

        let surround = TrueHDObjectAudioDecoder.excludedSpeakers(zone: TRUEHD_ATMOS_ZONE_SURROUND_ONLY)
        #expect(surround.isSuperset(of: [.left, .right, .center]))
        #expect(!surround.contains(.sideLeft))

        let centerBack = TrueHDObjectAudioDecoder.excludedSpeakers(zone: TRUEHD_ATMOS_ZONE_CENTER_BACK)
        #expect(centerBack.isSuperset(of: [.left, .right, .sideLeft, .sideRight]))
        #expect(!centerBack.contains(.center) && !centerBack.contains(.rearLeft))

        #expect(TrueHDObjectAudioDecoder.excludedSpeakers(zone: TRUEHD_ATMOS_ZONE_ALL).isEmpty)
    }

    @Test("a zone mask applied through the panner keeps the object's power on the allowed speakers")
    func zoneMaskThroughPanner() {
        let layout = SpatialSpeakerLayout.l714
        let excluded = TrueHDObjectAudioDecoder.excludedSpeakers(zone: TRUEHD_ATMOS_ZONE_NO_BACK)
        let panner = AllocentricPanner(layout: layout, excluded: excluded)
        var gains: [Float] = []
        panner.objectGains(position: SIMD3(0.1, 1, 0), size: 0, into: &gains)
        for (channel, speaker) in layout.speakers.enumerated() where excluded.contains(speaker) {
            #expect(gains[channel] == 0, "\(speaker)")
        }
        #expect(abs(gains.reduce(0) { $0 + $1 * $1 } - 1) < 1e-5)
    }

    #endif

    @Test("the decoder opens, takes input and asks for more")
    func decoderLifecycle() throws {
        let decoder = try TrueHDObjectAudioDecoder()
        let junk = [UInt8](repeating: 0x5A, count: 4096)
        try junk.withUnsafeBytes { try decoder.push($0) }
        #expect(try decoder.nextBlock() == nil)
        decoder.reset()
        #expect(try decoder.nextBlock() == nil)
    }
}
#endif
