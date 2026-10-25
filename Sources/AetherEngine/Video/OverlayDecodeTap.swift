import Foundation
import CoreMedia
import CoreVideo
import AetherLibavcodec
import AetherLibavutil

/// The source video of a software overlay session (`HLSVideoEngine.overlayDecodesVideo`), decoded near AVPlayer's
/// clock for ``DecodedPictureSource``.
///
/// The segment producer hands over every video packet before the placeholder takes its place, with output
/// (item-axis) timestamps, in decode order. One `SoftwareVideoDecoder` serves the session: a seek or a new run
/// flushes it and never reopens it, so its slabs, the finisher's pipelines and its buffer pool stay warm, and the
/// pictures between the keyframe and the clock are decoded as references only. Its pictures come out in
/// presentation order on the item axis, deinterlaced, film-matched or retimed as the load decided.
final class OverlayDecodeTap: @unchecked Sendable {

    /// A few pictures at any frame rate: the decoder only has to stay ahead of the refresh that shows them, and a
    /// 4K picture is about 25 MB.
    static let decodeAheadSeconds = 0.2

    /// Each unit's run shift (item axis to source axis, in seconds), for the decoder's captions.
    private let units: OverlayPacketTap<Double>

    /// `parameters` and `timeBase` are the source stream's, `containerSAR` its container's sample aspect;
    /// `deinterlace` what the load decided for interlaced carriage. `onCaptions` takes the decoder's A53 captions
    /// in presentation order, timed on the source axis.
    init(parameters: UnsafePointer<AVCodecParameters>, timeBase: AVRational, containerSAR: AVRational,
         deinterlace: DeinterlaceConfig,
         onCaptions: @escaping @Sendable ([CCDataParser.CCTriplet], Double) -> Void) {
        let shifts = UnitShifts()
        units = OverlayPacketTap(decodeAheadSeconds: Self.decodeAheadSeconds) { deliver in
            SoftwareTapDecoder(parameters: parameters, timeBase: timeBase, containerSAR: containerSAR,
                               deinterlace: deinterlace, deliver: deliver) { triplets, itemSeconds in
                onCaptions(triplets, itemSeconds + (shifts.shift(at: itemSeconds) ?? 0))
            }
        }
        shifts.units = units
    }

    func close() { units.close() }

    /// Keeps a copy of the source video packet `packet` (output timestamps, decode order) before the placeholder
    /// replaces it. `shiftSeconds` is the producer run's offset from the item axis to the source axis.
    func keep(_ packet: UnsafePointer<AVPacket>, timeBase: AVRational, shiftSeconds: Double) {
        guard packet.pointee.pts != Int64.min, let copy = av_packet_clone(packet) else { return }
        _ = units.beginsRun(dts: packet.pointee.dts)
        units.insert(pts: packet.pointee.pts, timeBase: timeBase, isKey: packet.pointee.flags & AV_PKT_FLAG_KEY != 0,
                     info: shiftSeconds, packet: copy)
    }

    /// The picture on screen at `seconds` (item time) and its own time, nil before the decoder reaches it.
    func picture(atOrBefore seconds: Double) -> (picture: CVPixelBuffer, seconds: Double)? {
        units.picture(atOrBefore: seconds)
    }

    /// Where AVPlayer's clock is (item time).
    func advance(to seconds: Double) { units.advance(to: seconds) }

    var held: (units: Int, decoded: Int) { units.held }

    /// The run shift of the unit a caption's picture came from, read through the tap once it exists.
    private final class UnitShifts: @unchecked Sendable {
        weak var units: OverlayPacketTap<Double>?
        func shift(at itemSeconds: Double) -> Double? { units?.unit(at: itemSeconds)?.info }
    }
}

/// `SoftwareVideoDecoder` as an ``OverlayTapDecoder``: opened on the first unit, flushed on a restart.
private final class SoftwareTapDecoder: OverlayTapDecoder {
    /// How far before the clock a restart still converts pictures: the picture on screen at the clock is the one at
    /// or before it, up to a frame earlier.
    static let shownBeforeClockSeconds = 0.1

    private let decoder = SoftwareVideoDecoder()
    /// The tap's own copy: the decoder opens on the tap's thread, whenever the first unit comes.
    private let parameters: HLSVideoEngine.OwnedCodecParameters?
    private let timeBase: AVRational
    private let containerSAR: AVRational
    private let deliver: @Sendable (CVPixelBuffer, CMTime) -> Void
    private var opened = false
    private var failed = false

    init(parameters: UnsafePointer<AVCodecParameters>, timeBase: AVRational, containerSAR: AVRational,
         deinterlace: DeinterlaceConfig, deliver: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void,
         onCaptions: @escaping @Sendable ([CCDataParser.CCTriplet], Double) -> Void) {
        self.parameters = HLSVideoEngine.OwnedCodecParameters(copying: parameters)
        self.timeBase = timeBase
        self.containerSAR = containerSAR
        self.deliver = deliver
        decoder.deinterlaceConfig = deinterlace
        decoder.onA53Captions = onCaptions
    }

    func decode(_ packet: UnsafeMutablePointer<AVPacket>, restartingAt clock: Double?, timeBase: AVRational) {
        if !opened, !failed {
            do {
                guard let parameters else { throw VideoDecoderError.noCodecParameters }
                let deliver = deliver
                try decoder.open(parameters: parameters.ptr, timeBase: self.timeBase, containerSAR: containerSAR) { picture, pts, _ in
                    deliver(picture, pts)
                }
                opened = true
            } catch {
                failed = true
                EngineLog.emit("[OverlayDecodeTap] decoder failed to open: \(error)", category: .swPlayback)
            }
        }
        guard opened else { return }
        if let clock {
            decoder.flush()
            decoder.skipUntilPTS = CMTime(seconds: clock - Self.shownBeforeClockSeconds, preferredTimescale: 90_000)
        }
        decoder.decode(packet: packet, epoch: nil)
    }

    func close() { decoder.close() }
}
