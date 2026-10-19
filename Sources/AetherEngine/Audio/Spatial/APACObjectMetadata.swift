// Only with the APACObjectOutput trait (personal builds, off by default).
#if APACObjectOutput
import Foundation
import simd

/// The metadata side of object APAC: the static blob the encoder is configured with and the
/// `aia_format` packet it reads from a trailing PCM channel at the start of every 1024-frame packet.
///
/// Neither format is documented. Both were recovered from macOS 27's AudioCodecs and verified by
/// round trip through the decoder and the system renderer (research notes, `apac-objects/README.md`
/// §3–4 and `specs/AIA_FORMAT_SPEC.md`). What the renderer does with each parameter is in §3.20 there:
/// with the Atmos renderer type it uses position, size and the blocks' timing, nothing else, so
/// nothing else is written.
enum APACObjectMetadata {

    /// Room-cube coordinates as the renderer reads them (renderer type 3): X right, Y front, Z up,
    /// −1…1 (Z 0…1).
    struct Point: Equatable {
        var x: Float, y: Float, z: Float
    }

    /// One block of an object's metadata within a packet: from `start` (frames into the packet) the
    /// renderer moves the object from where it is to `position`/`size` over `interpolation` frames
    /// (0 jumps). A packet's first block may omit both; the renderer then interpolates over the whole
    /// packet.
    struct Block: Equatable {
        var start: Int
        var interpolation: Int
        var position: Point
        var size: Float
    }

    /// The engine's allocentric room (x 0 left…1 right, y 0 front…1 back, z 0 floor…1 ceiling, see
    /// `SpatialSpeaker`) in the renderer's cube. Measured (§3.5): with renderer type 3 the renderer
    /// pans these exactly as `AllocentricPanner` does.
    static func point(_ p: SIMD3<Float>) -> Point {
        let c = simd_clamp(p, SIMD3(repeating: 0), SIMD3(repeating: 1))
        return Point(x: 2 * c.x - 1, y: 1 - 2 * c.y, z: c.z)
    }

    // MARK: - Static configuration

    /// The StaticMetadata blob for one bed group and `objects` object groups (spec §7): renderer
    /// metadata present, no global config, then per group the lean GroupConfig. Bed group 0 sits on
    /// ASC 0; object i is group i + 1 on ASC i + 1 with object ID i (one Object component each, see
    /// `APACObjectEncoder`; the ID layout the probes verified). Every object's default renderer data declares a position (whose precision
    /// fields the renderer keeps for the stream) and a Cartesian spread: without the static spread,
    /// per-frame sizes are re-read as angles (§3.6).
    static func staticBlob(objects: Int) -> [UInt8] {
        var w = BitWriter()
        w.put(0, 1)                     // metadataFrameCompressionEnabled
        w.put(1, 1)                     // rendererMetadataConfigPresent
        w.put(0, 1)                     // hasGlobalConfig
        w.put(1 + objects, 11)          // groupCount
        writeGroupConfig(&w, group: 0, asc: 0, isBed: true, subID: 0)
        w.put(0, 1)                     // bed: no default renderer data
        for i in 0..<objects {
            writeGroupConfig(&w, group: i + 1, asc: i + 1, isBed: false, subID: i)
            w.put(1, 1)                 // hasDefaultRendererData
            w.put(2, 11)                // numParams
            writePosition(&w, Point(x: 0, y: 0, z: 0))
            writeSpread(&w, 0)
        }
        w.align()
        return w.bytes
    }

    private static func writeGroupConfig(_ w: inout BitWriter, group: Int, asc: Int, isBed: Bool, subID: Int) {
        w.put(group, 11)
        w.put(0, 1)                     // isGlobal
        w.put(1, 1)                     // isPerASC
        w.put(asc, 11)
        w.put(isBed ? 0 : 1, 3)         // ascType: 0 channel bed, 1 object
        w.put(subID, 11)                // chBedID / objectID within the ASC
        if !isBed { w.put(0, 1) }       // isObjectInBed
    }

    // MARK: - Per-packet metadata

    /// Bytes the trailing metadata channel holds per packet: one 16-bit word per frame.
    static let packetCapacity = 1024 * 2

