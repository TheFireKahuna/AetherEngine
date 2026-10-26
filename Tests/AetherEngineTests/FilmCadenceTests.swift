import CoreMedia
import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Soft telecine (docs/software-route-gpu.md 6.1): pictures whose `repeat_pict` alternates 1, 0 (H.262
/// `repeat_first_field` in an interlaced sequence, H.264 `pic_struct` 5 / 6 then 3 / 4, VC-1 `RFF`) or 2, 4 (a
/// progressive sequence) are film at 4/5 of the carriage rate, and play on the film rate's uniform grid.
struct FilmCadenceTests {

    private static let ntsc = AVRational(num: 30000, den: 1001)
    private static let tb90k = AVRational(num: 1, den: 90000)

    /// Feeds (pts, repeat_pict, interlaced) and returns the timestamps out.
    private static func run(_ pictures: [(Int64, Int32, Bool)], carriage: AVRational = ntsc,
                            filmCoded: Bool = false) -> [Int64] {
        let cadence = FilmCadence(timeBase: tb90k, filmCoded: filmCoded)
        return pictures.map { cadence.retime(pts: $0.0, interlaced: $0.2, repeatPict: $0.1, carriage: carriage) }
    }

    /// The field timeline of 3:2 soft telecine at 29.97: 3 fields (4504.5 ticks), then 2 (3003), as H.262 displays it.
    private static func fieldTimeline(_ count: Int, start: Int64 = 0) -> [(Int64, Int32, Bool)] {
        var fields = 0
        return (0..<count).map { n in
            let repeatPict: Int32 = n % 2 == 0 ? 1 : 0
            defer { fields += 2 + Int(repeatPict) }
            return (start + Int64((Double(fields) * 1501.5).rounded()), repeatPict, false)
        }
    }

    /// One film period at 23.976 is 3753.75 ticks; slot n of a grid anchored at `anchor`.
    private static func slot(_ n: Int, anchor: Int64 = 0) -> Int64 { anchor + Int64((Double(n) * 3753.75).rounded()) }

    @Test("a 3:2 field timeline plays on the 23.976 grid once the cadence is confirmed")
    func softTelecineToFilmGrid() {
        let input = Self.fieldTimeline(20, start: 130505)
        let out = Self.run(input)
        // The pictures that confirm the run keep their own timestamps; from the fourth on, the grid.
        #expect(Array(out.prefix(3)) == input.prefix(3).map(\.0))
        for n in 3..<out.count { #expect(out[n] == Self.slot(n, anchor: 130505), "picture \(n)") }
    }

    @Test("a stream the load found to be film is on the grid from its first picture, whichever field it starts on")
    func filmCodedFromTheFirstPicture() {
        for skip in 0..<4 {
            let input = Array(Self.fieldTimeline(20 + skip, start: 130505).dropFirst(skip))
            let out = Self.run(input, filmCoded: true)
            let anchor = input[0].0
            for n in 0..<out.count {
                #expect(out[n] == anchor + Self.slot(n), "starting \(skip) pictures in, picture \(n)")
                #expect(abs(out[n] - input[n].0) <= 751, "within half a field of the field timeline, picture \(n)")
            }
        }
    }

    @Test("a stream the load found to be film still ends a run on a picture that breaks it, and starts the next there")
    func filmCodedBreak() {
        var input = Self.fieldTimeline(12)
        for n in 6..<12 { input[n].0 += 90000 }
        let out = Self.run(input, filmCoded: true)
        for n in 0..<6 { #expect(out[n] == Self.slot(n)) }
        for n in 6..<12 { #expect(out[n] == input[6].0 + Self.slot(n - 6), "picture \(n)") }
    }

    @Test("x264's pulldown timestamps (0, 4, 6, 8 fields in a cycle) are still the film run")
    func x264Timestamps() {
        // A cycle of 10 fields with the pictures at 0, 4, 6 and 8 fields; repeat_pict 1, 0, 1, 0.
        let input: [(Int64, Int32, Bool)] = (0..<16).map { n in
            let cycle = Int64(n / 4) * 15015, inCycle: [Int64] = [0, 6006, 9009, 12012]
            return (cycle + inCycle[n % 4], n % 2 == 0 ? 1 : 0, false)
        }
        let out = Self.run(input)
        for n in 3..<out.count { #expect(out[n] == Self.slot(n), "picture \(n)") }
    }

    @Test("an interlaced picture ends the run, and the cadence is found again after it")
    func interlacedBreaksRun() {
        var input = Self.fieldTimeline(20)
        input[8].2 = true
        let out = Self.run(input)
        for n in 3..<8 { #expect(out[n] == Self.slot(n)) }
        #expect(out[8] == input[8].0, "the interlaced picture keeps its own timestamp")
        // Four more pictures confirm a new run, anchored at the first of them.
        #expect(Array(out[9..<12]) == input[9..<12].map(\.0))
        for n in 12..<20 { #expect(out[n] == input[9].0 + Self.slot(n - 9), "picture \(n)") }
    }

    @Test("a timestamp more than one carriage frame off its slot ends the run (a splice)")
    func spliceBreaksRun() {
        var input = Self.fieldTimeline(12)
        for n in 6..<12 { input[n].0 += 90000 }
        let out = Self.run(input)
        #expect(out[5] == Self.slot(5))
        #expect(Array(out[6..<9]) == input[6..<9].map(\.0))
        for n in 9..<12 { #expect(out[n] == input[6].0 + Self.slot(n - 6)) }
    }

    @Test("a missing timestamp inside the run takes its slot")
    func missingTimestampTakesSlot() {
        var input = Self.fieldTimeline(10)
        input[6].0 = Int64.min
        let out = Self.run(input)
        #expect(out[6] == Self.slot(6))
        #expect(out[7] == Self.slot(7))
    }

    @Test("a broken alternation ends the run")
    func brokenAlternation() {
        var input = Self.fieldTimeline(10)
        input[6].1 = input[5].1
        let out = Self.run(input)
        #expect(out[5] == Self.slot(5))
        #expect(out[6] == input[6].0)
    }

    @Test("a progressive sequence's frame repeats (repeat_pict 2, 4) are film too")
    func progressiveSequence() {
        // 59.94p carriage (1501.5 ticks a frame), pictures shown 2 frames, then 3.
        var frames = 0
        let input: [(Int64, Int32, Bool)] = (0..<12).map { n in
            let repeatPict: Int32 = n % 2 == 0 ? 2 : 4
            defer { frames += 1 + Int(repeatPict) / 2 }
            return (Int64((Double(frames) * 1501.5).rounded()), repeatPict, false)
        }
        let out = Self.run(input, carriage: AVRational(num: 60000, den: 1001))
        for n in 3..<12 { #expect(out[n] == Self.slot(n), "picture \(n)") }
    }

    @Test("pictures without repeats are not film and keep their timestamps")
    func notFilm() {
        let input: [(Int64, Int32, Bool)] = (0..<12).map { (Int64($0) * 3003, 0, false) }
        #expect(Self.run(input) == input.map(\.0))
    }

    // MARK: - The decoder

    @Test("the software decoder plays an MPEG-2 soft-telecine stream on the 23.976 grid")
    func decoderRetimesSoftTelecine() throws {
        let data = try #require(Data(base64Encoded: Self.softTelecineBase64, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mpegts")
        defer { demuxer.close() }
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        final class Times: @unchecked Sendable {
            let lock = NSLock()
            var values: [CMTime] = []
        }
        let collected = Times()
        let decoder = SoftwareVideoDecoder()
        try decoder.open(stream: stream) { _, pts, _ in collected.lock.lock(); collected.values.append(pts); collected.lock.unlock() }
        defer { decoder.close() }
        while let pkt = try? demuxer.readPacket() {
            if pkt.pointee.stream_index == demuxer.videoStreamIndex { decoder.decode(packet: pkt) }
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        decoder.drainForEndOfStream()
        collected.lock.lock()
        let times = collected.values
        collected.lock.unlock()
        #expect(times.count == 24)
        guard times.count == 24 else { return }
        let ticks = times.map { CMTimeConvertScale($0, timescale: 90000, method: .roundHalfAwayFromZero).value }
        for n in 3..<24 { #expect(ticks[n] == ticks[0] + Self.slot(n), "picture \(n): \(ticks[n] - ticks[0])") }
    }

    // MARK: - The load probe

    private static func openFixture() throws -> Demuxer {
        let data = try #require(Data(base64Encoded: Self.softTelecineBase64, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mpegts")
        return demuxer
    }

    @Test("the load probe reads 24000/1001 off a soft-telecined MPEG-2 sample")
    func probeFindsFilmRate() throws {
        let demuxer = try Self.openFixture()
        defer { demuxer.close() }
        let rate = InterlaceProbe.filmRate(demuxer: demuxer, streamIndex: demuxer.videoStreamIndex)
        #expect(rate.map { [$0.num, $0.den] } == [24000, 1001])
    }

    @Test("the load probe finds no film in progressive MPEG-2 without repeats")
    func probeFindsNoFilm() throws {
        let data = try #require(Data(base64Encoded: SoftwareDecoderEndOfStreamDrainTests.progressiveBase64,
                                     options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        defer { demuxer.close() }
        #expect(InterlaceProbe.filmRate(demuxer: demuxer, streamIndex: demuxer.videoStreamIndex) == nil)
    }

    @Test("soft telecine is sampled for MPEG-2 and VC-1 at telecine carriage rates only")
    func samplingGate() {
        #expect(AetherEngine.carriesSoftTelecine(codecID: AV_CODEC_ID_MPEG2VIDEO, contentRate: 30000.0 / 1001))
        #expect(AetherEngine.carriesSoftTelecine(codecID: AV_CODEC_ID_VC1, contentRate: 60000.0 / 1001))
        #expect(AetherEngine.carriesSoftTelecine(codecID: AV_CODEC_ID_MPEG2VIDEO, contentRate: 30))
        #expect(!AetherEngine.carriesSoftTelecine(codecID: AV_CODEC_ID_MPEG2VIDEO, contentRate: 25))
        #expect(!AetherEngine.carriesSoftTelecine(codecID: AV_CODEC_ID_MPEG2VIDEO, contentRate: 24000.0 / 1001))
        #expect(!AetherEngine.carriesSoftTelecine(codecID: AV_CODEC_ID_H264, contentRate: 30000.0 / 1001))
        #expect(!AetherEngine.carriesSoftTelecine(codecID: AV_CODEC_ID_MPEG2VIDEO, contentRate: nil))
    }

    /// 64x48 MPEG-2 in MPEG-TS: 24 pictures of testsrc2 coded at 24000/1001 without B-frames, then soft-telecined by
    /// Probes/DolbyVisionPulse/Scripts/mpeg2_pulldown.py (29.97 carriage, 3:2 repeat_first_field). Regenerate:
    ///   ffmpeg -f lavfi -i "testsrc2=s=64x48:r=24000/1001" -frames:v 24 -c:v mpeg2video -bf 0 -g 12 -q:v 20 \
    ///     -pix_fmt yuv420p -f mpeg2video fx24.m2v
    ///   mpeg2_pulldown.py fx24.m2v fx_soft.m2v
    ///   ffmpeg -fflags +genpts -f mpegvideo -i fx_soft.m2v -c copy -muxrate 0 -f mpegts fx_soft.ts
    ///   base64 -b 100 -i fx_soft.ts
    static let softTelecineBase64 = """
        R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        //////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL/////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        /0dQABAAArASAAHBAADhAPAAAuEA8ACeiyPR////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////R0EAMAdQAAB7DH4AAAAB4AAAgMAKMQAH+5MRAAfYYQAAAbME
        ADAk///gGAAAAbUUggABAAAAAAG4AAgAQAAAAQAAD//4AAABtY//88OAAAABAaP5wEZG/IpEt6cTE5xbGu45j3rEgiACc7YbnHOd
        dj7gZJbqOJZjjGcQ4decTCZisrmH5TtfRFFrQnZZGfH3gAbEwvdRP5BurwHRCx6Cekg3KQsDPJO+2ce2W1elRK5224c+U94m/Anw
        sVdHAQARhpL/X1gbAiffjSWUzuaxruOY96/4oNFs+N16tuBkluEHEtlOMZ2HOHXLQvhv4TvtnwH2zdr7PkIrLbHYzBRx4D69Dp6c
        3wC26yygzZeI92wMEJnY1j0u45j7nF5gMfBG2+WB58p7uLJY11HDTHZnCw64kBiGCwNCbjDA1IZmQpZijDzwFsAAAAECo/lZRI1X
        6wokar9wG3tEIBIIIl7PbLH7Zc2vn0n35W0ez2j32WulJ17PbLH7ZUcBADIcAP///////////////////////////////////8Ou
        MMOD4AAAAQOj+aITtq1JNKzPyd7r3oCGYH3zmK399eAmL5ZNKK7MsSpHvzqQKhmxJJ3IF1gA9IQEyckgXvA0kcBfexvnEEJHx/AO
        r8/AriUnbDiDf5IfW5JaMz+l6EhmB9/SCCGn87E8g3sE0IK/woj3jSTStjyd7qgFYYBMncgXpw0kcBfewvmkF/4y+fANEYmhn/An
        8oRoR0EAMwkA//////////8AAAHgAACAwAoxAAkewxEAB/uTAAABAABX//uAAAABtYEf80GAAAABAaKYDCADA3AAwBycRw4fAwgA
        gHsADphIeHQB6LWAe1EwAdAG0BAiQNgAJ0ADoKAP6mA3AAtAHXEQN3/5PgeAAYA37E4ToGcAEB/UDgz//wAOgDeAB8RgH8AD8QAs
        gAeCIAAAAQKidHAAAAEDopcAHkDUADVYAP6lwAeQAPKlAYwAYGT/8fBHQAARAACwDQABwQAAAAHwACqxBLL/////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        /////0dQABEAArASAAHBAADhAPAAAuEA8ACeiyPR////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////R0EANHcQAACMpP4A////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        /////////////////////wAAAeAAAIDACjEACTY5EQAJHsMAAAEAAJf/+4AAAAG1gR/zQ4AAAAEBotAQmpBy//pwAAABAqJ0cAAA
        AQOidHBHQQA1agD/////////////////////////////////////////////////////////////////////////////////////
        //////////////////////////////////////////////////////8AAAHgAACAwAoxAAlZaxEACTY5AAABAADX//uAAAABtYEf
        88GAAAABAaKOAA/kll9KX7n9X7s/rYZmUdlsfI4AAAEConRwAAABA6J0cEdBADZ9EAAAm07+AP//////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        //////////////////////////////8AAAHgAACAwAoxAAlw4REACVlrAAABAAEX//uAAAABtYEf88OAAAABAaJ0cAAAAQKidHAA
        AAEDonRwR0AAEgAAsA0AAcEAAAAB8AAqsQSy////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        //////////////////////////////////////////////////////////9HUAASAAKwEgABwQAA4QDwAALhAPAAnosj0f//////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        /////////0dBADd9AP//////////////////////////////////////////////////////////////////////////////////
        //////////////////////////////////////////////////////////////////////////////////8AAAHgAACAwAoxAAmU
        EREACXDhAAABAAFX//uAAAABtYEf80GAAAABAaJ0cAAAAQKidHAAAAEDonRwR0EAOHoQAACp+H4A////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        /////////////////////////////wAAAeAAAIDACjEACauHEQAJlBEAAAEAAZf/+4AAAAG1gR/zQ4AAAAEBoqQaQAZHAAABAqJ0
        cAAAAQOidHBHQQA5eQD/////////////////////////////////////////////////////////////////////////////////
        //////////////////////////////////////////////////////////////////////////////8AAAHgAACAwAoxAAnOuREA
        CauHAAABAAHX//uAAAABtYEf88GAAAABAaKkGn/9cjgAAAEConRwAAABA6J0cEdAABMAALANAAHBAAAAAfAAKrEEsv//////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        ////////////R1AAEwACsBIAAcEAAOEA8AAC4QDwAJ6LI9H/////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        //////////////////////////////////////////////////////////////9HQQA6fRAAALiifgD/////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////AAAB4AAAgMAKMQAJ5i8RAAnOuQAAAQACF//7gAAAAbWBH/PDgAAAAQGidHAAAAEC
        onRwAAABA6J0cEdBADt6AP//////////////////////////////////////////////////////////////////////////////
        //////////////////////////////////////////////////////////////////////////////////8AAAHgAACAwAoxAAsJ
        XxEACeYvAAABAAJX//uAAAABtYEf80GAAAABAaKkQHnSOAAAAQKidHAAAAEDonRwR0EAPHgQAADHS/4A////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        //////////////////////////////8AAAHgAACAwAoxAAsg1REACwlfAAABAAKX//uAAAABtYEf80OAAAABAaKVBwABlSOAAAAB
        AqJ0cAAAAQOidHBHQAAUAACwDQABwQAAAAHwACqxBLL/////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        /////////////////////////////////////////////////////////////////0dQABQAArASAAHBAADhAPAAAuEA8ACeiyPR
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        ////////////////R0EAPX0A////////////////////////////////////////////////////////////////////////////
        /////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAIDA
        CjEAC0QHEQALINUAAAEAAtf/+4AAAAG1gR/zwYAAAAEBonRwAAABAqJ0cAAAAQOidHBHQBERAELwJQABwQAA/wH/AAH8gBRIEgEG
        RkZtcGVnCVNlcnZpY2UwMXd8Q8r/////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        /////////////////0dAABUAALANAAHBAAAAAfAAKrEEsv//////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////R1AAFQACsBIAAcEAAOEA8AAC4QDwAJ6L
        I9H/////////////////////////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        //////////////////9HQQA+B1AAANX1/gAAAAHgAACAwAoxAAtbfREAC0QHAAABswQAMCT//+AYAAABtRSCAAEAAAAAAbgACAYA
        AAABAAAP//gAAAG1j//zw4AAAAEBo/nmGZG/IpEtacTE5xbGu45j3rEgiACc7YbnHOddb7ksluo4lmOMZxDh18/jz+aRzgDi+rJg
        QMTtnUs1ePvEA2Jhe6ifyDdXgOiFj0E9JBuUhYGeSd9s49stq9KiVzttw58p7j34E+Fir0cBAB+aSX+vrA2BE+/Gkspnc1jXccx7
        1/xQaLZ8br1bcDJLcIOJbKcYzsOcOuWhfDfwnfbPgPtm7X2fIRWW2OxmCjjwH16HT05vgFt1llBmy8R7tgYITOxrHpdxzH3OLzAY
        +CNt8sDz5T3cWSxrqOGmOzOFh1xIDEMFgaE3GGBqQzMhSzFGHngLYAAAAQKj+VlEjVfrCiRqv3Abe0QgEggiXs9ssftlza+fSffl
        bR7PaPfZa6UnXs9ssftlRwEAMBwA////////////////////////////////////w64ww4PgAAABA6P5ohO2rUk0rM/J3uvegIZg
        ffOYrf314CYvlk0orsyxKke/OpAqGbEkncgXWAD0hATJySBe8DSRwF97G+cQQkfH8A6vz8CuJSdsOIN/kh9bklozP6XoSGYH39II
        IafzsTyDewTQgr/CiPeNJNK2PJ3uqAVhgEydyBenDSRwF97C+aQX/jL58A0RiaGf8CfyhGhHQQAxCQD//////////wAAAeAAAIDA
        CjEAC36tEQALW30AAAEAAFf/+4AAAAG1gR/zQYAAAAEBopgMIAMDcADAHJxHDh8DCACAewAOgsB/Aw//h4HaiYAOgDaAgRIGwAE6
        AB0FAH9TAbgAWgDriIG7/8nwPAAMAb9icJ0DOACA/qBwZ//4AHQBvAA+IwD+AB+IAWQAPBEAAAABAqJ0cAAAAQOilwAeQNQANVgA
        /qXAB5AA8qUBjABgZP/x8EdBADJwEAAA5J9+AP//////////////////////////////////////////////////////////////
        /////////////////////////////////////////////////////////////////////////////wAAAeAAAIDACjEAC5YjEQAL
        fq0AAAEAAJf/+4AAAAG1gR/zQ4AAAAEBoo+x4HIGj/+A5NSDl//TgAAAAQKidHAAAAEDonRwR0AAFgAAsA0AAcEAAAAB8AAqsQSy
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        //////////////////////9HUAAWAAKwEgABwQAA4QDwAALhAPAAnosj0f//////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        /////////////////////////////////////////////////////////////////////////0dBADN6AP//////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        //////////////////////////////////////////8AAAHgAACAwAoxAAu5VREAC5YjAAABAADX//uAAAABtYEf88GAAAABAaLp
        EkcAAAECoqwNSOAAAAEDonRwR0EANH0QAADzSX4A////////////////////////////////////////////////////////////
        /////////////////////////////////////////////////////////////////////////////////////////////////wAA
        AeAAAIDACjEAC9DLEQALuVUAAAEAARf/+4AAAAG1gR/zw4AAAAEBonRwAAABAqJ0cAAAAQOidHBHQQA1fQD/////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////AAAB4AAAgMAKMQAL8/sRAAvQywAAAQABV//7gAAAAbWBH/NBgAAA
        AQGidHAAAAEConRwAAABA6J0cEdAABcAALANAAHBAAAAAfAAKrEEsv//////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////R1AAFwACsBIAAcEAAOEA8AAC
        4QDwAJ6LI9H/////////////////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        //////////////////////////9HQQA2cxAAAQHy/gD/////////////////////////////////////////////////////////
        //////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAwAox
        AA0LcREAC/P7AAABAAGX//uAAAABtYEf80OAAAABAaKaOeXUkAdgRgAdzOAAAAEConRwAAABA6J0cEdBADd1EAABB9B+AP//////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////AAAB4AAAgMAKMQANLqMRAA0LcQAAAQAB1//7gAAAAbWBH/PBgAAAAQGi6Dd/
        /VIC2ZwAAAECoqXXI4AAAAEDonRwR0EAOH0A////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        /wAAAeAAAIDACjEADUYZEQANLqMAAAEAAhf/+4AAAAG1gR/zw4AAAAEBonRwAAABAqJ0cAAAAQOidHBHQAAYAACwDQABwQAAAAHw
        ACqxBLL/////////////////////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        /////////////////////////////0dQABgAArASAAHBAADhAPAAAuEA8ACeiyPR////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////R0EAOX0QAAEWen4A////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        /////////////////////////////////////////////////////wAAAeAAAIDACjEADWlJEQANRhkAAAEAAlf/+4AAAAG1gR/z
        QYAAAAEBonRwAAABAqJ0cAAAAQOidHBHQQA6egD/////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        AAAB4AAAgMAKMQANgL8RAA1pSQAAAQACl//7gAAAAbWBH/NDgAAAAQGi68jgAAABAqLfWvzOAAABA6J0cEdBADt9EAABJSP+AP//
        ////////////////////////////////////////////////////////////////////////////////////////////////////
        //////////////////////////////////////////////////////8AAAHgAACAwAoxAA2YNREADYC/AAABAALX//uAAAABtYEf
        88GAAAABAaJ0cAAAAQKidHAAAAEDonRw
        """
}
