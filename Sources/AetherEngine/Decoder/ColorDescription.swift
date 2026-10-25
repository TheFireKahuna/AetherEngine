import Foundation
import AetherLibavutil
import AetherLibavcodec

/// A stream's colour description, held in one place because it arrives from two (AE#499).
///
/// A decoded `AVFrame` carries what the BITSTREAM declared: libavcodec writes the VUI, and a VUI that
/// says nothing leaves the fields `unspecified` rather than falling back to anything. `AVCodecParameters`
/// carries what the CONTAINER declared (Matroska's Colour element, MP4's `colr`), which for a remux is
/// routinely the only place the description exists at all. Neither is authoritative alone, and reading
/// one where the other was meant is what made an HDR still lose its tone map: the extractor gated on
/// `codecpar` (PQ) and handed zscale the frame (unspecified), and zimg has no path to linear from
/// nothing.
///
/// Same shape as `SoftwareVideoDecoder.declaredStreamSAR(bitstream:container:)`, and for the same
/// reason: two declarations of one fact, resolved once so every consumer sees the same answer.
struct ColorDescription: Equatable {
    var primaries: AVColorPrimaries
    var transfer: AVColorTransferCharacteristic
    var matrix: AVColorSpace
    var range: AVColorRange

    static let unspecified = ColorDescription(
        primaries: AVCOL_PRI_UNSPECIFIED,
        transfer: AVCOL_TRC_UNSPECIFIED,
        matrix: AVCOL_SPC_UNSPECIFIED,
        range: AVCOL_RANGE_UNSPECIFIED)

    init(primaries: AVColorPrimaries,
         transfer: AVColorTransferCharacteristic,
         matrix: AVColorSpace,
         range: AVColorRange) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.range = range
    }

    init(frame: UnsafePointer<AVFrame>) {
        self.init(primaries: frame.pointee.color_primaries,
                  transfer: frame.pointee.color_trc,
                  matrix: frame.pointee.colorspace,
                  range: frame.pointee.color_range)
    }

    init(codecpar: UnsafePointer<AVCodecParameters>) {
        self.init(primaries: codecpar.pointee.color_primaries,
                  transfer: codecpar.pointee.color_trc,
                  matrix: codecpar.pointee.color_space,
                  range: codecpar.pointee.color_range)
    }

    /// The description to act on: the bitstream wherever it committed to a value, the container for the
    /// fields it left open. Per field, because a partially filled VUI is the common case and the one
    /// that fails silently (a matrix without a transfer reads HDR to a gate and reads nothing to zimg).
    /// Two silences stay silent: an untagged stream is not improved by inventing BT.709 for it here.
    /// The BT.709 a display needs is chosen where the buffer meets CoreVideo, see
    /// `ColorAttachments.presented` (AE#654), so the HDR gate and the tone mapper still see the gap.
    static func resolved(bitstream: ColorDescription, container: ColorDescription) -> ColorDescription {
        ColorDescription(
            primaries: bitstream.primaries == AVCOL_PRI_UNSPECIFIED ? container.primaries : bitstream.primaries,
            transfer: bitstream.transfer == AVCOL_TRC_UNSPECIFIED ? container.transfer : bitstream.transfer,
            matrix: bitstream.matrix == AVCOL_SPC_UNSPECIFIED ? container.matrix : bitstream.matrix,
            range: bitstream.range == AVCOL_RANGE_UNSPECIFIED ? container.range : bitstream.range)
    }
}

/// The container's description for one stream's frames, field by field, until the bitstream states that field
/// itself (AE#499). A remux whose VUI says nothing is filled from the container throughout. A bitstream that has
/// stated a field and then stops (a later sequence header or SPS without a colour description: a spliced stream, a
/// broadcast programme switch) means unspecified, as the codec standards define it, and stays so: for MPEG-TS the
/// "container" value is the first SPS's own, read by stream probing, so filling from it would bring back the colour
/// the stream just left. Not thread-safe: one per decoder, used where its frames are received.
struct ColourBackfill {
    let container: ColorDescription
    private var statedPrimaries = false
    private var statedTransfer = false
    private var statedMatrix = false
    private var statedRange = false

    init(container: ColorDescription) { self.container = container }

    /// Writes the description to act on back onto a freshly decoded frame, so every consumer downstream (the
    /// finisher, the Dolby Vision still converter, CoreVideo attachments) reads one answer. Returns whether anything
    /// was filled in.
    @discardableResult
    mutating func fill(_ frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        let current = ColorDescription(frame: frame)
        statedPrimaries = statedPrimaries || current.primaries != AVCOL_PRI_UNSPECIFIED
        statedTransfer = statedTransfer || current.transfer != AVCOL_TRC_UNSPECIFIED
        statedMatrix = statedMatrix || current.matrix != AVCOL_SPC_UNSPECIFIED
        statedRange = statedRange || current.range != AVCOL_RANGE_UNSPECIFIED
        let open = ColorDescription(
            primaries: statedPrimaries ? AVCOL_PRI_UNSPECIFIED : container.primaries,
            transfer: statedTransfer ? AVCOL_TRC_UNSPECIFIED : container.transfer,
            matrix: statedMatrix ? AVCOL_SPC_UNSPECIFIED : container.matrix,
            range: statedRange ? AVCOL_RANGE_UNSPECIFIED : container.range)
        let resolved = ColorDescription.resolved(bitstream: current, container: open)
        guard resolved != current else { return false }
        frame.pointee.color_primaries = resolved.primaries
        frame.pointee.color_trc = resolved.transfer
        frame.pointee.colorspace = resolved.matrix
        frame.pointee.color_range = resolved.range
        return true
    }
}
