// Only with the TrueHDObjectAudio trait (off by default): the decimator is not built without it.
#if TrueHDObjectAudio
import Testing
import Foundation
@testable import AetherEngine

/// TrueHD Atmos at 96 or 192 kHz is decimated to the 48 kHz the renderer and APAC run at. What a
/// listener would hear wrong: a level or timing shift, anything above 24 kHz folding back into the
/// audible band, metadata landing on the wrong frame, a click where blocks meet.
@Suite("Object audio at 96 and 192 kHz comes down to 48 kHz")
struct ObjectAudioDecimatorTests {

    /// `seconds` of a sine at `hz`, at `rate`, fed in access units (`rate / 1200` frames) through a
    /// decimator; the output, joined, with each block's start frame.
    private func run(hz: Double, rate: Int, frames: Int, updates: [Int: ObjectAudioMetadataUpdate] = [:])
        -> (out: [Float], blocks: [(start: Int64, frames: Int)], updates: [(Int64, ObjectAudioMetadataUpdate)]) {
        let decimator = ObjectAudioDecimator(factor: ObjectAudioDecimator.factor(from: rate)!)
        let au = rate / 1200
        var out: [Float] = []
        var blocks: [(start: Int64, frames: Int)] = []
        var placed: [(Int64, ObjectAudioMetadataUpdate)] = []
        var input = [Float](repeating: 0, count: au)
        for start in stride(from: 0, to: frames, by: au) {
            for i in 0..<au { input[i] = Float(sin(2 * .pi * hz * Double(start + i) / Double(rate))) }
            let inside = updates.filter { $0.key >= start && $0.key < start + au }
                .map { u -> ObjectAudioMetadataUpdate in var v = u.value; v.frameOffset = u.key - start; return v }
            let result = input.withUnsafeBufferPointer { buffer in
                decimator.process(planes: [buffer.baseAddress!], frames: au, inputStart: Int64(start), updates: inside)
            }
            if result.frames > 0 { blocks.append((result.start, result.frames)) }
            for u in result.updates { placed.append((result.start + Int64(u.frameOffset), u)) }
            out += UnsafeBufferPointer(start: result.planes[0], count: result.frames)
        }
        return (out, blocks, placed)
    }

    @Test("a tone in the audible band keeps its level and its timing, frame n being input frame n x factor",
          arguments: [96_000, 192_000])
    func passband(rate: Int) {
        for hz in [1_000.0, 19_000.0] {
            let (out, blocks, _) = run(hz: hz, rate: rate, frames: rate / 10)
            #expect(blocks.first?.start == 0)
            // After the first look-ahead, every output frame is the tone at its own time at 48 kHz.
            let error = (500..<out.count).map { n in abs(Double(out[n]) - sin(2 * .pi * hz * Double(n) / 48_000)) }.max()!
            #expect(error < 0.002, "\(hz) Hz at \(rate): largest error \(error)")
        }
    }

    @Test("what would fold below 20 kHz is gone", arguments: [96_000, 192_000])
    func stopband(rate: Int) {
        for hz in [28_000.0, 40_000.0] + (rate > 96_000 ? [70_000.0, 90_000.0] : []) {
            let (out, _, _) = run(hz: hz, rate: rate, frames: rate / 10)
            let rms = (Array(out[500...]).reduce(0) { $0 + Double($1 * $1) } / Double(out.count - 500)).squareRoot()
            #expect(20 * log10(max(rms, 1e-12) / 0.7071) < -100, "\(hz) Hz at \(rate): \(20 * log10(rms / 0.7071)) dB")
        }
    }

    @Test("blocks join without a seam: the output is one continuous stream", arguments: [96_000, 192_000])
    func continuity(rate: Int) {
        let (out, blocks, _) = run(hz: 997, rate: rate, frames: rate / 20)
        var expected: Int64 = 0
        for block in blocks { #expect(block.start == expected); expected += Int64(block.frames) }
        #expect(blocks.count > 2 && Int64(out.count) == expected)
        // The look-ahead holds back the same frames from every block: the first gives up that many.
        #expect(blocks.first?.frames == 40 - ObjectAudioDecimator.delay)
        #expect(blocks.dropFirst().allSatisfy { $0.frames == 40 })
    }

    @Test("an update lands on the output frame of its input frame, its ramp scaled, in whichever block holds it",
          arguments: [96_000, 192_000])
    func metadata(rate: Int) {
        let factor = rate / 48_000
        let at = [70 * factor, 1_000 * factor + factor - 1]
        let updates = Dictionary(uniqueKeysWithValues: at.map {
            ($0, ObjectAudioMetadataUpdate(frameOffset: 0, rampFrames: 512 * factor, states: [nil]))
        })
        let (_, _, placed) = run(hz: 1_000, rate: rate, frames: rate / 20, updates: updates)
        #expect(placed.map(\.0) == [70, 1_000])
        #expect(placed.allSatisfy { $0.1.rampFrames == 512 })
    }

    @Test("only 96 and 192 kHz are decimated")
    func factors() {
        #expect(ObjectAudioDecimator.factor(from: 96_000) == 2)
        #expect(ObjectAudioDecimator.factor(from: 192_000) == 4)
        #expect(ObjectAudioDecimator.factor(from: 48_000) == nil)
        #expect(ObjectAudioDecimator.factor(from: 88_200) == nil)
    }
}
#endif
