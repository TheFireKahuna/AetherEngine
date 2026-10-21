// Only with the TrueHDObjectAudio or DTSXObjectAudio trait (both off by default).
#if TrueHDObjectAudio || DTSXObjectAudio
import Accelerate
import Foundation

/// What one signal in an object-audio presentation is.
enum ObjectAudioRole: Sendable, Equatable {
    /// A bed channel at a fixed speaker position: on its speaker where the layout has it, and where
    /// it does not, folded onto the speakers TS 103 448 table 6 names (a 7.1.2 bed's top-middle pair
    /// on a 5.1.4 layout: half the power to each top on its side).
    case bed(SpatialSpeaker)
    /// A bed channel at a fixed position the room model names no speaker for (screen, centre back,
    /// top centre). Rendered as a phantom from the moment the renderer exists, like a bed channel the
    /// layout lacks, so it plays in a presentation that never sends metadata.
    case fixed(SIMD3<Float>)
    /// The low-frequency effects channel. Routed to the layout's LFE, never panned.
    case lfe
    /// A dynamic object, positioned by metadata.
    case object
}

/// One element's rendering parameters as of a metadata update.
struct ObjectAudioElementState: Sendable, Equatable {
    /// Allocentric position (see `SpatialSpeaker`). Ignored for beds and LFE.
    var position: SIMD3<Float> = SIMD3(0.5, 0.5, 0)
    /// Linear gain.
    var gain: Float = 1
    /// 0 = point source, 1 = whole room.
    var size: Float = 0
    /// Atmos divergence (TS 103 448 5.2.4): 0 = one source; more splits it into two, spread along x.
    var divergence: Float = 0
    /// Speakers the object must not use (Atmos zone masks, and the heights when `elevation` is off).
    var excluded: Set<SpatialSpeaker> = []
    /// b_enable_elevation. Off, the object keeps off the height speakers and, on a layout that has
    /// them, is rendered at ear level (TS 103 448 5.1.3.2: only the layouts of its table 5).
    var elevation = true
    /// How the object is trimmed on smaller layouts (TS 103 448 5.3); nil = not at all.
    var trim: ObjectAudioTrim?
}

/// TS 103 448 5.3: the level of an object positioned in the room, lowered on layouts with fewer
/// speakers than the mix had, by default (pseudocode 16) or by the trims the stream sends
/// (pseudocode 17).
struct ObjectAudioTrim: Sendable, Equatable {
    enum Mode: Sendable, Equatable {
        case `default`, disabled
        /// The trims in dB, and the front/back balances (TS 103 420 5.6.5.9-12), -1...1 with
        /// negative towards the front: in the top and bottom planes and in the listener plane.
        case custom(centre: Float, surround: Float, height: Float, balanceTop: Float = 0, balanceListener: Float = 0)
    }

    /// Indexed by trim_cfg (TS 103 448 table 7).
    var configs: [Mode]

    static let defaults = ObjectAudioTrim(configs: Array(repeating: .default, count: 9))

    /// trim_gain, linear, for an object at `p` rendered to `layout`.
    func gain(at p: SIMD3<Float>, on layout: SpatialSpeakerLayout) -> Float {
        let (mid, top) = (layout.trimMidCount, layout.trimTopCount)
        let row = mid >= 4 ? 2 : (mid >= 2 ? 1 : 0)
        let column = top > 2 ? 2 : (top > 0 ? 1 : 0)
        func clamp(_ v: Float) -> Float { min(max(v, 0), 1) }
        let db: Float
        switch configs[3 * column + row] {
        case .disabled:
            return 1
        case .default:
            let maxTrim = min(0, -4.5 + 3 * min(1, Float(mid) / 4) + 1.5 * min(1, Float(top) / 4))
            let gY = clamp(p.y / 0.6)
            let gZ = clamp((abs(p.z) - 0.2) / 0.8)
            db = maxTrim * clamp(gY + gZ)
        case .custom(let centre, let surround, let height, let balanceTop, let balanceListener):
            db = height * abs(p.z) + (p.y >= 0.5 ? surround : surround * 2 * p.y)
                + (layout == .l20 ? Self.centreWeight(p) * centre : 0)
            return powf(10, db / 20) * Self.balanceGain(at: p, top: balanceTop, listener: balanceListener)
        }
        return powf(10, db / 20)
    }

