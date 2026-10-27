import Foundation
import AetherLibavutil
import Dovi

/// The HDR10 static metadata of the master a Dolby Vision RPU reconstructs, for a picture composed from it.
///
/// - Mastering display primaries and white point: level 9, either an index into the predefined set or the
///   chromaticities themselves.
/// - Mastering display luminance: level 6 where it states one, otherwise the display-management data's
///   `source_min_pq` / `source_max_pq`, which are the mastering display's minimum and maximum luminance in 12-bit PQ.
/// - Content light level: level 6's.
///
/// Without level 9 the RPU names no primaries, so the stream's own mastering display is kept and only its luminance
/// rewritten from level 6 (``DolbyVisionLevel6/describingMaster(_:)``).
enum DolbyVisionMasteringDisplay {

    /// Level 9's predefined primaries by `source_primary_index`: red, green, blue and white x, y. P3 D65, BT.709,
    /// BT.2020, BT.601 525 and 625 and P3 DCI are H.273's own (``ColourRepresentation/chromaticities``); then ACES AP0,
    /// S-Gamut and S-Gamut3.Cine.
    static let predefinedPrimaries: [[Double]] = [12, 1, 9, 6, 5, 11].compactMap { ColourRepresentation.chromaticities[$0] } + [
        [0.7347, 0.2653, 0.0, 1.0, 0.0001, -0.077, 0.32168, 0.33767],
        [0.73, 0.28, 0.14, 0.855, 0.10, -0.05, 0.3127, 0.329],
        [0.766, 0.275, 0.225, 0.80, 0.089, -0.087, 0.3127, 0.329],
    ]

    /// `stream` (the decoded picture's own static metadata) rewritten to describe the master `rpu` reconstructs.
    static func staticMetadata(rpu: OpaquePointer, stream: HDRStaticMetadata) -> HDRStaticMetadata {
        let level6 = DolbyVisionLevel6(rpu: rpu)
        var out = level6?.describingMaster(stream) ?? stream
        guard let dm = dovi_rpu_get_vdr_dm_data(rpu) else { return out }
        defer { dovi_rpu_free_vdr_dm_data(dm) }
        guard let primaries = primaries(dm.pointee.dm_data.level9) else { return out }
        let luminance: (min: Double, max: Double)
        if let level6, level6.statesLuminance {
            luminance = (Double(level6.minLuminance) / 10000, Double(level6.maxLuminance))
        } else {
            let source = (min: Double(dm.pointee.source_min_pq), max: Double(dm.pointee.source_max_pq))
            guard source.max > source.min else { return out }
            luminance = (nits(pq: source.min / 4095), nits(pq: source.max / 4095))
        }
        var display = AVMasteringDisplayMetadata()
        func q(_ v: Double) -> AVRational { av_d2q(v, 1 << 30) }
        display.display_primaries = ((q(primaries[0]), q(primaries[1])), (q(primaries[2]), q(primaries[3])),
                                     (q(primaries[4]), q(primaries[5])))
        display.white_point = (q(primaries[6]), q(primaries[7]))
        display.min_luminance = q(luminance.min)
        display.max_luminance = q(luminance.max)
        display.has_primaries = 1
        display.has_luminance = 1
        if let payload = HDRStaticMetadata.masteringDisplayPayload(display) {
            out.masteringDisplay = payload as NSData
        }
        return out
    }

    /// Level 9's primaries: the 17-byte form's own chromaticities (over 32767), or the predefined set its index names.
    static func primaries(_ level9: UnsafePointer<DoviExtMetadataBlockLevel9>?) -> [Double]? {
        guard let l9 = level9?.pointee else { return nil }
        if l9.length >= 17 {
            return [l9.source_primary_red_x, l9.source_primary_red_y, l9.source_primary_green_x, l9.source_primary_green_y,
                    l9.source_primary_blue_x, l9.source_primary_blue_y, l9.source_primary_white_x, l9.source_primary_white_y]
                .map { Double($0) / 32767 }
        }
        let index = Int(l9.source_primary_index)
        return index < predefinedPrimaries.count ? predefinedPrimaries[index] : nil
    }

    /// The luminance, in cd/m², of a normalised PQ signal (the ST 2084 EOTF).
    static func nits(pq e: Double) -> Double {
        let p = pow(max(e, 0), 1 / 78.84375)
        return 10000 * pow(max(p - 0.8359375, 0) / (18.8515625 - 18.6875 * p), 1 / 0.1593017578125)
    }
}