    /// The live `aia_format` packet for one 1024-frame APAC packet (spec §1–3, §6): a header with
    /// its CRC, the payload CRC, and one dynamic `apdd` chunk restating every group. `objects[i]` is
    /// group i + 1; an empty list leaves that object where it is. Nil when it does not fit
    /// `packetCapacity` (the caller retries with fewer blocks).
    static func packet(objects: [[Block]]) -> [UInt8]? {
        var body = BitWriter()
        body.put(1 + objects.count, 11)
        // Bed group: present, one block, no parameters.
        body.put(1, 1); body.put(0, 11); body.put(0, 3); body.put(0, 1); body.put(0, 1); body.put(0, 11)
        for (i, blocks) in objects.enumerated() {
            guard !blocks.isEmpty else { body.put(0, 1); continue }
            precondition(blocks.count <= maxBlocks, "an apdd group carries at most \(maxBlocks) blocks")
            body.put(1, 1)
            body.put(i + 1, 11)
            body.put(blocks.count - 1, 3)
            for (k, block) in blocks.enumerated() {
                // The first block at frame 0 without an interpolation length interpolates over the
                // whole packet, which is also what an explicit 1024 would say.
                let implicit = k == 0 && block.start == 0 && block.interpolation == 1024
                if implicit {
                    body.put(0, 1); body.put(0, 1)
                } else {
                    body.put(1, 1); body.put(min(max(block.start, 0), 1023), 10)
                    body.put(1, 1); body.put(min(max(block.interpolation, 0), 2047), 11)
                }
                body.put(2, 11)         // numParams
                writePosition(&body, block.position)
                writeSpread(&body, block.size)
            }
        }
        body.align()
        guard body.bytes.count <= 0xFFFF else { return nil }

        var payload: [UInt8] = [0, 1] + Array("apdd".utf8)      // no static chunks, one dynamic
        payload += [UInt8(body.bytes.count >> 8), UInt8(body.bytes.count & 0xFF)]
        payload += body.bytes
        let chunkSize = 7 + payload.count
        guard chunkSize <= 0xFFFF else { return nil }
        // Live header: sync, chunk size, version 1.4, flags 0x08 (what the probes ran with).
        var out: [UInt8] = [0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xFF, 0xFF,
                            UInt8(chunkSize >> 8), UInt8(chunkSize & 0xFF), 1, 4, 0x08]
        let headerCRC = crc16(out[...])
        out += [UInt8(headerCRC >> 8), UInt8(headerCRC & 0xFF)]
        let payloadCRC = crc16(payload[...])
        out += [UInt8(payloadCRC >> 8), UInt8(payloadCRC & 0xFF)]
        out += payload
        if out.count % 2 == 1 { out.append(0) }
        return out.count <= packetCapacity ? out : nil
    }

    static let maxBlocks = 8

    /// The packet as samples of the metadata channel: each pair of bytes is one 16-bit word, the
    /// earlier byte low (the other order is silently ignored by the encoder), scaled to ±1.
    static func samples(of packet: [UInt8], into channel: (Int, Float) -> Void) {
        var k = 0
        while k + 1 < packet.count {
            let word = Int16(bitPattern: UInt16(packet[k]) | UInt16(packet[k + 1]) << 8)
            channel(k / 2, Float(word) / 32768)
            k += 2
        }
    }

    // MARK: - Renderer data

    /// RendererData param 0. The precision fields are only read from the static default: maximum
    /// distance 1 and 10 position bits (stored in 16 bits; more overflow, §4).
    private static func writePosition(_ w: inout BitWriter, _ p: Point) {
        w.put(0, 11)                    // paramIndex 0: Position
        w.put(0, 1)                     // p0
        w.put(0, 6)                     // p1
        w.put(0, 1)                     // deriveDistance
        w.f32(1)                        // maxDistance
        w.put(10, 5)                    // posQuantBits
        w.put(2, 5)                     // rotQuantBits
        w.put(1, 1)                     // positionPresent
        w.put(1, 1)                     // isCartesian
        w.f32(p.x); w.f32(p.y); w.f32(p.z)
        w.put(0, 1)                     // rotationPresent
        w.put(0, 1)                     // p38
    }

    /// RendererData param 1, Cartesian: the renderer takes max(width, height, depth) as an isotropic
    /// size on the same 0…1 scale as Atmos object size (§3.6).
    private static func writeSpread(_ w: inout BitWriter, _ size: Float) {
        let s = min(max(size, 0), 1)
        w.put(1, 11)                    // paramIndex 1: ObjectSpread
        w.put(0, 1)                     // isAngular = 0 (Cartesian)
        w.put(0, 1)
        w.f32(1)                        // range
        w.put(8, 5)                     // quantBits (<= 10)
        w.f32(s); w.f32(s)
        w.put(1, 1); w.f32(s)           // hasDepth, depth
    }

    // MARK: - Bits

    /// MSB-first bit writer over a big-endian byte stream.
    struct BitWriter {
        private(set) var bytes: [UInt8] = []
        private var acc: UInt64 = 0
        private var count = 0

        mutating func put(_ value: Int, _ bits: Int) {
            precondition(bits > 0 && bits <= 32 && value >= 0 && UInt64(value) < (1 << UInt64(bits)),
                         "\(value) does not fit \(bits) bits")
            acc = (acc << UInt64(bits)) | UInt64(value)
            count += bits
            while count >= 8 {
                count -= 8
                bytes.append(UInt8((acc >> UInt64(count)) & 0xFF))
            }
        }

        mutating func f32(_ value: Float) {
            let bits = value.bitPattern
            put(Int(bits >> 16), 16)
            put(Int(bits & 0xFFFF), 16)
        }

        mutating func align() {
            if count > 0 { put(0, 8 - count) }
        }
    }

    /// CRC-16/CCITT-FALSE (polynomial 0x1021, initial 0xFFFF), as `aia_format::Header` checks it.
    static func crc16(_ data: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }
}
#endif