    /// The front/back balance of a custom trim. TS 103 420 gives each plane's balance (table 33:
    /// only with custom_trim) but no renderer specifies how to apply it, so it is applied as a
    /// fader: a balance b towards the back lowers an object at the front wall to 1 - b of its level
    /// and one at the back wall not at all, linearly in between, and the other way round towards the
    /// front. The listener plane's balance holds at ear level, the top and bottom planes' at the
    /// ceiling and floor, and between them they mix by height.
    static func balanceGain(at p: SIMD3<Float>, top: Float, listener: Float) -> Float {
        let w = min(abs(p.z), 1)
        let b = min(max(listener + (top - listener) * w, -1), 1)
        let y = min(max(p.y, 0), 1)
        return b >= 0 ? 1 - b * (1 - y) : 1 + b * y
    }

    /// Pseudocode 17's trim_C weight on a 2.0 layout: 1 for an object at the front centre, falling
    /// to 0 over 0.1 of the room beyond 0.05 of it in any direction.
    static func centreWeight(_ p: SIMD3<Float>) -> Float {
        let (siz, tran): (Float, Float) = (0.05, 0.1)
        let reach = max(max(abs(p.x - 0.5) - siz, p.y - siz), abs(p.z) - siz)
        return 1 - min(max(reach / tran, 0), 1)
    }
}

/// A metadata change taking effect partway through a block.
struct ObjectAudioMetadataUpdate: Sendable {
    /// Frame within the block at which the ramp towards the new state starts.
    var frameOffset: Int
    /// The update's ramp_duration: gains move from their current values to the new ones over this
    /// many frames plus the update's own (TS 103 448 5.5). 0 jumps.
    var rampFrames: Int
    /// One entry per element, indexed like `ObjectAudioRenderer.roles`. Nil leaves that element
    /// alone, ramp included. Atmos restarts every element's ramp at every update, restated values
    /// included (TS 103 448 pseudocode 19), so its decoder sends every element.
    var states: [ObjectAudioElementState?]
}

/// Element gains and positions as `ObjectAudioRenderer.snapshot` reads them, reused across blocks.
struct ObjectAudioGainSnapshot {
    var layoutGains: [Float] = []
    var positions: [SIMD3<Float>?] = []
    var gains: [Float] = []

    mutating func resize(elements: Int, channels: Int) {
        if layoutGains.count != elements * channels { layoutGains = [Float](repeating: 0, count: elements * channels) }
        if positions.count != elements {
            positions = Array(repeating: nil, count: elements)
            gains = [Float](repeating: 0, count: elements)
        }
    }
}

/// Renders object audio (beds + dynamic objects + metadata) into a `SpatialSpeakerLayout` bed.
///
/// Gains are computed once per metadata update and interpolated linearly across each update's
/// ramp, the way object metadata is defined to be applied. Between updates every element is a
/// constant gain per output channel, which is a single multiply-add over the block.
final class ObjectAudioRenderer {

    let layout: SpatialSpeakerLayout
    private(set) var roles: [ObjectAudioRole]

    private var panners: [Set<SpatialSpeaker>: AllocentricPanner] = [:]
    /// Whether the bed has the back pair, which sets table 6's gain g (TS 103 448 5.2.5.2).
    private let bedHasBacks: Bool

    /// Per element, per output channel: the gains currently applied, the gains being ramped
    /// towards, and how many frames of that ramp remain.
    private var current: [[Float]]
    private var target: [[Float]]
    private var rampRemaining: [Int]
    private var rampTotal: [Int]
    /// Whether the element has had metadata since the renderer was built or reset. Its first
    /// update is applied as a jump whatever its ramp says: there is no earlier position to ramp
    /// from, and ramping from silence would fade every object in after each seek.
    private var hasMetadata: [Bool]

    /// Each object's latest state, for `snapshot`.
    private var objectStates: [ObjectAudioElementState?]

    private var scratch: [Float] = []
    private var rampScratch: [Float] = []

    init(layout: SpatialSpeakerLayout, roles: [ObjectAudioRole]) {
        self.layout = layout
        self.roles = roles
        bedHasBacks = Self.bedHasBacks(roles)
        let channels = layout.channelCount
        current = Array(repeating: [Float](repeating: 0, count: channels), count: roles.count)
        target = current
        rampRemaining = Array(repeating: 0, count: roles.count)
        rampTotal = rampRemaining
        hasMetadata = Array(repeating: false, count: roles.count)
        objectStates = Array(repeating: nil, count: roles.count)
        // Beds and LFE have gains the moment the renderer exists; objects wait for metadata and are
        // silent until their first update, rather than guessing at a position. The TrueHD decoder
        // holds the blocks before that update and gives the first of them its state at frame 0
        // (`ObjectMetadataHold`), so after a reset that wait costs nothing audible.
        for (index, role) in roles.enumerated() where role != .object {
            staticGains(for: role, state: ObjectAudioElementState(), into: &current[index])
            target[index] = current[index]
        }
    }

