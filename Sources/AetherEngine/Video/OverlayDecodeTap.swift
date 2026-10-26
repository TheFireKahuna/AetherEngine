import Foundation
import CoreMedia
import QuartzCore
import os
import CoreVideo
import AetherLibavcodec
import AetherLibavutil

/// The source video of a software overlay session (`HLSVideoEngine.overlayDecodesVideo`), decoded near AVPlayer's
/// clock for ``DecodedPictureSource``.
///
/// The segment producer hands over every video packet before the placeholder takes its place, with output
/// (item-axis) timestamps, in decode order. One decoder serves the session: VideoToolbox for an HEVC stream it opens
/// a hardware session for (`VTCapabilityProbe`), as on every other route, and `SoftwareVideoDecoder` otherwise. A seek
/// or a new run flushes it and never reopens it, so its sessions, slabs, the finisher's pipelines and its buffer
/// pool stay warm, and the pictures between the keyframe and the clock are decoded as references only. Its
/// pictures are on the item axis, deinterlaced, film-matched or retimed as the load decided.
///
/// Captions: an H.264 or HEVC source's are read off its packets by the producer, as on the native route
/// (VideoToolbox surfaces none); any other codec's come from libavcodec's decode, `onCaptions`.
final class OverlayDecodeTap: @unchecked Sendable {

    /// A few pictures at any frame rate: the decoder only has to stay ahead of the refresh that shows them, and a
    /// 4K picture is about 25 MB.
    static let decodeAheadSeconds = 0.2

    /// Each unit's run shift (item axis to source axis, in seconds), for the decoder's captions.
    private let units: OverlayPacketTap<Double>
    /// The source decodes on VideoToolbox.
    let decodesInHardware: Bool

    /// A clock the player moved within this long is AVPlayer's; otherwise the producer's run start stands in for it.
    static let playerClockSeconds = 0.5
    /// A run whose start is this far from the clock is cut ahead of a playing clock: nothing waits for it.
    static let runStartNearClockSeconds = 1.0

    /// Where the current run starts (item seconds), the producer side's; the player's last clock move.
    private let clock = OSAllocatedUnfairLock(initialState: (runStart: Double?.none, playerMoved: -Double.infinity))

    /// `parameters` and `timeBase` are the source stream's, `containerSAR` its container's sample aspect;
    /// `deinterlace` what the load decided for interlaced carriage. `onCaptions` takes the decoder's A53 captions
    /// in presentation order, timed on the source axis.
    init(parameters: UnsafePointer<AVCodecParameters>, timeBase: AVRational, containerSAR: AVRational,
         deinterlace: DeinterlaceConfig,
         onCaptions: @escaping @Sendable ([CCDataParser.CCTriplet], Double) -> Void) {
        let shifts = UnitShifts()
        let codec = parameters.pointee.codec_id
        let hardware = codec == AV_CODEC_ID_HEVC && VTCapabilityProbe.opensHardwareDecoder(codecpar: parameters)
        decodesInHardware = hardware
        let captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)? = codec == AV_CODEC_ID_H264 || codec == AV_CODEC_ID_HEVC
            ? nil : { @Sendable triplets, itemSeconds in onCaptions(triplets, itemSeconds + (shifts.shift(at: itemSeconds) ?? 0)) }
        units = OverlayPacketTap(decodeAheadSeconds: Self.decodeAheadSeconds) { deliver in
            PictureTapDecoder(hardware ? HardwareVideoDecoder() : SoftwareVideoDecoder(),
                              parameters: parameters, timeBase: timeBase, containerSAR: containerSAR,
                              deinterlace: deinterlace, deliver: deliver, onCaptions: captions)
        }
        shifts.units = units
        EngineLog.emit("[OverlayDecodeTap] \(avcodec_get_name(codec).map { String(cString: $0) } ?? "?") on "
                       + (hardware ? "VideoToolbox" : "libavcodec"), category: .swPlayback)
    }

    func close() { units.close() }

    /// Keeps a copy of the source video packet `packet` (output timestamps, decode order) before the placeholder
    /// replaces it. `shiftSeconds` is the producer run's offset from the item axis to the source axis.
    ///
    /// A run's first unit is where AVPlayer's clock is about to be (a load, a resume, a seek), so before the player
    /// moves the clock itself the decode works toward it.
    func keep(_ packet: UnsafePointer<AVPacket>, timeBase: AVRational, shiftSeconds: Double) {
        guard packet.pointee.pts != Int64.min, let copy = av_packet_clone(packet) else { return }
        let seconds = Double(packet.pointee.pts) * av_q2d(timeBase)
        let newRun = units.beginsRun(dts: packet.pointee.dts)
        let playerIdle = clock.withLock { state -> Bool in
            guard newRun || state.runStart == nil else { return false }
            state.runStart = seconds
            return CACurrentMediaTime() - state.playerMoved > Self.playerClockSeconds
        }
        units.insert(pts: packet.pointee.pts, timeBase: timeBase, isKey: packet.pointee.flags & AV_PKT_FLAG_KEY != 0,
                     info: shiftSeconds, packet: copy)
        if playerIdle { units.advance(to: seconds) }
    }

    /// Blocks until the current run's first picture is decoded, when the clock is at or heading for the run's start:
    /// the segment holding it is what AVPlayer prerolls the placeholder on and then starts its clock. True when the
    /// picture is there or nothing needs to wait; false after `timeout` or once `shouldStop` says so.
    func awaitRunStart(timeout: TimeInterval, shouldStop: () -> Bool) -> Bool {
        guard let start = clock.withLock({ $0.runStart }),
              abs(units.clockSeconds - start) < Self.runStartNearClockSeconds else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while !units.hasPicture(near: start, toleranceSeconds: PictureTapDecoder.shownBeforeClockSeconds) {
            if shouldStop() || Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }

    /// The picture on screen at `seconds` (item time) and its own time, nil before the decoder reaches it.
    func picture(atOrBefore seconds: Double) -> OverlayPacketTap<Double>.Picture? {
        units.picture(atOrBefore: seconds)
    }

    /// The pictures to queue for display after `last`, from the one on screen at `seconds` on
    /// (``OverlayPacketTap/pictures(after:atOrBefore:)``).
    func pictures(after last: CMTime?, atOrBefore seconds: Double) -> [OverlayPacketTap<Double>.Picture] {
        units.pictures(after: last, atOrBefore: seconds)
    }

    /// Where AVPlayer's clock is (item time).
    func advance(to seconds: Double) {
        clock.withLock { $0.playerMoved = CACurrentMediaTime() }
        units.advance(to: seconds)
    }

    var held: (units: Int, decoded: Int) { units.held }

    /// The run shift of the unit a caption's picture came from, read through the tap once it exists.
    private final class UnitShifts: @unchecked Sendable {
        weak var units: OverlayPacketTap<Double>?
        func shift(at itemSeconds: Double) -> Double? { units?.unit(at: itemSeconds)?.info }
    }
}

