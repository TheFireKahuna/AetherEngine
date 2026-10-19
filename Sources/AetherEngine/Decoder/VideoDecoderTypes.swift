import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Decoded frame callback. `hdr10PlusT35` carries HDR10+ dynamic metadata serialised to ITU-T T.35 bytes
/// (kCMSampleAttachmentKey_HDR10PlusPerFrameData format); nil for non-HDR10+ streams.
typealias DecodedFrameHandler = @Sendable (CVPixelBuffer, CMTime, Data?) -> Void

/// Common video decoder protocol. SoftwareVideoDecoder (libavcodec, AV1/VP9) and
/// HardwareVideoDecoder (VTDecompressionSession, HEVC) both conform; the host swaps per codec without rewiring the demux loop.
// Sendable: both conformers (SoftwareVideoDecoder, HardwareVideoDecoder) are @unchecked Sendable
// (internally lock-guarded), so `any VideoDecodingPipeline` is safe to capture in @Sendable closures.
protocol VideoDecodingPipeline: AnyObject, Sendable {
    var onFrame: DecodedFrameHandler? { get set }
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)? { get set }
    /// #131: fires per decoded frame carrying `AV_FRAME_DATA_A53_CC` side data, with the raw
    /// cc_data triplets and the frame PTS in seconds. Decoder output is presentation order.
    /// Only the software decoder produces it; VideoToolbox surfaces no A53 side data (H.264/HEVC
    /// never route through the SW host, so nothing is missed there).
    var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)? { get set }
    /// AE#658: the decoded format and its display buffer, reported on the first frame and on change.
    var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)? { get set }
    var skipUntilPTS: CMTime? { get set }

    /// AE#492: the decoder's current feed epoch. A caller that decides a batch of packets is
    /// current captures this, hands it back with each one, and the decoder refuses any packet whose
    /// epoch `flush()` has since retired. Read and compared under the same lock `flush()` takes, so
    /// a flush and a feed cannot interleave: the alternative is a caller re-reading a generation it
    /// cannot hold across the call it is about to make.
    var feedEpoch: UInt64 { get }

    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws
    /// `epoch` is the value read from `feedEpoch` when this packet was decided to be current;
    /// `nil` from a caller with no seek of its own to be invalidated by.
    func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64?)
    func flush()
    /// End of source or a live seam: delivers what the decoder still owes before the `flush()` the host
    /// makes next. `flush()` of a decoder that delivers what it drains is enough, so the default does
    /// nothing; a decoder whose `flush()` discards (the dual-layer one) overrides it. Seeks never call it.
    func drainForEndOfStream()
    func close()
}

extension VideoDecodingPipeline {
    func drainForEndOfStream() {}
}

enum VideoDecoderError: Error, LocalizedError {
    case noCodecParameters
    case unsupportedCodec(id: UInt32)
    case noExtradata
    case formatDescriptionFailed(status: OSStatus)
    case sessionCreationFailed(status: OSStatus)
    /// `DualLayerVideoDecoder` is single use (dolby-vision-fel.md §5.8): `open` after `close` refuses
    /// with this instead of inheriting the previous stream's state. Thrown rather than a
    /// trapping precondition so host misuse surfaces as an error and tests can assert it.
    case decoderClosed
    /// No Metal device or shader compilation failed; FEL composition cannot run.
    /// Thrown from `open()` for a decoder built without a composer. The software host does not get
    /// there in production: it builds the composer first and decodes the base layer alone when that
    /// fails.
    case composerUnavailable

    var errorDescription: String? {
        switch self {
        case .noCodecParameters: "No codec parameters"
        case .unsupportedCodec(let id): "Unsupported video codec (id: \(id))"
        case .noExtradata: "Missing codec extradata"
        case .formatDescriptionFailed(let s): "Format description failed (\(s))"
        case .sessionCreationFailed(let s): "Decoder session failed (\(s))"
        case .decoderClosed: "Decoder is closed (single use)"
        case .composerUnavailable: "Dolby Vision FEL composer unavailable (no Metal device or shader compilation failed)"
        }
    }
}