    /// Forget every ramp and object position: the next block starts from the same state a freshly
    /// built renderer would (seeks, producer restarts).
    func reset() {
        for index in roles.indices {
            rampRemaining[index] = 0
            hasMetadata[index] = false
            objectStates[index] = nil
            if roles[index] == .object {
                for c in current[index].indices { current[index][c] = 0 }
            } else {
                // A bed fade cut off by the reset would otherwise stay at the ramp's origin.
                staticGains(for: roles[index], state: ObjectAudioElementState(), into: &current[index])
            }
            target[index] = current[index]
        }
    }

    /// The source skipped audio (a damaged span the decoder resynchronised over). Objects hold where
    /// they are, any ramp stops where it has got to, and each element's next metadata is applied as
    /// a jump: it describes the far side of the gap, and sweeping there from the near side would be
    /// audible motion the programme never had.
    func markDiscontinuity() {
        for index in roles.indices {
            if rampRemaining[index] > 0 {
                let t = Float(rampTotal[index] - rampRemaining[index]) / Float(rampTotal[index])
                for c in current[index].indices {
                    current[index][c] += (target[index][c] - current[index][c]) * t
                }
                target[index] = current[index]
                rampRemaining[index] = 0
            }
            hasMetadata[index] = false
        }
    }

    /// Render `frameCount` frames of `inputs` (one plane per role) into `outputs` (one plane per
    /// layout channel, overwritten). `updates` must be sorted by `frameOffset`.
    func render(
        inputs: [UnsafePointer<Float>],
        frameCount: Int,
        updates: [ObjectAudioMetadataUpdate],
        outputs: [UnsafeMutablePointer<Float>]
    ) {
        for out in outputs { vDSP_vclr(out, 1, vDSP_Length(frameCount)) }
        // A block from a configuration this renderer was not built for renders as silence rather than
        // trapping: the bridge rebuilds on `configurationGeneration`, and a mismatch here is a stream
        // that changed shape without saying so.
        guard inputs.count == roles.count, outputs.count == layout.channelCount else { return }

        var cursor = 0
        var pending = updates[...]
        while cursor < frameCount {
            while let next = pending.first, next.frameOffset <= cursor {
                apply(next)
                pending = pending.dropFirst()
            }
            // Every update at or before `cursor` has been applied, so the next one is strictly later.
            let end = min(frameCount, pending.first?.frameOffset ?? frameCount)
            mix(inputs: inputs, from: cursor, count: end - cursor, outputs: outputs)
            cursor = end
        }
        // Updates stamped at or past the end of the block still take effect, for the next block.
        for update in pending { apply(update) }
    }

    /// Take `frameCount` frames of metadata and ramps forward without mixing any audio: what
    /// `render` does to the gains, for a caller that reads them through `snapshot` instead.
    func advance(frameCount: Int, updates: [ObjectAudioMetadataUpdate]) {
        var cursor = 0
        var pending = updates[...]
        while cursor < frameCount {
            while let next = pending.first, next.frameOffset <= cursor {
                apply(next)
                pending = pending.dropFirst()
            }
            let end = min(frameCount, pending.first?.frameOffset ?? frameCount)
            for index in roles.indices where rampRemaining[index] > 0 {
                rampRemaining[index] -= min(rampRemaining[index], end - cursor)
                if rampRemaining[index] == 0 { current[index] = target[index] }
            }
            cursor = end
        }
        for update in pending { apply(update) }
    }

    /// Every element's gains towards the layout as they stand now (mid-ramp included), and where
    /// it sits: `layoutGains` holds `roles.count` rows of `layout.channelCount`; `positions` is nil
    /// for the LFE and for an object without metadata yet; `gains` is the element gain.
    func snapshot(into snapshot: inout ObjectAudioGainSnapshot) {
        let channels = layout.channelCount
        snapshot.resize(elements: roles.count, channels: channels)
        for index in roles.indices {
            let row = index * channels
            if rampRemaining[index] > 0 {
                let t = Float(rampTotal[index] - rampRemaining[index]) / Float(rampTotal[index])
                for c in 0..<channels {
                    snapshot.layoutGains[row + c] = current[index][c] + (target[index][c] - current[index][c]) * t
                }
            } else {
                for c in 0..<channels { snapshot.layoutGains[row + c] = current[index][c] }
            }
            switch roles[index] {
            case .object:
                snapshot.positions[index] = objectStates[index]?.position
                snapshot.gains[index] = objectStates[index]?.gain ?? 0
            case .bed(let speaker):
                snapshot.positions[index] = speaker.position
                snapshot.gains[index] = 1
            case .fixed(let position):
                snapshot.positions[index] = position
                snapshot.gains[index] = 1
            case .lfe:
                snapshot.positions[index] = nil
                snapshot.gains[index] = 0
            }
        }
    }

