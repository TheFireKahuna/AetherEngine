// Only with the TrueHDObjectAudio or DTSXObjectAudio trait (both off by default).
#if TrueHDObjectAudio || DTSXObjectAudio
import Foundation
import simd

/// Speaker gains for a position in the allocentric room cube (see `SpatialSpeaker`).
///
/// Dual-balance panning, the scheme ITU-R BS.2127 specifies for Cartesian ("allocentric") objects
/// and the one Atmos home renderers are built around: the room is a stack of speaker planes (floor,
/// ceiling), each plane a set of rows front to back, each row a set of speakers left to right.
/// A position is balanced between the two planes that bracket its height, then inside each plane
/// between the two rows that bracket its depth, then inside each row between the two speakers that
/// bracket its width. Every balance is constant-power, so the result always has unit power and an
/// object moving across the room never changes loudness.
///
/// Rows and planes are whatever the layout has: a 7.1.2 ceiling is one row, a 5.1 floor has no
/// side row, and a bed with no ceiling at all folds every height onto the floor, which is what a
/// renderer is supposed to do with height content it has nowhere to put.
struct AllocentricPanner: Sendable {

    let layout: SpatialSpeakerLayout
    private let planes: [Plane]
    private let channelCount: Int
    /// The size panner's per-axis gains at its virtual sources, and at the six room boundaries:
    /// they depend on the layout alone.
    private var sizeGridGains: (x: [[Double]], y: [[Double]], z: [[Double]]) = ([], [], [])
    private var sizeBoundaryGains: (front: [Double], back: [Double], left: [Double], right: [Double],
                                    floor: [Double], ceiling: [Double]) = ([], [], [], [], [], [])

    private struct Column: Sendable {
        let x: Float
        let channel: Int
    }

    private struct Row: Sendable {
        let y: Float
        let columns: [Column]  // sorted by x
    }

    private struct Plane: Sendable {
        let z: Float
        let rows: [Row]  // sorted by y
    }

    /// `excluded` removes speakers from consideration (object zone masks). A mask that removes
    /// every positional speaker is ignored, because silencing an object is never what it asks for.
    init(layout: SpatialSpeakerLayout, excluded: Set<SpatialSpeaker> = []) {
        self.layout = layout
        self.channelCount = layout.channelCount
        let usable = layout.speakers.enumerated().filter { !$0.element.isLFE }
        let kept = usable.filter { !excluded.contains($0.element) }
        let speakers = kept.isEmpty ? usable : kept

        var byZ: [Float: [Float: [(Float, Int)]]] = [:]
        for (channel, speaker) in speakers {
            let p = speaker.position
            byZ[p.z, default: [:]][p.y, default: []].append((p.x, channel))
        }
        planes = byZ.keys.sorted().map { z in
            let rows = byZ[z]!.keys.sorted().map { y in
                Row(y: y, columns: byZ[z]![y]!.sorted { $0.0 < $1.0 }.map { Column(x: $0.0, channel: $0.1) })
            }
            return Plane(z: z, rows: rows)
        }
        let grid = Self.sizeGrid
        sizeGridGains = (gridGains(axis: 0, count: grid.x), gridGains(axis: 1, count: grid.y),
                         gridGains(axis: 2, count: grid.z))
        sizeBoundaryGains = (axisGains(0, axis: 1), axisGains(1, axis: 1), axisGains(0, axis: 0),
                             axisGains(1, axis: 0), axisGains(0, axis: 2), axisGains(1, axis: 2))
    }

    // MARK: - Point source

    /// Unit-power gains for a point at `p`, written into `gains` (resized to the layout's channel
    /// count, LFE always 0). Coordinates outside the cube are clamped to it.
    func pointGains(_ p: SIMD3<Float>, into gains: inout [Float]) {
        if gains.count != channelCount { gains = [Float](repeating: 0, count: channelCount) }
        for i in gains.indices { gains[i] = 0 }
        accumulatePoint(clamp(p), weight: 1, into: &gains)
    }

    /// Adds `weight` × the point's gains to `gains`. Split out so extent sampling can accumulate
    /// power over many points without allocating.
    private func accumulatePoint(_ p: SIMD3<Float>, weight: Float, into gains: inout [Float]) {
        Self.balance(planes, value: p.z, key: \.z) { plane, planeGain in
            Self.balance(plane.rows, value: p.y, key: \.y) { row, rowGain in
                Self.balance(row.columns, value: p.x, key: \.x) { column, columnGain in
                    gains[column.channel] += weight * planeGain * rowGain * columnGain
                }
            }
        }
    }