/// FFmpeg-to-CoreVideo color metadata mapping shared by SW and HW decoders (single source of truth for primaries/transfer/matrix).
enum ColorAttachments {
    static func primaries(_ v: AVColorPrimaries) -> CFString? {
        switch v {
        case AVCOL_PRI_BT709:    kCVImageBufferColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT2020:   kCVImageBufferColorPrimaries_ITU_R_2020
        case AVCOL_PRI_SMPTE432: kCVImageBufferColorPrimaries_P3_D65
        case AVCOL_PRI_SMPTE431: kCVImageBufferColorPrimaries_DCI_P3
        case AVCOL_PRI_SMPTE170M, AVCOL_PRI_SMPTE240M: kCVImageBufferColorPrimaries_SMPTE_C
        case AVCOL_PRI_BT470BG:  kCVImageBufferColorPrimaries_EBU_3213
        // H.273 code point 22, which CoreVideo's own code-point table maps to P22.
        case AVCOL_PRI_EBU3213:  kCVImageBufferColorPrimaries_P22
        // BT.470M, FILM (illuminant C) and SMPTE 428 (XYZ) have no CoreVideo constant; see `unmapped`.
        default:                 nil
        }
    }

    static func transfer(_ v: AVColorTransferCharacteristic) -> CFString? {
        switch v {
        // BT.601 and the SDR BT.2020 codepoints name the BT.709 curve, CoreVideo has one constant for all.
        case AVCOL_TRC_BT709, AVCOL_TRC_SMPTE170M, AVCOL_TRC_BT2020_10, AVCOL_TRC_BT2020_12:
            kCVImageBufferTransferFunction_ITU_R_709_2
        case AVCOL_TRC_SMPTE2084:    kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        case AVCOL_TRC_IEC61966_2_1: kCVImageBufferTransferFunction_sRGB
        case AVCOL_TRC_LINEAR:       kCVImageBufferTransferFunction_Linear
        case AVCOL_TRC_SMPTE240M:    kCVImageBufferTransferFunction_SMPTE_240M_1995
        case AVCOL_TRC_SMPTE428:     kCVImageBufferTransferFunction_SMPTE_ST_428_1
        // A pure power curve: the exponent rides in `kCVImageBufferGammaLevelKey`, see `gammaLevel`.
        case AVCOL_TRC_GAMMA22, AVCOL_TRC_GAMMA28: kCVImageBufferTransferFunction_UseGamma
        default:                     nil
        }
    }

    /// The exponent `kCVImageBufferTransferFunction_UseGamma` stands for, nil for every other curve.
    static func gammaLevel(_ v: AVColorTransferCharacteristic) -> Double? {
        switch v {
        case AVCOL_TRC_GAMMA22: 2.2
        case AVCOL_TRC_GAMMA28: 2.8
        default:                nil
        }
    }

    static func matrix(_ v: AVColorSpace) -> CFString? {
        switch v {
        case AVCOL_SPC_BT709:                       kCVImageBufferYCbCrMatrix_ITU_R_709_2
        // CoreVideo has one BT.2020 matrix, the non-constant-luminance one; a constant-luminance
        // picture is decoded with it, slightly off in saturated colours (see `unmapped`).
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: kCVImageBufferYCbCrMatrix_ITU_R_2020
        case AVCOL_SPC_SMPTE170M, AVCOL_SPC_BT470BG: kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case AVCOL_SPC_SMPTE240M:                   kCVImageBufferYCbCrMatrix_SMPTE_240M_1995
        default:                                    nil
        }
    }

    struct Tags: Equatable {
        var primaries: CFString
        var transfer: CFString
        var matrix: CFString
        /// The exponent when `transfer` is `kCVImageBufferTransferFunction_UseGamma`.
        var gammaLevel: Double? = nil
    }