    // MARK: - Metadata

    private func apply(_ update: ObjectAudioMetadataUpdate) {
        let count = min(update.states.count, roles.count)
        for index in 0..<count {
            guard let state = update.states[index] else { continue }
            if roles[index] == .object { objectStates[index] = state }
            let jump = update.rampFrames <= 0 || !hasMetadata[index]
            hasMetadata[index] = true
            var gains = [Float](repeating: 0, count: layout.channelCount)
            switch roles[index] {
            case .object:
                let position = Self.renderPosition(state, on: layout)
                panner(excluding: state.excluded).objectGains(
                    position: position, size: state.size, divergence: state.divergence, into: &gains)
                let gain = state.gain * (state.trim?.gain(at: position, on: layout) ?? 1)
                if gain != 1 { for c in gains.indices { gains[c] *= gain } }
            case .bed, .lfe, .fixed:
                staticGains(for: roles[index], state: state, into: &gains)
            }
            // A ramp still in flight restarts from where it has got to, not from its origin.
            if rampRemaining[index] > 0, !jump {
                let t = Float(rampTotal[index] - rampRemaining[index]) / Float(rampTotal[index])
                for c in gains.indices {
                    current[index][c] += (target[index][c] - current[index][c]) * t
                }
            }
            target[index] = gains
            if !jump {
                // TS 103 448 pseudocode 19: ramp_duration + 1 steps of (target - current) / (ramp_duration + 1),
                // the first on the update's own frame.
                rampRemaining[index] = update.rampFrames + 1
                rampTotal[index] = update.rampFrames + 1
            } else {
                current[index] = gains
                rampRemaining[index] = 0
            }
        }
    }

    private func staticGains(for role: ObjectAudioRole, state: ObjectAudioElementState, into gains: inout [Float]) {
        if gains.count != layout.channelCount { gains = [Float](repeating: 0, count: layout.channelCount) }
        switch role {
        case .lfe:
            for c in gains.indices { gains[c] = 0 }
            gains[layout.lfeIndex] = state.gain
        case .bed(let speaker):
            if let routes = Self.speakerAnchoredRoutes(speaker, in: layout, bedHasBacks: bedHasBacks) {
                for c in gains.indices { gains[c] = 0 }
                for route in routes { gains[route.channel] += route.gain * state.gain }
            } else {
                panner(excluding: []).pointGains(speaker.position, into: &gains)
                if state.gain != 1 { for c in gains.indices { gains[c] *= state.gain } }
            }
        case .fixed(let position):
            panner(excluding: []).pointGains(position, into: &gains)
            if state.gain != 1 { for c in gains.indices { gains[c] *= state.gain } }
        case .object:
            break
        }
    }

    /// Where an object is panned and trimmed from on `layout`: at ear level with its elevation off,
    /// on a layout with height speakers (TS 103 448 5.1.3.2, table 5). Without them it keeps its
    /// height, which the default trim lowers it by.
    static func renderPosition(_ state: ObjectAudioElementState, on layout: SpatialSpeakerLayout) -> SIMD3<Float> {
        var p = state.position
        if !state.elevation, layout.isBed { p.z = 0 }
        return p
    }

    static func bedHasBacks(_ roles: [ObjectAudioRole]) -> Bool {
        roles.contains(.bed(.rearLeft)) && roles.contains(.bed(.rearRight))
    }