    /// Constant-power balance of `value` between the two sorted elements that bracket it. Outside
    /// the range the nearest element takes everything.
    private static func balance<T>(
        _ items: [T], value: Float, key: KeyPath<T, Float>, _ body: (T, Float) -> Void
    ) {
        guard let first = items.first, let last = items.last else { return }
        if items.count == 1 || value <= first[keyPath: key] { body(first, 1); return }
        if value >= last[keyPath: key] { body(last, 1); return }
        var upper = 1
        while items[upper][keyPath: key] < value { upper += 1 }
        let a = items[upper - 1], b = items[upper]
        let lo = a[keyPath: key], hi = b[keyPath: key]
        let t = hi > lo ? (value - lo) / (hi - lo) : 0
        let angle = t * .pi / 2
        body(a, cos(angle))
        body(b, sin(angle))
    }

    // MARK: - Object

    /// Gains for an object: point panning; TS 103 448's size panner (5.2.3) for an object with size
    /// (0 for a point up to 1 for the whole room); or, with divergence, two points either side of it
    /// along x (5.2.4, pseudocode 15: size is then ignored). Unit power in every case.
    func objectGains(position: SIMD3<Float>, size: Float, divergence: Float = 0, into gains: inout [Float]) {
        if gains.count != channelCount { gains = [Float](repeating: 0, count: channelCount) }
        for i in gains.indices { gains[i] = 0 }
        let p = clamp(position)

        if divergence > 0 {
            // The two halves stay inside the room, and their amplitudes add before normalising.
            let spread = min(divergence, 1 - abs(p.x - 0.5) * 2)
            accumulatePoint(SIMD3(p.x + spread / 2, p.y, p.z), weight: 1, into: &gains)
            accumulatePoint(SIMD3(p.x - spread / 2, p.y, p.z), weight: 1, into: &gains)
            let norm = gains.reduce(0) { $0 + $1 * $1 }.squareRoot()
            if norm > 0 { for i in gains.indices { gains[i] /= norm } }
            return
        }
        guard size > 0 else {
            accumulatePoint(p, weight: 1, into: &gains)
            return
        }
        sizeGains(p, width: min(size, 1), into: &gains)
    }

    // MARK: - Size (TS 103 448 5.2.3)

    /// The per-axis panning of pseudocodes 4-6, per channel: each speaker's share of `value` along
    /// one axis, between the planes (z), the rows of its plane (y) or the columns of its row (x)
    /// that bracket it. Their product is the point panner.
    private func axisGains(_ value: Float, axis: Int) -> [Double] {
        var g = [Double](repeating: 0, count: channelCount)
        switch axis {
        case 2:
            Self.balance(planes, value: value, key: \.z) { plane, gain in
                for row in plane.rows { for column in row.columns { g[column.channel] = Double(gain) } }
            }
        case 1:
            for plane in planes {
                Self.balance(plane.rows, value: value, key: \.y) { row, gain in
                    for column in row.columns { g[column.channel] = Double(gain) }
                }
            }
        default:
            for plane in planes {
                for row in plane.rows {
                    Self.balance(row.columns, value: value, key: \.x) { column, gain in g[column.channel] = Double(gain) }
                }
            }
        }
        return g
    }

    /// Virtual source positions (the minimum counts the clause allows: N_x = N_y = 20, N_z = 8; the
    /// floor flr is 0, there being no 22.2 layout) and the per-axis gains at each.
    private static let sizeGrid = (x: 20, y: 20, z: 8)
    private func gridGains(axis: Int, count: Int) -> [[Double]] {
        (0..<count).map { axisGains(Float($0) / Float(count - 1), axis: axis) }
    }

