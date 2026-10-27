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

    /// Where the current run starts and whether the player has moved the clock since (`OverlayRunStart`).
    private let runStart = OverlayRunStart()

    /// `parameters` are the source stream's and `timeBase` the one the session serves video in, which the decoder runs
    /// in so its pictures carry the times their units are served at; `containerSAR` is the container's sample aspect,
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

    /// Keeps a copy of the source video packet `packet` (decode order) before the placeholder replaces it, named and
    /// stamped with `served`, the time AVPlayer is served it at; `opensRun` for a producer's first. `shiftSeconds` is
    /// the producer run's offset from the item axis to the source axis.
    ///
    /// A run opens where AVPlayer is about to start (a load, a resume, a seek), so the decode works toward the picture
    /// it starts on (`OverlayRunStart`).
    func keep(_ packet: UnsafePointer<AVPacket>, opensRun: Bool, served: ServedVideoTime, shiftSeconds: Double) {
        guard served.pts != Int64.min, let copy = av_packet_clone(packet) else { return }
        copy.pointee.pts = served.pts
        copy.pointee.dts = served.dts
        let seconds = Double(served.pts) * av_q2d(served.timeBase)
        if opensRun { units.beginRun() }
        let decodeTo = runStart.noteUnit(at: seconds, opensRun: opensRun)
        units.insert(pts: served.pts, timeBase: served.timeBase, isKey: packet.pointee.flags & AV_PKT_FLAG_KEY != 0,
                     info: shiftSeconds, packet: copy)
        if let decodeTo { units.advance(to: decodeTo) }
    }

    /// Where AVPlayer will start, before the player has a clock (a resume's start position, item time).
    func noteStart(at seconds: Double) {
        runStart.noteStart(at: seconds)
    }

    /// Reads where AVPlayer reports it is (item time, a pending seek's target included); nil once its item is gone.
    func follow(reportedTime read: (@Sendable () -> Double?)?) {
        runStart.follow(reportedTime: read)
    }

    /// Blocks until the picture AVPlayer starts the current run on is decoded (`OverlayRunStart`): the segment holding
    /// it is what AVPlayer prerolls the placeholder on and then starts its clock. True when the picture is there or
    /// nothing needs to wait; false after `timeout`, once the decoder has stalled
    /// (`OverlayRunStart.stalledDecodeSeconds`), or once `shouldStop` says so.
    func awaitRunStart(timeout: TimeInterval, shouldStop: () -> Bool) -> Bool {
        runStart.awaitPicture(decodeClock: { units.clockSeconds }, decodeTo: { units.advance(to: $0) },
                              timeout: timeout, progress: { units.unitsDecoded },
                              hasPicture: { units.hasPictureShown(at: $0) }, shouldStop: shouldStop)
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

    /// Where AVPlayer's clock is (item time). Its staging while an item gets ready is not followed.
    func advance(to seconds: Double) {
        guard runStart.notePlayerMoved(to: seconds) else { return }
        units.advance(to: seconds)
    }

    var held: (units: Int, decoded: Int, bytes: Int) { units.held }

    /// Whether the producer may hand over another packet (``OverlayPacketTap/hasRoomAhead``).
    var hasRoomAhead: Bool { units.hasRoomAhead }

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