    /// TS 103 448 table 6: the output channels and gains a speaker-anchored bed channel goes to on
    /// the layouts of its table A.1, the ones the layout has at gain 1 and the others folded onto
    /// the speakers it names. Nil for a layout the table has no column for (9.1.6, which has every
    /// channel the table has a row for) and for a channel it has no row for (those are panned).
    /// `bedHasBacks` is its g: m when the bed has the back pair, else 1.
    static func speakerAnchoredRoutes(_ speaker: SpatialSpeaker, in layout: SpatialSpeakerLayout,
                                      bedHasBacks: Bool) -> [(channel: Int, gain: Float)]? {
        let config: Int
        switch layout {
        case .l20: config = 0
        case .l51: config = 1
        case .l71: config = 2
        case .l714: config = 3
        case .l712: config = 4
        case .l514: config = 5
        case .l512: config = 6
        case .l916: return layout.speakers.firstIndex(of: speaker).map { [(channel: $0, gain: Float(1))] }
        }
        let right = speaker.isRight
        let left = right ? speaker.mirrored : speaker
        let m = Float(0.5).squareRoot(), g: Float = bedHasBacks ? m : 1
        // Table A.3 to A.8 put a 5.1-style surround or a 7.1 side at the layout's index 3.
        let surround: SpatialSpeaker = layout.speakers.contains(.sideLeft) ? .sideLeft : .surroundLeft
        let routes: [(SpatialSpeaker, Float)]
        switch left {
        case .left: routes = [(.left, 1)]
        case .center: routes = config == 0 ? [(.left, m), (.right, m)] : [(.center, 1)]
        case .sideLeft, .surroundLeft:
            switch config {
            case 0: routes = [(.left, g * m)]
            case 1, 5, 6: routes = [(surround, g)]
            default: routes = [(surround, 1)]
            }
        case .rearLeft:
            switch config {
            case 0: routes = [(.left, 0.5)]
            case 1, 5, 6: routes = [(surround, m)]
            default: routes = [(.rearLeft, 1)]
            }
        case .topFrontLeft, .topMiddleLeft, .topRearLeft:
            switch (left, config) {
            case (_, 0): routes = [(.left, 0.5)]
            case (_, 1), (_, 2): routes = [(surround, m)]
            case (.topMiddleLeft, 3), (.topMiddleLeft, 5): routes = [(.topFrontLeft, m), (.topRearLeft, m)]
            case (_, 3), (_, 5): routes = [(left, 1)]
            case (.topMiddleLeft, _): routes = [(.topMiddleLeft, 1)]
            default: routes = [(.topMiddleLeft, m)]
            }
        case .wideLeft: routes = [(.left, config == 0 ? 0.5 : m)]
        default: return nil
        }
        var out: [(channel: Int, gain: Float)] = []
        for (target, gain) in routes {
            // Mirrored, the centre's pair stays a pair.
            let t = right && target != .center ? target.mirrored : target
            guard let channel = layout.speakers.firstIndex(of: t) else { return nil }
            out.append((channel, gain))
        }
        return out
    }

    private func panner(excluding excluded: Set<SpatialSpeaker>) -> AllocentricPanner {
        if let cached = panners[excluded] { return cached }
        let built = AllocentricPanner(layout: layout, excluded: excluded)
        panners[excluded] = built
        return built
    }

    // MARK: - Mixing

    private func mix(
        inputs: [UnsafePointer<Float>], from start: Int, count: Int, outputs: [UnsafeMutablePointer<Float>]
    ) {
        let n = vDSP_Length(count)
        for index in roles.indices {
            let input = inputs[index] + start
            let ramp = min(rampRemaining[index], count)
            if ramp > 0 {
                if rampScratch.count < count { rampScratch = [Float](repeating: 0, count: count) }
                let total = Float(rampTotal[index])
                let done = Float(rampTotal[index] - rampRemaining[index])
                for c in 0..<layout.channelCount {
                    let from = current[index][c], to = target[index][c]
                    if from == 0 && to == 0 { continue }
                    // Linear per-frame gain: frame i of the ramp (0-based) plays at (i + 1) / total of
                    // the way, so the ramp's last frame lands exactly on the target. Constant after it.
                    var startGain = from + (to - from) * ((done + 1) / total)
                    var step = (to - from) / total
                    let g1 = from + (to - from) * ((done + Float(ramp)) / total)
                    rampScratch.withUnsafeMutableBufferPointer { buf in
                        vDSP_vramp(&startGain, &step, buf.baseAddress!, 1, vDSP_Length(ramp))
                        vDSP_vma(input, 1, buf.baseAddress!, 1, outputs[c] + start, 1, outputs[c] + start, 1,
                                 vDSP_Length(ramp))
                    }
                    if ramp < count {
                        var hold = g1
                        vDSP_vsma(input + ramp, 1, &hold, outputs[c] + start + ramp, 1,
                                  outputs[c] + start + ramp, 1, vDSP_Length(count - ramp))
                    }
                }
                // `current` stays the ramp's origin until it completes; progress lives in rampRemaining.
                rampRemaining[index] -= ramp
                if rampRemaining[index] == 0 { current[index] = target[index] }
            } else {
                for c in 0..<layout.channelCount {
                    var g = current[index][c]
                    if g == 0 { continue }
                    vDSP_vsma(input, 1, &g, outputs[c] + start, 1, outputs[c] + start, 1, n)
                }
            }
        }
    }
}
#endif