    /// Pseudocodes 7-14: gains for an object of uniform `width` (object_width, 0...1) at `p`.
    private func sizeGains(_ p: SIMD3<Float>, width: Float, into gains: inout [Float]) {
        let (nx, ny, nz) = Self.sizeGrid
        let gX = sizeGridGains.x, gY = sizeGridGains.y, gZ = sizeGridGains.z
        let (x, y, z) = (Double(p.x), Double(p.y), Double(max(p.z, 0)))

        func sizeScale(_ v: Double) -> Double {                          // pseudocode 7
            if v < 1e-5 { return 0 }
            if v <= 0.2 { return 1.5 * v }
            if v <= 0.5 { return 7.0 / 3 * v - 1.0 / 6 }
            if v <= 0.75 { return 3.2 * v - 0.6 }
            return 4 * v - 1.2
        }
        func weight(_ a: Double, _ b: Double, _ c: Double) -> Double {   // pseudocode 8
            c > 0 ? pow(10, -pow(1.5 * (a - b) / c, 4)) : 0
        }
        func fade(_ position: Double, _ size: Double, _ minimum: Double) -> Double {   // pseudocode 13
            let t = min(position - minimum, 1 - position)
            return t < size || t < 0.2 ? t / max(0.2, size) : 1
        }
        func normalized(_ g: [Double]) -> [Double] {
            let total = g.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return g.map { $0 / max(1e-5, total) }
        }

        // One width for all three axes: Atmos sends object_width (5.2.3.2).
        let size = sizeScale(Double(width))
        let lbX = max(size, 2 / Double(nx - 1)), lbY = max(size, 2 / Double(ny - 1)), lbZ = max(size, 2 / Double(nz - 1))
        let wX = (0..<nx).map { weight(Double($0) / Double(nx - 1), x, lbX) }
        let wY = (0..<ny).map { weight(Double($0) / Double(ny - 1), y, lbY) }
        let wZ = (0..<nz).map { weight(Double($0) / Double(nz - 1), z, lbZ) }
        // Pseudocode 9, with x1 = x2 = x3 = size.
        let sizeEff = (2.0 / 3 + 2.0 / 9 + 1.0 / 9) * size
        let power = sizeEff > 0.5 ? 6 + (sizeEff - 0.5) * (-4 / 2.3) : 6

        // Pseudocode 10: the weighted per-axis sums, and the inside gains.
        var sumX = [Double](repeating: 0, count: channelCount)
        var sumY = sumX, sumZ = sumX
        for j in 0..<channelCount {
            for s in 0..<nx { sumX[j] += pow(gX[s][j] * wX[s], power) }
            for s in 0..<ny { sumY[j] += pow(gY[s][j] * wY[s], power) }
            for s in 0..<nz { sumZ[j] += pow(gZ[s][j] * wZ[s], power) }
        }
        let inside = normalized((0..<channelCount).map { pow(sumX[$0] * sumY[$0] * sumZ[$0], 1 / power) })

        // Pseudocode 11: the six room boundaries.
        let b = sizeBoundaryGains
        let bound = normalized((0..<channelCount).map { j in
            pow(b.floor[j] * weight(0, z, lbZ), power) * sumX[j] * sumY[j]
                + pow(b.ceiling[j] * weight(1, z, lbZ), power) * sumX[j] * sumY[j]
                + pow(b.left[j] * weight(0, x, lbX), power) * sumY[j] * sumZ[j]
                + pow(b.right[j] * weight(1, x, lbX), power) * sumY[j] * sumZ[j]
                + pow(b.front[j] * weight(0, y, lbY), power) * sumX[j] * sumZ[j]
                + pow(b.back[j] * weight(1, y, lbY), power) * sumX[j] * sumZ[j]
        })

        // Pseudocodes 12 and 14: inside faded out toward the walls, then blended with the point.
        let out = fade(x, lbX, 0) * fade(y, lbY, 0) * fade(z, lbZ, 0)
        let sized = normalized((0..<channelCount).map { pow(bound[$0] + out * inside[$0], 1 / power) })
        var point = [Float](repeating: 0, count: channelCount)
        accumulatePoint(p, weight: 1, into: &point)
        let (alpha, beta) = sizeEff < 0.2 ? (cos(sizeEff / 0.2 * .pi / 2), sin(sizeEff / 0.2 * .pi / 2)) : (0, 1)
        let blended = normalized((0..<channelCount).map { alpha * Double(point[$0]) + beta * sized[$0] })
        for j in 0..<channelCount { gains[j] = Float(blended[j]) }
    }

    private func clamp(_ p: SIMD3<Float>) -> SIMD3<Float> {
        simd_clamp(p, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }
}
#endif
