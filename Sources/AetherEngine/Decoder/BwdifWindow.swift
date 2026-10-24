import Foundation
import AetherLibavutil

/// Deinterlacer cadence for the software-decode path, resolved from `LoadOptions` at load time and handed to
/// `SoftwareVideoDecoder` before `open`.
struct DeinterlaceConfig: Sendable, Equatable {
    var fieldRate: DeinterlaceFieldRate = .field
}

/// Which deinterlaced pictures to make, and from what: libavfilter/yadif_common.c's scheduling (`ff_yadif_filter_frame`,
/// `return_frame`, `ff_yadif_request_frame`), the part of FFmpeg's bwdif that is not per-sample arithmetic, with
/// `deint=interlaced` and `parity=auto`. The arithmetic runs on the GPU (``PlanarFrameFinisher/Field``); this says
/// which three pictures, which parities, which fields are intra, and the timestamps, as FFmpeg does:
///
/// - A window of three pictures (previous, current, next). The first picture stands in for its own predecessor, and
///   the stream's first field is interpolated from the current field alone (`YADIF_FIELD_END`).
/// - Both fields of the current picture are made once the next picture is in (field rate), or the first alone (frame
///   rate). At the end of the stream the last picture stands in for its own successor, its timestamp extrapolated,
///   and the last field is intra again (`YADIF_FIELD_BACK_END`).
/// - A picture not flagged interlaced, or one next to a progressive repeat-field picture, goes out as it is.
/// - Output timestamps are on the input time base halved (`av_reduce`): the first field at `pts * 2`, the second at
///   `cur + next`, AV_NOPTS_VALUE when either is missing. When the halved base does not reduce into 32 bits FFmpeg
///   keeps the input base, and the second field takes `(cur + next) >> 1`.
///
/// Not thread-safe; the owning decoder serialises access with its lock.
final class BwdifWindow {

    /// A decoded picture held for the window: its frame (a reference, so the decoder's slab stays alive) and where its
    /// planes are. `pts` is the window's own: FFmpeg's end-of-stream clone carries an extrapolated one.
    final class Picture {
        let storage: Storage
        let pts: Int64

        init(storage: Storage, pts: Int64) {
            self.storage = storage
            self.pts = pts
        }

        var frame: UnsafeMutablePointer<AVFrame> { storage.frame }
        var interlaced: Bool { storage.frame.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0 }
        var topFieldFirst: Bool { storage.frame.pointee.flags & AV_FRAME_FLAG_TOP_FIELD_FIRST != 0 }
        var repeatPict: Bool { storage.frame.pointee.repeat_pict != 0 }

        func clone(pts: Int64) -> Picture { Picture(storage: storage, pts: pts) }
    }

    /// Owns a picture's frame reference and, for a picture copied into a slab, the slab; both go when the last
    /// ``Picture`` sharing it does.
    final class Storage {
        let frame: UnsafeMutablePointer<AVFrame>
        let planes: PlanarFrameFinisher.Planes
        private let release: (() -> Void)?

        init(frame: UnsafeMutablePointer<AVFrame>, planes: PlanarFrameFinisher.Planes, release: (() -> Void)?) {
            self.frame = frame
            self.planes = planes
            self.release = release
        }

