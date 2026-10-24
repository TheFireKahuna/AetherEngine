// Sources/AetherEngine/Video/IFrameStillBuilder.swift
import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import VideoToolbox

/// AE#682: the SDR trick-play tier an HDR session lists beside its own keyframes. One HEVC Main10 intra frame
/// per keyframe, BT.709, 800 pixels wide: the size AVKit's 400 x 225 point scrub thumbnail fills on a 4K
/// panel, next to the smallest HEVC SDR entry of Apple's HLS Authoring Specification (768 x 432).
///
/// Why SDR, and why video rather than images:
/// - tvOS caps a player with the Scanning role, the one AVKit builds for scrub thumbnails, at SDR. Decoded
///   from the Apple TV's MediaToolbox: the resource arbiter limits Scanning and PIP players while
///   `CelestialShouldLimitHDRConcurrentPlayback()` holds, and `fpfs_StartTrackPlaying` drops a PQ or HLG I-frame
///   tier with CoreMedia -16042. The specification says the same for tvOS: "SDR trick play streams MUST be
///   provided" (6.16).
/// - "Players should prefer video I-frame variants over image sequences"; Motion JPEG exists for third-party
///   devices. HEVC is also several times smaller than JPEG at the same quality, and decodes on the hardware.
/// - 10-bit, like Apple's own SDR HEVC I-frame tiers (Main10, VIDEO-RANGE=SDR): less banding after the tone map.
///
/// The keyframe goes straight into one long-lived decoder, VideoToolbox scales it and maps PQ or HLG to BT.709
/// in one pass (`VTPixelTransferSession`, Apple's own curve), and one hardware encode makes the still; nothing
/// touches the disk. A Dolby Vision profile 5 picture is IPT, which only `DolbyVisionStillConverter` reads, so
/// it takes that converter and then the same encoder. The CODECS the master declares come from a warm-up encode,
/// so they match the `hvcC` in every init.
final class IFrameStillBuilder: @unchecked Sendable {
    static let defaultWidth = 800
    /// A still above this is not expected at this size; it bounds the declared BANDWIDTH.
    static let maxFrameBytes = 256 * 1024
    /// For AVERAGE-BANDWIDTH: a typical still, generous against the specification's 40-55 kbit/s at 1 fps
    /// (about 5-7 KB a frame at 768 x 432).
    static let typicalFrameBytes = 24 * 1024
    /// Built fragments kept in memory (tens of KB each): AVKit asks for the same still more than once, and a
    /// scrub back over ground already covered should cost nothing.
    static let cachedFragments = 1536
    private static let timescale: UInt32 = 90_000
    private static var sdr: ColorAttachments.Tags {
        ColorAttachments.Tags(primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                              transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
                              matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    }

    struct Output {
        let initSegment: Data
        let fragment: Data
    }

    let width: Int
    let height: Int
    /// The master's CODECS for this tier, read off the encoder's own `hvcC`.
    let codecs: String
    let initSegment: Data

    private let decoder: FrameDecodeContext
    private let session: VTCompressionSession
    private let lock = NSLock()
    private var built: [Int: Data] = [:]
    private var builtOrder: [Int] = []
    private var nextPTS: Int64 = 1
    private var loggedFailure = false

    /// nil when no HEVC Main10 encoder can be made or the warm-up encode yields no configuration record.
    init?(decoder: FrameDecodeContext, width: Int, height: Int) {
        self.decoder = decoder
        self.width = width
        self.height = height
        var made: VTCompressionSession?
        guard VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &made) == noErr, let made else {
            EngineLog.emit("[IFrameStill] no HEVC encoder", category: .session)
            return nil
        }
        session = made
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main10_AutoLevel)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 1 as CFNumber)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_Quality, value: 0.7 as CFNumber)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_ColorPrimaries, value: Self.sdr.primaries)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_TransferFunction, value: Self.sdr.transfer)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_YCbCrMatrix, value: Self.sdr.matrix)
        VTCompressionSessionPrepareToEncodeFrames(made)
        var hardware: CFBoolean?
        VTSessionCopyProperty(made, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                              allocator: nil, valueOut: &hardware)

        guard let blank = Self.blankFrame(width: width, height: height),
              let warm = Self.encode(blank, session: made, pts: 0),
              let codecs = HLSVideoEngine.hevcCodecsString(fromConfigRecord: [UInt8](warm.hvcC)) else {
            EngineLog.emit("[IFrameStill] warm-up encode gave no hvcC", category: .session)
            VTCompressionSessionInvalidate(made)
            return nil
        }
        self.codecs = codecs
        let colr = Self.box("colr", Self.cat([Data("nclx".utf8), Self.be16(1), Self.be16(1), Self.be16(1), Data([0x00])]))
        let entry = Self.visualSampleEntry("hvc1", width: width, height: height,
                                           children: [Self.box("hvcC", warm.hvcC), colr])
        initSegment = Self.makeInit(width: width, height: height, sampleEntry: entry)
        EngineLog.emit("[IFrameStill] \(width)x\(height) \(codecs) hardware=\(hardware == kCFBooleanTrue)",
                       category: .session)
    }

    deinit { VTCompressionSessionInvalidate(session) }

    /// Output size for a source of `codedWidth` x `codedHeight` with sample aspect `sar`, even on both axes.
    static func size(codedWidth: Int, codedHeight: Int, sarNum: Int32, sarDen: Int32,
                     maxWidth: Int = defaultWidth) -> (width: Int, height: Int)? {
        guard codedWidth > 0, codedHeight > 0 else { return nil }
        let num = sarNum > 0 ? Double(sarNum) : 1
        let den = sarDen > 0 ? Double(sarDen) : 1
        let displayWidth = Double(codedWidth) * num / den
        let w = min(maxWidth, Int(displayWidth.rounded()))
        let h = Double(w) * Double(codedHeight) / displayWidth
        let even = { (v: Double) in max(2, Int((v / 2).rounded()) * 2) }
        return (even(Double(w)), even(h))
    }

    /// Highest declared bitrate a fragment can reach: the byte cap over the shortest segment.
    static func bandwidth(shortestSegmentSeconds: Double) -> Int {
        let seconds = max(shortestSegmentSeconds, 0.1)
        return Int((Double(maxFrameBytes + 256) * 8 / seconds).rounded(.up))
    }

    /// AVERAGE-BANDWIDTH: a typical still over the mean segment.
    static func averageBandwidth(meanSegmentSeconds: Double) -> Int {
        let seconds = max(meanSegmentSeconds, 0.1)
        return Int((Double(typicalFrameBytes + 256) * 8 / seconds).rounded(.up))
    }

    /// Called on the rendition's serial queue, so the decoder and the encoder are never used from two threads.
    func build(payload: Data, index: Int, startSeconds: Double, durationSeconds: Double) -> Output? {
        if let hit = lock.withLock({ built[index] }) {
            return Output(initSegment: initSegment, fragment: hit)
        }
        do { try decoder.ensureOpen() } catch { return nil }
        guard let picture = decoder.decodeScaledStill(keyframe: payload, width: width, height: height,
                                                      destination: Self.sdr) ?? converted(payload),
              let pts = Optional(lock.withLock { () -> Int64 in defer { nextPTS += 1 }; return nextPTS }),
              let encoded = Self.encode(picture, session: session, pts: pts) else {
            if !loggedFailure {
                loggedFailure = true
                EngineLog.emit("[IFrameStill] no still for idx=\(index)", category: .session)
            }
            return nil
        }
        let fragment = Self.makeFragment(sample: encoded.data, sequence: UInt32(truncatingIfNeeded: index + 1),
                                         startSeconds: startSeconds, durationSeconds: durationSeconds)
        lock.withLock {
            if built.updateValue(fragment, forKey: index) == nil { builtOrder.append(index) }
            if builtOrder.count > Self.cachedFragments { built[builtOrder.removeFirst()] = nil }
        }
        return Output(initSegment: initSegment, fragment: fragment)
    }

    /// The CPU path's picture (Dolby Vision profile 5's converter, or a software decode) drawn into a buffer
    /// the encoder takes.
    private func converted(_ payload: Data) -> CVPixelBuffer? {
        guard let image = decoder.decodeStill(keyframe: payload, targetWidth: width) else { return nil }
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let space = CGColorSpace(name: CGColorSpace.itur_709),
              let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, Self.sdr.primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, Self.sdr.transfer, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, Self.sdr.matrix, .shouldPropagate)
        return buffer
    }

    // MARK: - Encoding

    private final class EncodeResult: @unchecked Sendable {
        var data: Data?
        var hvcC: Data?
    }

    /// One intra frame, synchronously: the sample's length-prefixed NAL units and the encoder's `hvcC`.
    private static func encode(_ buffer: CVPixelBuffer, session: VTCompressionSession,
                               pts: Int64) -> (data: Data, hvcC: Data)? {
        let result = EncodeResult()
        let properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: pts, timescale: 24),
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample),
                  let format = CMSampleBufferGetFormatDescription(sample) else { return }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            let copied = data.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
            }
            guard copied == kCMBlockBufferNoErr else { return }
            let atoms = CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
            result.data = data
            result.hvcC = atoms?["hvcC"] as? Data
        }
        guard status == noErr else { return nil }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard let data = result.data, !data.isEmpty, let hvcC = result.hvcC else { return nil }
        return (data, hvcC)
    }

    /// Black in 10-bit video range, tagged as the stills are, for the warm-up encode.
    private static func blankFrame(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                  attributes, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        for (plane, value) in [(0, UInt16(64 << 6)), (1, UInt16(512 << 6))] {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let count = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane) / 2
            base.assumingMemoryBound(to: UInt16.self).update(repeating: value, count: count)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, sdr.primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, sdr.transfer, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, sdr.matrix, .shouldPropagate)
        return buffer
    }

    // MARK: - ISO BMFF

    static func box(_ type: String, _ body: Data) -> Data {
        var out = Data()
        out.append(be32(UInt32(8 + body.count)))
        out.append(contentsOf: Array(type.utf8))
        out.append(body)
        return out
    }
    private static func fullBox(_ type: String, version: UInt8, flags: UInt32, _ body: Data) -> Data {
        var head = be32(flags & 0x00FF_FFFF)
        head[head.startIndex] = version
        return box(type, cat([head, body]))
    }
    static func be16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func be64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func zeros(_ n: Int) -> Data { Data(count: n) }
    private static let unityMatrix: Data = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]
        .reduce(into: Data()) { $0.append(be32($1)) }
    static func cat(_ parts: [Data]) -> Data { parts.reduce(into: Data()) { $0.append($1) } }

    /// A visual sample entry of `type` with its codec boxes and a square `pasp`.
    static func visualSampleEntry(_ type: String, width: Int, height: Int, children: [Data]) -> Data {
        let pasp = box("pasp", cat([be32(1), be32(1)]))
        return box(type, cat([
            zeros(6), be16(1), zeros(16), be16(UInt16(width)), be16(UInt16(height)),
            be32(0x0048_0000), be32(0x0048_0000), be32(0), be16(1), zeros(32),
            be16(0x0018), be16(0xFFFF)] + children + [pasp]))
    }

    /// A one-track init around `sampleEntry`, on the 90 kHz timescale the fragments use.
    static func makeInit(width: Int, height: Int, sampleEntry entry: Data) -> Data {
        let ftyp = box("ftyp", cat([Data("iso6".utf8), be32(0), Data("iso6mp41".utf8)]))
        let mvhd = fullBox("mvhd", version: 0, flags: 0, cat([
            be32(0), be32(0), be32(timescale), be32(0), be32(0x0001_0000), be16(0x0100),
            zeros(10), unityMatrix, zeros(24), be32(2)]))
        let tkhd = fullBox("tkhd", version: 0, flags: 3, cat([
            be32(0), be32(0), be32(1), be32(0), be32(0), zeros(8), zeros(8), unityMatrix,
            be32(UInt32(width) << 16), be32(UInt32(height) << 16)]))
        let mdhd = fullBox("mdhd", version: 0, flags: 0, cat([
            be32(0), be32(0), be32(timescale), be32(0), be16(0x55C4), be16(0)]))
        let hdlr = fullBox("hdlr", version: 0, flags: 0, cat([
            be32(0), Data("vide".utf8), zeros(12), Data("VideoHandler\0".utf8)]))
        let vmhd = fullBox("vmhd", version: 0, flags: 1, zeros(8))
        let dref = fullBox("dref", version: 0, flags: 0, cat([be32(1), fullBox("url ", version: 0, flags: 1, Data())]))
        let dinf = box("dinf", dref)
        let stsd = fullBox("stsd", version: 0, flags: 0, cat([be32(1), entry]))
        let stts = fullBox("stts", version: 0, flags: 0, be32(0))
        let stsc = fullBox("stsc", version: 0, flags: 0, be32(0))
        let stsz = fullBox("stsz", version: 0, flags: 0, cat([be32(0), be32(0)]))
        let stco = fullBox("stco", version: 0, flags: 0, be32(0))
        let stbl = box("stbl", cat([stsd, stts, stsc, stsz, stco]))
        let minf = box("minf", cat([vmhd, dinf, stbl]))
        let trak = box("trak", cat([tkhd, box("mdia", cat([mdhd, hdlr, minf]))]))
        let trex = fullBox("trex", version: 0, flags: 0, cat([be32(1), be32(1), be32(0), be32(0), be32(0)]))
        return cat([ftyp, box("moov", cat([mvhd, trak, box("mvex", trex)]))])
    }

    /// One sync sample at the plan time: default-base-is-moof, default duration and size, the trun carrying only
    /// the data offset.
    static func makeFragment(sample: Data, sequence: UInt32, startSeconds: Double, durationSeconds: Double) -> Data {
        let start = UInt64(max(0, (startSeconds * Double(timescale)).rounded()))
        let duration = UInt32(max(1, (durationSeconds * Double(timescale)).rounded()))
        let tfhd = fullBox("tfhd", version: 0, flags: 0x02_0018,
                           cat([be32(1), be32(duration), be32(UInt32(sample.count))]))
        let tfdt = fullBox("tfdt", version: 1, flags: 0, be64(start))
        let mfhd = fullBox("mfhd", version: 0, flags: 0, be32(sequence))
        func moof(dataOffset: UInt32) -> Data {
            let trun = fullBox("trun", version: 0, flags: 0x00_0001, cat([be32(1), be32(dataOffset)]))
            return box("moof", cat([mfhd, box("traf", cat([tfhd, tfdt, trun]))]))
        }
        let sized = moof(dataOffset: 0)
        return cat([moof(dataOffset: UInt32(sized.count + 8)), box("mdat", sample)])
    }
}
