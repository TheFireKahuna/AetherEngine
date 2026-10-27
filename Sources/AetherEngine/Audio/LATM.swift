/// AAC in LATM (ISO/IEC 14496-3 1.7.3), framed by LOAS (1.7.2): what DVB broadcasts and their
/// IPTV restreams carry. LATM is a transport, not a codec: each AudioMuxElement wraps a raw AAC
/// frame and, every so often, the StreamMuxConfig that holds the stream's AudioSpecificConfig. Taken
/// out of it, the frames and their config are AAC like any other and copy into fMP4.
///
/// Read to the scope libavcodec's LATM decoder has (aacdec_latm.h): one program, one layer, the
/// configuration in the stream (muxConfigPresent). A version-0 StreamMuxConfig does not state how
/// long its AudioSpecificConfig is, so the configuration is read to find its end
/// (`AudioSpecificConfigReader`).
enum LATM {

    /// What a stream's elements are read with: the configuration the last StreamMuxConfig carried
    /// and its frame length coding. An element that reuses it (useSameStreamMux) states neither.
    struct Reader {
        /// The AudioSpecificConfig last carried, byte-aligned with its trailing bits zero.
        private(set) var config: [UInt8]?
        private var frameLengthType = 0
        private var frameLength = 0

        /// The raw AAC frame `bytes` carries, byte-aligned. `bytes` is one LOAS frame
        /// (AudioSyncStream: the 0x2B7 sync word, the length, an AudioMuxElement) as libavformat's
        /// loas and mpegts demuxers deliver it. Nil for anything outside the scope above, a truncated
        /// element, or an element that reuses a configuration this reader has not seen.
        mutating func payload(_ bytes: UnsafeRawBufferPointer) -> [UInt8]? {
            var bits = BitReader(bytes)
            guard bits.read(11) == 0x2B7, let length = bits.read(13), Int(length) + 3 <= bytes.count,
                  let useSameStreamMux = bits.read(1) else { return nil }
            if useSameStreamMux == 0 {
                guard let mux = LATM.streamMuxConfig(&bits) else { return nil }
                (config, frameLengthType, frameLength) = mux
            } else if config == nil {
                return nil
            }
            // PayloadLengthInfo: a run of bytes summed until one under 255 (variable frame length),
            // or the fixed length the configuration gave.
            var payloadBytes = frameLength
            if frameLengthType == 0 {
                payloadBytes = 0
                while true {
                    guard let tmp = bits.read(8) else { return nil }
                    payloadBytes += Int(tmp)
                    if tmp != 255 { break }
                }
            }
            guard payloadBytes > 0 else { return nil }
            return bits.bytes(payloadBytes)
        }
    }

    /// An AudioSpecificConfig as libavcodec's LATM decoder leaves it in `extradata`: the bytes it
    /// started in, so the last one can carry bits of what followed it. Cut at its end.
    static func configuration(extradata: UnsafeRawBufferPointer) -> [UInt8]? {
        let bits = BitReader(extradata)
        guard let length = AudioSpecificConfigReader.length(bits) else { return nil }
        return bits.copy(bits: length, from: 0)
    }

    /// The StreamMuxConfig's AudioSpecificConfig and frame length coding.
    fileprivate static func streamMuxConfig(_ bits: inout BitReader) -> (config: [UInt8], frameLengthType: Int, frameLength: Int)? {
        guard let audioMuxVersion = bits.read(1) else { return nil }
        var audioMuxVersionA: UInt64 = 0
        if audioMuxVersion == 1 { guard let a = bits.read(1) else { return nil }; audioMuxVersionA = a }
        guard audioMuxVersionA == 0 else { return nil }
        if audioMuxVersion == 1 { guard bits.latmValue() != nil else { return nil } }   // taraBufferFullness
        guard bits.read(1) != nil,                               // allStreamsSameTimeFraming
              bits.read(6) == 0,                                 // numSubFrames
              bits.read(4) == 0,                                 // numProgram
              bits.read(3) == 0 else { return nil }              // numLayer
        let start = bits.position
        let configBits: Int
        if audioMuxVersion == 0 {
            guard let length = AudioSpecificConfigReader.length(bits) else { return nil }
            configBits = length
        } else {
            guard let ascLen = bits.latmValue(), ascLen > 0 else { return nil }
            configBits = Int(ascLen)
        }
        guard let config = bits.copy(bits: configBits, from: start) else { return nil }
        bits.skip(configBits)
        guard let frameLengthType = bits.read(3) else { return nil }
        var frameLength = 0
        switch frameLengthType {
        case 0: guard bits.read(8) != nil else { return nil }    // latmBufferFullness
        case 1: guard let length = bits.read(9) else { return nil }; frameLength = Int(length)
        default: return nil                                      // CELP / HVXC: not AAC
        }
        if bits.read(1) == 1 {                                   // otherDataPresent
            if audioMuxVersion == 1 {
                guard bits.latmValue() != nil else { return nil }
            } else {
                var escape: UInt64 = 1
                while escape == 1 {
                    guard let e = bits.read(1), bits.read(8) != nil else { return nil }
                    escape = e
                }
            }
        }
        if bits.read(1) == 1 { guard bits.read(8) != nil else { return nil } }   // crcCheckPresent
        return (config, Int(frameLengthType), frameLength)
    }

