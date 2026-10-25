import CoreMedia
import CoreVideo
import Foundation
import AetherLibavutil

/// The colour an HEVC stream states for each picture in its own bitstream, for `HardwareVideoDecoder`, whose
/// VideoToolbox buffers carry what the session's format description said at open. A later SPS may state a different
/// colour or none (a spliced stream, a broadcast programme switch), and the alternative transfer characteristics SEI
/// (how HLG is signalled over a BT.2020 transfer) lasts one coded video sequence (H.265 D.3).
///
/// Per access unit: an SPS that differs from the last one is read through CoreMedia
/// (`CMVideoFormatDescriptionCreateFromHEVCParameterSets` parses its VUI), and the alternative transfer is taken from
/// the unit's SEI, or dropped by a unit that starts a new coded video sequence without one. The open-time tags (the
/// container's, see `ColourBackfill`) stand for each field until an in-band SPS states that field; after that its
/// silence is unspecified. Not thread-safe: the decoder's feed thread owns it.
struct HEVCInBandColour {
    /// CoreVideo's immutable tag constants (or CoreMedia's copies of them).
    struct Tags: Equatable, @unchecked Sendable {
        var primaries: CFString?
        var transfer: CFString?
        var matrix: CFString?

        static func == (a: Tags, b: Tags) -> Bool {
            func same(_ x: CFString?, _ y: CFString?) -> Bool {
                switch (x, y) { case (nil, nil): true; case let (x?, y?): CFEqual(x, y); default: false }
            }
            return same(a.primaries, b.primaries) && same(a.transfer, b.transfer) && same(a.matrix, b.matrix)
        }
    }

    private let framing: A53SEIParser.NALFraming
    private let container: Tags
    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    /// The active SPS's own colour, and which fields an in-band SPS has stated so far: a field stays the container's
    /// until one does.
    private var read = Tags()
    private var statedPrimaries = false
    private var statedTransfer = false
    private var statedMatrix = false
    private var alternative: UInt8?
    /// An end-of-sequence NAL makes the next CRA start a coded video sequence; so does the first picture.
    private var nextCRAStartsSequence = true

    init(framing: A53SEIParser.NALFraming, container: Tags) {
        self.framing = framing
        self.container = container
    }

    /// The tags for the picture in this access unit.
    mutating func tags(forAccessUnit data: UnsafePointer<UInt8>, size: Int) -> Tags {
        var newSPS: [UInt8]?, vclType: UInt8?, preferred: UInt8?
        A53SEIParser.forEachNAL(data, size, framing) { nal, length in
            guard length > 2 else { return }
            let type = (nal[0] >> 1) & 0x3F
            switch type {
            case 32: vps = Array(UnsafeBufferPointer(start: nal, count: length))
            case 33: newSPS = Array(UnsafeBufferPointer(start: nal, count: length))
            case 34: pps = Array(UnsafeBufferPointer(start: nal, count: length))
            case 36, 37: nextCRAStartsSequence = true   // end of sequence, end of bitstream
            case 39:
                if preferred == nil {
                    preferred = AlternativeTransferSEI.preferredTransfer(inSEIRBSP: A53SEIParser.unescapeRBSP(nal + 2, length - 2))
                }
            case 0...31: if vclType == nil { vclType = type }
            default: break
            }
        }
        if let newSPS, newSPS != sps {
            sps = newSPS
            if let colour = Self.colour(vps: vps, sps: newSPS, pps: pps) {
                read = colour
                statedPrimaries = statedPrimaries || colour.primaries != nil
                statedTransfer = statedTransfer || colour.transfer != nil
                statedMatrix = statedMatrix || colour.matrix != nil
            }
        }
        if let vclType {
            // BLA (16-18), IDR (19, 20), or a CRA (21) after an end of sequence: a new coded video sequence.
            let startsSequence = (16...20).contains(vclType) || (vclType == 21 && nextCRAStartsSequence)
            if let preferred { alternative = preferred } else if startsSequence { alternative = nil }
            if (16...21).contains(vclType) { nextCRAStartsSequence = false }
        }
        var tags = Tags(primaries: statedPrimaries ? read.primaries : container.primaries,
                        transfer: statedTransfer ? read.transfer : container.transfer,
                        matrix: statedMatrix ? read.matrix : container.matrix)
        if let alternative, let curve = ColorAttachments.transfer(AVColorTransferCharacteristic(rawValue: UInt32(alternative))) {
            tags.transfer = curve
        }
        return tags
    }

    /// After a flush or seek: the next random access point starts a coded video sequence.
    mutating func restart() { nextCRAStartsSequence = true }

    /// The colour the SPS's VUI states, nil for each field it leaves out; nil altogether when CoreMedia cannot read the
    /// parameter sets.
    static func colour(vps: [UInt8]?, sps: [UInt8], pps: [UInt8]?) -> Tags? {
        guard let vps, let pps else { return nil }
        let sets = [vps, sps, pps]
        var description: CMFormatDescription?
        let status = sets[0].withUnsafeBufferPointer { v in
            sets[1].withUnsafeBufferPointer { s in
                sets[2].withUnsafeBufferPointer { p in
                    let pointers = [v.baseAddress!, s.baseAddress!, p.baseAddress!]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: nil, parameterSetCount: 3, parameterSetPointers: pointers,
                        parameterSetSizes: sets.map(\.count), nalUnitHeaderLength: 4, extensions: nil,
                        formatDescriptionOut: &description)
                }
            }
        }
        guard status == noErr, let description else { return nil }
        func value(_ key: CFString) -> CFString? {
            CMFormatDescriptionGetExtension(description, extensionKey: key).flatMap { $0 as? String }.map { $0 as CFString }
        }
        return Tags(primaries: value(kCMFormatDescriptionExtension_ColorPrimaries),
                    transfer: value(kCMFormatDescriptionExtension_TransferFunction),
                    matrix: value(kCMFormatDescriptionExtension_YCbCrMatrix))
    }
}
