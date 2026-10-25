import Foundation
import AetherLibavcodec

/// The per-picture metadata a software overlay's placeholder sample carries for its source picture, as HEVC NAL
/// units (2-byte header, emulation prevention in place): what reaches the panel is the metadata in the stream
/// AVPlayer plays, never the overlay's own frames (docs/software-route-gpu.md Part 1).
///
/// - AV1 (ITU-T T.35 metadata OBUs): HDR10+ (ST 2094-40) becomes a `user_data_registered_itu_t_t35` prefix SEI with
///   the same payload; a Dolby Vision RPU (profile 10) is taken out of its EMDF container and becomes the unspec62
///   NAL HEVC carries, the same RPU bytes.
/// - HEVC: the source's own prefix SEI and unspec62 NALs, as they are.
/// - Anything else carries none.
struct OverlayPictureMetadata: Equatable {
    /// Before the picture's slices.
    var prefixSEI: [[UInt8]] = []
    /// After them, where an HEVC Dolby Vision stream carries it.
    var rpu: [UInt8]?

    static let none = OverlayPictureMetadata()

    /// The metadata of the access unit `bytes`, read as `codecID` packets with `framing` (HEVC only).
    static func read(_ bytes: UnsafeBufferPointer<UInt8>, codecID: AVCodecID, framing: A53SEIParser.NALFraming) -> OverlayPictureMetadata {
        switch codecID {
        case AV_CODEC_ID_AV1: return fromOBUs(bytes)
        case AV_CODEC_ID_HEVC: return fromHEVC(bytes, framing: framing)
        default: return .none
        }
    }

    // MARK: - AV1

    private static let hdr10PlusProvider: [UInt8] = [0x00, 0x3C, 0x00, 0x01]
    private static let dolbyVisionProvider: [UInt8] = [0x00, 0x3B, 0x00, 0x00, 0x08, 0x00]

    /// A low-overhead OBU stream (the demuxed packet framing).
    private static func fromOBUs(_ bytes: UnsafeBufferPointer<UInt8>) -> OverlayPictureMetadata {
        var out = OverlayPictureMetadata()
        var offset = 0
        while offset < bytes.count {
            let header = bytes[offset]
            offset += 1
            guard header & 0x81 == 0 else { return out }
            let type = (header >> 3) & 15
            if header & 4 != 0 { offset += 1 }
            let size: Int
            if header & 2 != 0 {
                guard let declared = leb128(bytes, &offset), declared <= bytes.count - offset else { return out }
                size = declared
            } else {
                size = bytes.count - offset
            }
            let end = offset + size
            if type == 5, let message = t35Message(bytes, from: offset, to: end) {
                if message.first == 0xB5, message.dropFirst().starts(with: hdr10PlusProvider) {
                    out.prefixSEI.append(t35SEI(message))
                } else if message.first == 0xB5, message.dropFirst().starts(with: dolbyVisionProvider),
                          let rpu = dolbyVisionRPU(message) {
                    out.rpu = rpu
                }
            }
            offset = end
        }
        return out
    }

    /// A metadata OBU's ITU-T T.35 message (`metadata_type` 4), from its country code up to the OBU's trailing bits
    /// (a stop bit, then any number of zero bytes); nil for any other metadata.
    private static func t35Message(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> [UInt8]? {
        var at = start
        guard leb128(bytes, &at) == 4 else { return nil }
        var trailing = end
        while trailing > at, bytes[trailing - 1] == 0 { trailing -= 1 }
        guard trailing > at, bytes[trailing - 1] == 0x80 else { return nil }
        return Array(bytes[at..<(trailing - 1)])
    }

    /// AV1 restricts leb128 values to 32 bits, even with an eight-byte encoding.
    private static func leb128(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: inout Int) -> Int? {
        var value: UInt64 = 0
        for index in 0..<8 {
            guard offset < bytes.count else { return nil }
            let byte = bytes[offset]
            offset += 1
            value |= UInt64(byte & 0x7F) << (index * 7)
            if byte & 0x80 == 0 { return value <= UInt32.max ? Int(value) : nil }
        }
        return nil
    }

    /// The unspec62 NAL for the RPU in a Dolby Vision T.35 message (country code, provider code, provider oriented
    /// code, then an EMDF container whose one payload is the RPU from its header to its CRC and final byte). nil
    /// when the container is not the one Dolby defines for it or the RPU's CRC is wrong.
    static func dolbyVisionRPU(_ message: [UInt8]) -> [UInt8]? {
        var r = H264SPS.BitReader(message)
        guard r.skip(56),
              r.u(2) == 0,     // emdf_version
              r.u(3) == 6,     // key_id
              r.u(5) == 31,    // emdf_payload_id
              variableBits(&r, 5) == 225,
              r.u(4) == 0,     // smploffste, duratione, groupide, codecdatae
              r.u(1) == 1,     // discard_unknown_payload
              let size = variableBits(&r, 8), size > 6 else { return nil }
        var rpu: [UInt8] = [0x19]
        rpu.reserveCapacity(size + 1)
        for _ in 0..<size {
            guard let byte = r.u(8) else { return nil }
            rpu.append(UInt8(byte))
        }
        let nal = [0x7C, 0x01] + escaped(rpu)
        return nal.withUnsafeBufferPointer { DoviRpuGuard.crcIsValid($0.baseAddress!, $0.count) } ? nal : nil
    }

    /// EMDF's `variable_bits(n)`.
    private static func variableBits(_ r: inout H264SPS.BitReader, _ n: Int) -> Int? {
        var value = 0
        while true {
            guard let chunk = r.u(n), let more = r.flag() else { return nil }
            value += chunk
            guard more else { return value }
            guard value < 1 << 24 else { return nil }
            value = (value << n) + (1 << n)
        }
    }

    /// A prefix SEI NAL holding one `user_data_registered_itu_t_t35` message, `message` from its country code on.
    static func t35SEI(_ message: [UInt8]) -> [UInt8] {
        var rbsp: [UInt8] = [4]
        var size = message.count
        while size >= 255 { rbsp.append(0xFF); size -= 255 }
        rbsp.append(UInt8(size))
        rbsp += message
        rbsp.append(0x80)
        return [0x4E, 0x01] + escaped(rbsp)
    }

    /// Emulation prevention: a 0x03 after any two zero bytes followed by a byte of 3 or less.
    static func escaped(_ rbsp: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(rbsp.count + rbsp.count / 64)
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2, byte <= 3 {
                out.append(3)
                zeros = 0
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    // MARK: - HEVC

    private static func fromHEVC(_ bytes: UnsafeBufferPointer<UInt8>, framing: A53SEIParser.NALFraming) -> OverlayPictureMetadata {
        var out = OverlayPictureMetadata()
        guard let base = bytes.baseAddress else { return out }
        A53SEIParser.forEachNAL(base, bytes.count, framing) { nal, length in
            guard length > 2, HEVCSPS.isBaseLayer(nal) else { return }
            switch (nal[0] >> 1) & 0x3F {
            case 39: out.prefixSEI.append(Array(UnsafeBufferPointer(start: nal, count: length)))
            case 62: out.rpu = Array(UnsafeBufferPointer(start: nal, count: length))
            default: break
            }
        }
        return out
    }
}