    /// MSB-first reader over a byte buffer.
    struct BitReader {
        private let bytes: UnsafeRawBufferPointer
        private(set) var position = 0

        init(_ bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

        var remaining: Int { bytes.count * 8 - position }

        mutating func read(_ count: Int) -> UInt64? {
            guard count <= 64, count <= remaining else { return nil }
            defer { position += count }
            return peek(count, at: position)
        }

        mutating func skip(_ count: Int) { position += count }

        /// LatmGetValue: two bits of byte count less one, then that many bytes.
        mutating func latmValue() -> UInt64? {
            guard let bytesForValue = read(2) else { return nil }
            return read(Int(bytesForValue + 1) * 8)
        }

        /// `count` whole bytes from the current position, whatever its bit offset.
        mutating func bytes(_ count: Int) -> [UInt8]? {
            guard count * 8 <= remaining else { return nil }
            var out = [UInt8](repeating: 0, count: count)
            for i in 0..<count { out[i] = UInt8(peek(8, at: position + 8 * i)) }
            position += count * 8
            return out
        }

        /// `count` bits starting at bit `start`, left-aligned in bytes, the last byte's spare bits zero.
        func copy(bits count: Int, from start: Int) -> [UInt8]? {
            guard count > 0, start + count <= bytes.count * 8 else { return nil }
            var out = [UInt8](repeating: 0, count: (count + 7) / 8)
            for i in out.indices {
                let width = min(8, count - 8 * i)
                out[i] = UInt8(peek(width, at: start + 8 * i) << (8 - UInt64(width)))
            }
            return out
        }

        private func peek(_ count: Int, at start: Int) -> UInt64 {
            var value: UInt64 = 0
            for bit in start..<(start + count) {
                value = value << 1 | UInt64(bytes[bit >> 3] >> (7 - UInt8(bit & 7)) & 1)
            }
            return value
        }
    }
}

/// How long an AudioSpecificConfig is, in bits (ISO/IEC 14496-3 1.6.2.1), read to the scope the
/// AAC family needs: the object types of GASpecificConfig, SBR and parametric stereo over them, and
/// the error-resilient variants without error protection. Nil for anything else, which includes a
/// program_config_element in place of a channel configuration: those stay with the decoder.
enum AudioSpecificConfigReader {

    static func length(_ start: LATM.BitReader) -> Int? {
        var bits = start
        let origin = bits.position
        func objectType() -> UInt64? {
            guard let aot = bits.read(5) else { return nil }
            guard aot == 31 else { return aot }
            return bits.read(6).map { 32 + $0 }
        }
        func samplingFrequency() -> Bool {
            guard let index = bits.read(4) else { return false }
            return index != 15 || bits.read(24) != nil
        }
        guard var aot = objectType(), samplingFrequency(), let channelConfiguration = bits.read(4) else { return nil }
        if aot == 5 || aot == 29 {
            guard samplingFrequency(), let core = objectType() else { return nil }
            aot = core
        }
        let generalAudio: Set<UInt64> = [1, 2, 3, 4, 6, 7, 17, 19, 20, 21, 22, 23]
        guard generalAudio.contains(aot), channelConfiguration != 0 else { return nil }
        // GASpecificConfig: frameLengthFlag, dependsOnCoreCoder (+ coreCoderDelay), extensionFlag.
        guard bits.read(1) != nil, let dependsOnCoreCoder = bits.read(1) else { return nil }
        if dependsOnCoreCoder == 1 { guard bits.read(14) != nil else { return nil } }
        guard let extensionFlag = bits.read(1) else { return nil }
        if aot == 6 || aot == 20 { guard bits.read(3) != nil else { return nil } }        // layerNr
        if extensionFlag == 1 {
            if aot == 22 { guard bits.read(5) != nil, bits.read(11) != nil else { return nil } }
            if [17, 19, 20, 23].contains(aot) { guard bits.read(3) != nil else { return nil } }
            guard bits.read(1) != nil else { return nil }                                   // extensionFlag3
        }
        if [17, 19, 20, 21, 22, 23].contains(aot) {
            guard let epConfig = bits.read(2), epConfig < 2 else { return nil }
        }
        return bits.position - origin
    }
}