        deinit {
            var owned: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&owned)
            release?()
        }
    }

    /// The planar formats FFmpeg's bwdif takes (vf_bwdif.c `pix_fmts`), less alpha and RGB, which the deinterlacer
    /// does not read, in the little-endian layouts the deinterlacer writes: its reference is defined on these and no
    /// others, so a picture whose planar equivalent is not one of them goes out as decoded.
    static let referenceFormats: Set<Int32> = Set([
        AV_PIX_FMT_YUV410P, AV_PIX_FMT_YUV411P, AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUV422P, AV_PIX_FMT_YUV440P, AV_PIX_FMT_YUV444P,
        AV_PIX_FMT_YUV420P9LE, AV_PIX_FMT_YUV422P9LE, AV_PIX_FMT_YUV444P9LE,
        AV_PIX_FMT_YUV420P10LE, AV_PIX_FMT_YUV422P10LE, AV_PIX_FMT_YUV444P10LE,
        AV_PIX_FMT_YUV420P12LE, AV_PIX_FMT_YUV422P12LE, AV_PIX_FMT_YUV444P12LE,
        AV_PIX_FMT_YUV420P14LE, AV_PIX_FMT_YUV422P14LE, AV_PIX_FMT_YUV444P14LE,
        AV_PIX_FMT_YUV420P16LE, AV_PIX_FMT_YUV422P16LE, AV_PIX_FMT_YUV444P16LE,
        AV_PIX_FMT_GRAY8, AV_PIX_FMT_GRAY16LE,
    ].map(\.rawValue))

    enum Output {
        /// `picture` as it is, at `pts` on ``outputTimeBase``.
        case picture(Picture, pts: Int64)
        /// A deinterlaced field of `cur`, at `pts` on ``outputTimeBase``.
        case field(prev: Picture, cur: Picture, next: Picture, parity: UInt32, fieldParity: UInt32, intra: Bool, pts: Int64)
    }

    private enum FieldState { case normal, end, backEnd }

    let fieldRate: Bool
    /// The time base of every output timestamp.
    let outputTimeBase: AVRational
    private let ptsMultiplier: Int64

    private var prev: Picture?
    private var cur: Picture?
    private var next: Picture?
    private var currentField = FieldState.normal
    private var framePending = false
    private var eof = false

    init(timeBase: AVRational, fieldRate: Bool) {
        self.fieldRate = fieldRate
        var num: Int32 = 0, den: Int32 = 0
        if av_reduce(&num, &den, Int64(timeBase.num), Int64(timeBase.den) * 2, Int64(Int32.max)) != 0 {
            outputTimeBase = AVRational(num: num, den: den)
            ptsMultiplier = 2
        } else {
            outputTimeBase = timeBase
            ptsMultiplier = 1
        }
    }

    /// Whether a picture is held: once engaged, every picture goes through the window.
    var isActive: Bool { next != nil }

    /// `ff_yadif_filter_frame`.
    func push(_ picture: Picture) -> [Output] {
        var out: [Output] = []
        if framePending { out.append(returnFrame(isSecond: true)) }
        prev = cur
        cur = next
        next = picture
        if cur == nil {
            cur = picture.clone(pts: picture.pts)
            currentField = .end
        }
        guard let prev, let cur, let next else { return out }
        if !cur.interlaced || (!prev.interlaced && prev.repeatPict) || (!next.interlaced && next.repeatPict) {
            self.prev = nil
            out.append(.picture(cur, pts: scaled(cur.pts)))
            return out
        }
        out.append(returnFrame(isSecond: false))
        return out
    }

    /// End of stream (`ff_yadif_request_frame` at EOF): the pending second field, then the last picture's fields with
    /// the picture standing in for its own successor.
    func finish() -> [Output] {
        var out: [Output] = []
        if framePending { out.append(returnFrame(isSecond: true)) }
        guard !eof, let cur, let next else { return out }
        let successor = next.clone(pts: next.pts == Self.noPTS || cur.pts == Self.noPTS ? Self.noPTS : next.pts * 2 - cur.pts)
        currentField = .backEnd
        out += push(successor)
        eof = true
        if framePending { out.append(returnFrame(isSecond: true)) }
        return out
    }

    /// Drops every picture (a seek): the window starts over, as a filter graph rebuilt would.
    func reset() {
        prev = nil
        cur = nil
        next = nil
        currentField = .normal
        framePending = false
        eof = false
    }

    private static let noPTS = Int64.min

    private func scaled(_ pts: Int64) -> Int64 { pts == Self.noPTS ? pts : pts * ptsMultiplier }

    /// `return_frame`.
    private func returnFrame(isSecond: Bool) -> Output {
        guard let prev, let cur, let next else { preconditionFailure("return_frame without a full window") }
        let tff: UInt32 = cur.interlaced ? (cur.topFieldFirst ? 1 : 0) : 1
        if isSecond, currentField == .backEnd { currentField = .end }
        let parity = tff ^ (isSecond ? 0 : 1)
        let intra = currentField == .end
        if currentField == .end { currentField = .normal }
        let pts: Int64
        if isSecond {
            if cur.pts != Self.noPTS, next.pts != Self.noPTS {
                pts = ptsMultiplier == 1 ? (cur.pts + next.pts) >> 1 : cur.pts + next.pts
            } else {
                pts = Self.noPTS
            }
        } else {
            pts = scaled(cur.pts)
        }
        framePending = fieldRate && !isSecond
        return .field(prev: prev, cur: cur, next: next, parity: parity, fieldParity: parity ^ tff, intra: intra, pts: pts)
    }
}