    /// The declared values CoreVideo cannot carry, for a once-per-stream line: nil when everything the
    /// stream declares reached a CoreVideo constant (or was undeclared, which `presented` fills).
    static func unmapped(_ d: ColorDescription) -> String? {
        var gaps: [String] = []
        switch d.primaries {
        case AVCOL_PRI_BT470M: gaps.append("primaries BT.470M")
        case AVCOL_PRI_FILM: gaps.append("primaries FILM (illuminant C)")
        case AVCOL_PRI_SMPTE428: gaps.append("primaries SMPTE 428 (XYZ)")
        default: break
        }
        if d.matrix == AVCOL_SPC_BT2020_CL { gaps.append("BT.2020 constant-luminance matrix (tagged non-constant)") }
        return gaps.isEmpty ? nil : gaps.joined(separator: ", ")
    }

    /// AE#654: the tags a software-decoded buffer is presented with, gaps filled the way VideoToolbox
    /// fills them on the hardware path. A buffer without tags is not read as BT.709 by the display
    /// layer, the report has it going out in the panel's own gamut, so one untagged file looked two
    /// ways depending on which decoder the route picked. Measured
    /// on VideoToolbox's output (`ColorInfoGuessedBy`): nothing declared reads as BT.709 in all three,
    /// at 720x480 and 720x576 as much as at 1080p and for MPEG-2 as much as H.264, and a lone BT.601
    /// matrix gets SMPTE-C primaries and the BT.709 curve.
    ///
    /// #6: `frameSize` departs from VideoToolbox on purpose, for a picture that declares neither a
    /// matrix nor primaries. What lands on the software route untagged is overwhelmingly DVD MPEG-2 and
    /// SD broadcast, which was mastered BT.601, and decoding it with the BT.709 matrix shifts every
    /// saturated colour (reds go orange, greens go yellow). The guess is mpv's: SD (narrower than 1280
    /// and no taller than 576) is the BT.601 matrix, with EBU 3213 primaries for the 625-line heights
    /// (576, 288) and SMPTE-C for the rest (480 / 486 NTSC and other SD sizes); anything larger is
    /// BT.709. The curve stays BT.709 either way, which is what BT.1886 SD is tagged as. The hardware
    /// decoder tags such a stream the same way, and stills pass their frame size, so every path agrees;
    /// nil keeps the VideoToolbox answer.
    static func presented(_ d: ColorDescription, frameSize: (width: Int32, height: Int32)? = nil) -> Tags {
        let declaredPrimaries = primaries(d.primaries)
        let declaredMatrix = matrix(d.matrix)
        let bt709 = kCVImageBufferColorPrimaries_ITU_R_709_2
        let bt601Matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4
        let bt2020Matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
        let bt2020Primaries = kCVImageBufferColorPrimaries_ITU_R_2020
        let smpteC = kCVImageBufferColorPrimaries_SMPTE_C
        let ebu = kCVImageBufferColorPrimaries_EBU_3213

        if declaredPrimaries == nil, declaredMatrix == nil, let size = frameSize,
           size.width < 1280, size.height <= 576 {
            return Tags(
                primaries: size.height == 576 || size.height == 288 ? ebu : smpteC,
                transfer: transfer(d.transfer) ?? kCVImageBufferTransferFunction_ITU_R_709_2,
                matrix: bt601Matrix,
                gammaLevel: gammaLevel(d.transfer))
        }

        let resolvedPrimaries: CFString = declaredPrimaries ?? {
            switch declaredMatrix {
            case bt601Matrix?:  smpteC
            case bt2020Matrix?: bt2020Primaries
            default:            bt709
            }
        }()
        let resolvedMatrix: CFString = declaredMatrix ?? {
            switch declaredPrimaries {
            case smpteC?, ebu?:     bt601Matrix
            case bt2020Primaries?:  bt2020Matrix
            default:                kCVImageBufferYCbCrMatrix_ITU_R_709_2
            }
        }()
        return Tags(
            primaries: resolvedPrimaries,
            transfer: transfer(d.transfer) ?? kCVImageBufferTransferFunction_ITU_R_709_2,
            matrix: resolvedMatrix,
            gammaLevel: gammaLevel(d.transfer))
    }

