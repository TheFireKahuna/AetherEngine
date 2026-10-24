// The deinterlace card: one 1920x1080 grey picture per FIELD, written to stdout as raw 8-bit luma
// at 50 pictures a second. build_deint.sh weaves each pair into one 25i frame (the even picture
// becomes the top field), so every field shows a different moment and each region below fails
// in a way of its own.
//
//   rows  120-420  a white bar, 48 px wide, 24 px further right every field: combing on its
//                  edges means the picture was not deinterlaced
//   rows  480-660  static stripes two rows high, so each field carries the same fine one-row
//                  pattern: sharp and steady when the deinterlacer keeps still areas, soft or
//                  shimmering when it interpolates them. (One-row stripes would be no test: each
//                  field alone is then a solid tone, which every deinterlacer shows as a flicker.)
//   rows  720-1000 the field number in 7-segment digits, and a box stepping 80 px right every
//                  field: at field rate the number counts 0, 1, 2, 3 ... at 50 a second and the
//                  box glides; with the field order wrong the box steps back every other field
//                  and the numbers come out 1, 0, 3, 2 ...; at frame rate every other number
//
// Usage: deint_card <fields>    (swiftc -O deint_card.swift, then pipe into ffmpeg)

import Foundation

let width = 1920, height = 1080
let fields = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 3000
let background: UInt8 = 32, light: UInt8 = 235, dark: UInt8 = 16

var picture = [UInt8](repeating: background, count: width * height)

func fill(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ value: UInt8) {
    let xs = max(0, x0)..<min(width, x0 + w)
    guard !xs.isEmpty else { return }
    for y in max(0, y0)..<min(height, y0 + h) {
        let row = y * width
        for x in xs { picture[row + x] = value }
    }
}

// Segments a (top), b (top right), c (bottom right), d (bottom), e (bottom left), f (top left), g (middle).
let segments: [[Bool]] = [
    [true, true, true, true, true, true, false],      // 0
    [false, true, true, false, false, false, false],  // 1
    [true, true, false, true, true, false, true],     // 2
    [true, true, true, true, false, false, true],     // 3
    [false, true, true, false, false, true, true],    // 4
    [true, false, true, true, false, true, true],     // 5
    [true, false, true, true, true, true, true],      // 6
    [true, true, true, false, false, false, false],   // 7
    [true, true, true, true, true, true, true],       // 8
    [true, true, true, true, false, true, true],      // 9
]

func digit(_ d: Int, x: Int, y: Int) {
    let w = 140, h = 240, t = 28, half = h / 2
    let on = segments[d]
    if on[0] { fill(x, y, w, t, light) }
    if on[1] { fill(x + w - t, y, t, half, light) }
    if on[2] { fill(x + w - t, y + half, t, half, light) }
    if on[3] { fill(x, y + h - t, w, t, light) }
    if on[4] { fill(x, y + half, t, half, light) }
    if on[5] { fill(x, y, t, half, light) }
    if on[6] { fill(x, y + half - t / 2, w, t, light) }
}

let out = FileHandle.standardOutput
for n in 0..<fields {
    picture.withUnsafeMutableBufferPointer { $0.update(repeating: background) }
    // The bar, wrapping at the right edge.
    fill((n * 24) % width, 120, 48, 300, light)
    // Static stripes: the same picture in every field.
    for y in 480..<660 { fill(120, y, 1680, 1, (y / 2) % 2 == 0 ? light : dark) }
    // The field number, four digits.
    var value = n % 10000
    for i in (0..<4).reversed() {
        digit(value % 10, x: 120 + i * 180, y: 740)
        value /= 10
    }
    // The stepping box: eight positions, one per field.
    fill(1100 + (n % 8) * 80, 800, 80, 80, light)
    picture.withUnsafeBytes { out.write(Data($0)) }
}
