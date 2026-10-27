/// MPEG audio Layer III's bit reservoir as the bitstream states it (ISO/IEC 11172-3 2.4.1.7, 13818-3
/// 2.4.1.7): each frame's main data begins `main_data_begin` bytes before the end of its side
/// information, in the main data of the frames before it. A decoder started at a frame therefore
/// decodes a later frame only if the bytes its main data begins in were fed, which is how far back a
/// run of an MP3 decoder has to start (`AudioSegmentRuns`), read off the stream instead of bounded
/// by the format's worst case (`AudioStageSpan.mp3DecoderMemory`).
enum MP3MainData {

    /// A Layer III frame's reservoir: where its main data begins, counted back from its own, and how
    /// much main data the frame carries for the frames after it to begin in.
    struct Frame: Equatable {
        let mainDataBegin: Int
        let mainDataBytes: Int
    }

    private static let bitRatesMPEG1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    private static let bitRatesMPEG2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
    private static let sampleRates: [[Int]] = [[11_025, 12_000, 8_000], [], [22_050, 24_000, 16_000], [44_100, 48_000, 32_000]]

    /// The Layer III frames `bytes` holds back to back (a packet: one frame, or several where a
    /// container laces them); nil where one is not a Layer III frame or states no bitrate (free
    /// format, whose frame length only the next sync word gives).
    static func frames(in bytes: UnsafeRawBufferPointer) -> [Frame]? {
        var frames: [Frame] = []
        var at = 0
        while at < bytes.count {
            guard bytes.count - at >= 6, bytes[at] == 0xFF, bytes[at + 1] & 0xE0 == 0xE0 else { return nil }
            let version = Int(bytes[at + 1] >> 3 & 3)          // 3 MPEG-1, 2 MPEG-2, 0 MPEG-2.5
            let layer = bytes[at + 1] >> 1 & 3                  // 1 Layer III
            let crc = bytes[at + 1] & 1 == 0
            let bitRateIndex = Int(bytes[at + 2] >> 4)
            let rateIndex = Int(bytes[at + 2] >> 2 & 3)
            let padding = Int(bytes[at + 2] >> 1 & 1)
            let mono = bytes[at + 3] >> 6 == 3
            guard version != 1, layer == 1, bitRateIndex > 0, bitRateIndex < 15, rateIndex < 3 else { return nil }
            let mpeg1 = version == 3
            let bitRate = (mpeg1 ? bitRatesMPEG1 : bitRatesMPEG2)[bitRateIndex] * 1000
            let sampleRate = sampleRates[version][rateIndex]
            let length = (mpeg1 ? 144 : 72) * bitRate / sampleRate + padding
            let sideInfo = mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17)
            let side = at + 4 + (crc ? 2 : 0)
            guard length > side - at + sideInfo, side + 2 <= bytes.count else { return nil }
            let begin = mpeg1 ? Int(bytes[side]) << 1 | Int(bytes[side + 1] >> 7) : Int(bytes[side])
            frames.append(Frame(mainDataBegin: begin, mainDataBytes: length - (side - at) - sideInfo))
            at += length
        }
        return frames.isEmpty ? nil : frames
    }

    /// The first of `packets` a decoder has to be fed for the frames of packet `needed` and every
    /// packet after it to decode: the one holding the byte the main data of `needed`'s first frame
    /// begins at. Later frames' main data begins no earlier, since it follows in stream order. Nil
    /// where a packet in between cannot be read, or the reservoir reaches back past the first one.
    static func firstPacket(feeding needed: Int, of packets: [UnsafeRawBufferPointer]) -> Int? {
        guard needed < packets.count, let first = frames(in: packets[needed])?.first else { return nil }
        var back = first.mainDataBegin
        var index = needed
        while back > 0 {
            index -= 1
            guard index >= 0, let earlier = frames(in: packets[index]) else { return nil }
            back -= earlier.reduce(0) { $0 + $1.mainDataBytes }
        }
        return index
    }
}