/// A session decoder as an ``OverlayTapDecoder``: opened on the first unit, flushed on a restart.
private final class PictureTapDecoder: OverlayTapDecoder {
    /// How far before the clock a restart still converts pictures: the picture on screen at the clock is the one at
    /// or before it, up to a frame earlier.
    static let shownBeforeClockSeconds = 0.1

    private let decoder: any VideoDecodingPipeline
    /// The tap's own copy: the decoder opens on the tap's thread, whenever the first unit comes.
    private let parameters: HLSVideoEngine.OwnedCodecParameters?
    private let timeBase: AVRational
    private let containerSAR: AVRational
    private let deliver: @Sendable (CVPixelBuffer, CMTime) -> Void
    private var opened = false
    private var failed = false

    init(_ decoder: any VideoDecodingPipeline, parameters: UnsafePointer<AVCodecParameters>, timeBase: AVRational,
         containerSAR: AVRational, deinterlace: DeinterlaceConfig,
         deliver: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void,
         onCaptions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?) {
        self.decoder = decoder
        self.parameters = HLSVideoEngine.OwnedCodecParameters(copying: parameters)
        self.timeBase = timeBase
        self.containerSAR = containerSAR
        self.deliver = deliver
        (decoder as? SoftwareVideoDecoder)?.deinterlaceConfig = deinterlace
        decoder.onA53Captions = onCaptions
    }

    func decode(_ packet: UnsafeMutablePointer<AVPacket>, restarting: Bool, clock: Double, timeBase: AVRational) {
        if !opened, !failed {
            do {
                guard let parameters else { throw VideoDecoderError.noCodecParameters }
                let deliver = deliver
                let handler: DecodedFrameHandler = { picture, pts, _ in deliver(picture, pts) }
                switch decoder {
                case let hardware as HardwareVideoDecoder:
                    try hardware.open(parameters: parameters.ptr, timeBase: self.timeBase, containerSAR: containerSAR, onFrame: handler)
                case let software as SoftwareVideoDecoder:
                    try software.open(parameters: parameters.ptr, timeBase: self.timeBase, containerSAR: containerSAR, onFrame: handler)
                default:
                    throw VideoDecoderError.noCodecParameters
                }
                opened = true
            } catch {
                failed = true
                EngineLog.emit("[OverlayDecodeTap] decoder failed to open: \(error)", category: .swPlayback)
            }
        }
        guard opened else { return }
        // A picture this far before the clock is behind the one on screen by the time it decodes: after a restart,
        // or while a decoder that fell behind catches up. It is not converted, and where nothing references it,
        // not decoded either, so the decode reaches the clock as fast as the references allow.
        let showable = clock - Self.shownBeforeClockSeconds
        let skip = CMTime(seconds: showable, preferredTimescale: 90_000)
        if restarting { decoder.flush() }
        let late = packet.pointee.pts != Int64.min && Double(packet.pointee.pts) * av_q2d(timeBase) < showable
        if restarting || late {
            (decoder as? SoftwareVideoDecoder)?.skipUntilPTS = skip
            (decoder as? HardwareVideoDecoder)?.skipUntilPTS = skip
        }
        (decoder as? SoftwareVideoDecoder)?.discardsNonReferencePictures(late)
        decoder.decode(packet: packet, epoch: nil)
    }

    func close() { decoder.close() }
}
