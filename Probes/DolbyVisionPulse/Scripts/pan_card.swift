// The film pan card: one 1920x1080 grey picture per FILM frame, written to stdout as raw 8-bit luma. A pattern pans
// right at a constant 12 px per film frame, the motion where film cadence errors show:
//
//   rows 80-500    tall white bars of varied widths: smooth at the film rate, a rhythmic 2-3 stutter when film
//                  plays on a 59.94 / 29.97 timeline, a doubled or skipped step when a frame repeats or is lost
//   rows 520-560   two static white lines: stay perfectly still (reference)
//   rows 580-1000  fine 2 px ruler ticks, every 10th long: comb teeth on their edges mean interlaced fields
//                  were woven from different film frames; a shimmer or softness means they were interpolated
//
// Usage: pan_card <frames>    (swiftc -O pan_card.swift, then pipe into ffmpeg)

import Foundation

let width = 1920, height = 1080
let frames = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 960
let speed = 12
let background: UInt8 = 24, light: UInt8 = 235, mid: UInt8 = 140

var picture = [UInt8](repeating: background, count: width * height)

func fillRows(_ y0: Int, _ y1: Int, _ value: (Int) -> UInt8) {
    for x in 0..<width {
        let v = value(x)
        for y in y0..<y1 { picture[y * width + x] = v }
    }
}

// The bar pattern repeats every 480 px: bars of 8, 24, 48 and 96 px with gaps between.
func bar(_ u: Int) -> Bool {
    let p = ((u % 480) + 480) % 480
    return (p >= 20 && p < 28) || (p >= 80 && p < 104) || (p >= 170 && p < 218) || (p >= 300 && p < 396)
}

let out = FileHandle.standardOutput
for n in 0..<frames {
    picture.withUnsafeMutableBufferPointer { $0.update(repeating: background) }
    let shift = n * speed
    fillRows(80, 500) { bar($0 - shift) ? light : background }
    fillRows(520, 524) { _ in light }
    fillRows(556, 560) { _ in light }
    fillRows(580, 1000) { x in
        let u = ((x - shift) % 40 + 40) % 40
        return u < 2 ? light : background
    }
    fillRows(580, 660) { x in
        let u = ((x - shift) % 400 + 400) % 400
        return u < 4 ? mid : picture[600 * width + x]
    }
    picture.withUnsafeBytes { out.write(Data($0)) }
}