    /// The colour space CoreVideo manages a buffer with these tags in, i.e. the one playback shows the
    /// picture in. An RGB still converted from the same picture has to carry it: tagged sRGB instead,
    /// a BT.709 still drew 8 levels darker than VideoToolbox's own conversion of the frame, and an SDR
    /// BT.2020 one up to 57 levels off in red.
    static func colorSpace(for tags: Tags) -> CGColorSpace? {
        let attachments = NSMutableDictionary(dictionary: [
            kCVImageBufferColorPrimariesKey: tags.primaries,
            kCVImageBufferTransferFunctionKey: tags.transfer,
            kCVImageBufferYCbCrMatrixKey: tags.matrix,
        ])
        if let gamma = tags.gammaLevel { attachments[kCVImageBufferGammaLevelKey] = gamma }
        return CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue()
    }

    /// PQ (ST 2084) or HLG transfer means the stream is HDR.
    static func isHDRTransfer(_ trc: AVColorTransferCharacteristic) -> Bool {
        trc == AVCOL_TRC_SMPTE2084 || trc == AVCOL_TRC_ARIB_STD_B67
    }
}

/// HDR10 static metadata, SMPTE ST 2086 mastering display and CTA-861.3 content light level, in the
/// form CoreVideo carries it: `kCVImageBufferMasteringDisplayColorVolumeKey` and
/// `kCVImageBufferContentLightLevelInfoKey` hold the big-endian HEVC SEI payloads, not a dictionary.
/// The colour attachments alone were all a software-decoded buffer ever got, so an HDR10 file
/// decoded in software reached the display layer with no mastering peak and no MaxCLL, and the tone
/// mapping the layer does for a panel dimmer than the grade had nothing to map from.
///
/// Held as `NSData` so a decoder can keep one instance per stream and attach the same object to every
/// frame: the per-frame cost is a comparison, and the renderer's format-description cache key sees
/// equal bytes. `@unchecked Sendable`: every payload is immutable `NSData`, never `NSMutableData`.
///
/// Also carries the H.274 ambient viewing environment (`kCVImageBufferAmbientViewingEnvironmentKey`),
/// the room the grade was made for, which travels the same way and has the same lifetime.
struct HDRStaticMetadata: Equatable, @unchecked Sendable {
    var masteringDisplay: NSData?
    var contentLightLevel: NSData?
    var ambientViewingEnvironment: NSData?

    static let none = HDRStaticMetadata()

    init(masteringDisplay: NSData? = nil, contentLightLevel: NSData? = nil, ambientViewingEnvironment: NSData? = nil) {
        self.masteringDisplay = masteringDisplay
        self.contentLightLevel = contentLightLevel
        self.ambientViewingEnvironment = ambientViewingEnvironment
    }

    /// What the decoded frame carries. libavcodec puts the bitstream's SEI / AV1 metadata OBU here,
    /// and the container's declaration too when the bitstream has none (`ff_decode_frame_props`).
    init(frame: UnsafePointer<AVFrame>) {
        if let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA),
           let raw = sd.pointee.data, sd.pointee.size >= MemoryLayout<AVMasteringDisplayMetadata>.size {
            let value = UnsafeRawPointer(raw).loadUnaligned(as: AVMasteringDisplayMetadata.self)
            masteringDisplay = Self.masteringDisplayPayload(value).map { $0 as NSData }
        }
        if let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL),
           let raw = sd.pointee.data, sd.pointee.size >= MemoryLayout<AVContentLightMetadata>.size {
            let value = UnsafeRawPointer(raw).loadUnaligned(as: AVContentLightMetadata.self)
            contentLightLevel = Self.contentLightLevelPayload(value).map { $0 as NSData }
        }
        if let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_AMBIENT_VIEWING_ENVIRONMENT),
           let raw = sd.pointee.data, sd.pointee.size >= MemoryLayout<AVAmbientViewingEnvironment>.size {
            let value = UnsafeRawPointer(raw).loadUnaligned(as: AVAmbientViewingEnvironment.self)
            ambientViewingEnvironment = Self.ambientViewingEnvironmentPayload(value).map { $0 as NSData }
        }
    }

    /// What the container declared (Matroska's MasteringMetadata, MP4's `mdcv` / `clli`), for a
    /// frame that arrives without it.
    init(codecpar: UnsafePointer<AVCodecParameters>) {
        let sideData = codecpar.pointee.coded_side_data
        let count = codecpar.pointee.nb_coded_side_data
        if let sd = av_packet_side_data_get(sideData, count, AV_PKT_DATA_MASTERING_DISPLAY_METADATA),
           let raw = sd.pointee.data, sd.pointee.size >= MemoryLayout<AVMasteringDisplayMetadata>.size {
            let value = UnsafeRawPointer(raw).loadUnaligned(as: AVMasteringDisplayMetadata.self)
            masteringDisplay = Self.masteringDisplayPayload(value).map { $0 as NSData }
        }
        if let sd = av_packet_side_data_get(sideData, count, AV_PKT_DATA_CONTENT_LIGHT_LEVEL),
           let raw = sd.pointee.data, sd.pointee.size >= MemoryLayout<AVContentLightMetadata>.size {
            let value = UnsafeRawPointer(raw).loadUnaligned(as: AVContentLightMetadata.self)
            contentLightLevel = Self.contentLightLevelPayload(value).map { $0 as NSData }
        }
        if let sd = av_packet_side_data_get(sideData, count, AV_PKT_DATA_AMBIENT_VIEWING_ENVIRONMENT),
           let raw = sd.pointee.data, sd.pointee.size >= MemoryLayout<AVAmbientViewingEnvironment>.size {
            let value = UnsafeRawPointer(raw).loadUnaligned(as: AVAmbientViewingEnvironment.self)
            ambientViewingEnvironment = Self.ambientViewingEnvironmentPayload(value).map { $0 as NSData }
        }
    }

    /// Per field, own value first: the bitstream's SEI is the grade, the container's a fallback.
    func filled(from fallback: HDRStaticMetadata) -> HDRStaticMetadata {
        HDRStaticMetadata(masteringDisplay: masteringDisplay ?? fallback.masteringDisplay,
                          contentLightLevel: contentLightLevel ?? fallback.contentLightLevel,
                          ambientViewingEnvironment: ambientViewingEnvironment ?? fallback.ambientViewingEnvironment)
    }

    /// The 24-byte `mastering_display_colour_volume` SEI payload (H.265 D.2.28): the three display
    /// primaries in G, B, R order, then the white point, as x/y pairs in 0.00002 units, then the
    /// maximum and minimum luminance in 0.0001 cd/m². FFmpeg's primaries are R, G, B. nil unless both
    /// halves are present, because the attachment has no way to say "unknown" for either.
    static func masteringDisplayPayload(_ m: AVMasteringDisplayMetadata) -> Data? {
        guard m.has_primaries != 0, m.has_luminance != 0 else { return nil }
        func chromaticity(_ r: AVRational) -> UInt16? {
            guard r.den != 0 else { return nil }
            let v = (av_q2d(r) * 50000).rounded()
            guard v.isFinite, v >= 0, v <= 50000 else { return nil }
            return UInt16(v)
        }
        func luminance(_ r: AVRational) -> UInt32? {
            guard r.den != 0 else { return nil }
            let v = (av_q2d(r) * 10000).rounded()
            guard v.isFinite, v >= 0, v <= Double(UInt32.max) else { return nil }
            return UInt32(v)
        }
        let p = m.display_primaries
        guard let gx = chromaticity(p.1.0), let gy = chromaticity(p.1.1),
              let bx = chromaticity(p.2.0), let by = chromaticity(p.2.1),
              let rx = chromaticity(p.0.0), let ry = chromaticity(p.0.1),
              let wx = chromaticity(m.white_point.0), let wy = chromaticity(m.white_point.1),
              let maxL = luminance(m.max_luminance), let minL = luminance(m.min_luminance) else { return nil }
        var bytes = Data(capacity: 24)
        for v in [gx, gy, bx, by, rx, ry, wx, wy] { withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) } }
        for v in [maxL, minL] { withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) } }
        return bytes
    }

    /// The 4-byte `content_light_level_info` SEI payload (H.265 D.2.35): MaxCLL, then MaxFALL, in
    /// cd/m². Zero is the standard's "unknown" and is carried as such; a pair of zeros says nothing
    /// and is dropped.
    static func contentLightLevelPayload(_ c: AVContentLightMetadata) -> Data? {
        guard c.MaxCLL != 0 || c.MaxFALL != 0 else { return nil }
        var bytes = Data(capacity: 4)
        for v in [UInt16(clamping: c.MaxCLL), UInt16(clamping: c.MaxFALL)] {
            withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    /// The 8-byte `ambient_viewing_environment` SEI payload (H.274 8.28): the ambient illuminance in
    /// 0.0001 lux (u32), then the ambient light's x / y chromaticity in 0.00002 units (u16 each).
    static func ambientViewingEnvironmentPayload(_ a: AVAmbientViewingEnvironment) -> Data? {
        guard a.ambient_illuminance.den != 0, a.ambient_light_x.den != 0, a.ambient_light_y.den != 0 else { return nil }
        let lux = (av_q2d(a.ambient_illuminance) * 10000).rounded()
        let x = (av_q2d(a.ambient_light_x) * 50000).rounded(), y = (av_q2d(a.ambient_light_y) * 50000).rounded()
        guard lux >= 1, lux <= Double(UInt32.max), x >= 0, x <= 50000, y >= 0, y <= 50000 else { return nil }
        var bytes = Data(capacity: 8)
        withUnsafeBytes(of: UInt32(lux).bigEndian) { bytes.append(contentsOf: $0) }
        for v in [UInt16(x), UInt16(y)] { withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) } }
        return bytes
    }

    /// Write every attachment, removing a missing one: pool buffers are recycled across frames and a
    /// stale value from an earlier stream must not survive on them.
    func attach(to buffer: CVBuffer) {
        if let masteringDisplay {
            CVBufferSetAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, masteringDisplay, .shouldPropagate)
        } else {
            CVBufferRemoveAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey)
        }
        if let contentLightLevel {
            CVBufferSetAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, contentLightLevel, .shouldPropagate)
        } else {
            CVBufferRemoveAttachment(buffer, kCVImageBufferContentLightLevelInfoKey)
        }
        if let ambientViewingEnvironment {
            CVBufferSetAttachment(buffer, kCVImageBufferAmbientViewingEnvironmentKey, ambientViewingEnvironment, .shouldPropagate)
        } else {
            CVBufferRemoveAttachment(buffer, kCVImageBufferAmbientViewingEnvironmentKey)
        }
    }

    /// Fill only what the buffer does not already carry. For VideoToolbox output, where the
    /// decoder's own per-frame SEI (`PropagatePerFrameHDRDisplayMetadata`) is the better source and
    /// the container's declaration is the fallback.
    func attachWhereAbsent(to buffer: CVBuffer) {
        if let masteringDisplay,
           CVBufferCopyAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) == nil {
            CVBufferSetAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, masteringDisplay, .shouldPropagate)
        }
        if let contentLightLevel,
           CVBufferCopyAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, nil) == nil {
            CVBufferSetAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, contentLightLevel, .shouldPropagate)
        }
        if let ambientViewingEnvironment,
           CVBufferCopyAttachment(buffer, kCVImageBufferAmbientViewingEnvironmentKey, nil) == nil {
            CVBufferSetAttachment(buffer, kCVImageBufferAmbientViewingEnvironmentKey, ambientViewingEnvironment, .shouldPropagate)
        }
    }
}
