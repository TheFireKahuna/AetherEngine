import Foundation
import CoreVideo
import AetherLibavcodec
import AetherLibavutil
import Dovi

/// A Dolby Vision master's HDR10 static metadata, as its RPU's level 6 block states it.
///
/// On a Profile 7 disc the base layer is often a grade of its own: its SEI describes that grade, L6 the master the RPU
/// reconstructs. Measured on John Wick: master 0.005 / 4000 nits, MaxCLL 1355 / MaxFALL 332; base layer 0.0001 / 1000
/// nits, 1000 / 227 (research/colour-range-dv, section 6.1). A picture composed from both layers is the master, so the
/// mastering display and light level it carries are L6's, not the base layer's.
struct DolbyVisionLevel6: Equatable, Sendable {
    /// `min_display_mastering_luminance`, in 0.0001 cd/m².
    var minLuminance: UInt16
    /// `max_display_mastering_luminance`, in cd/m².
    var maxLuminance: UInt16
    var maxContentLightLevel: UInt16
    var maxFrameAverageLightLevel: UInt16

    init(minLuminance: UInt16, maxLuminance: UInt16, maxContentLightLevel: UInt16, maxFrameAverageLightLevel: UInt16) {
        self.minLuminance = minLuminance
        self.maxLuminance = maxLuminance
        self.maxContentLightLevel = maxContentLightLevel
        self.maxFrameAverageLightLevel = maxFrameAverageLightLevel
    }

    /// The RPU's L6, nil when it carries none.
    init?(rpu: OpaquePointer) {
        guard let dm = dovi_rpu_get_vdr_dm_data(rpu) else { return nil }
        defer { dovi_rpu_free_vdr_dm_data(dm) }
        guard let l6 = dm.pointee.dm_data.level6 else { return nil }
        self.init(minLuminance: l6.pointee.min_display_mastering_luminance,
                  maxLuminance: l6.pointee.max_display_mastering_luminance,
                  maxContentLightLevel: l6.pointee.max_content_light_level,
                  maxFrameAverageLightLevel: l6.pointee.max_frame_average_light_level)
    }

    /// Whether L6 states a usable mastering luminance: a maximum, and a minimum below it.
    var statesLuminance: Bool {
        maxLuminance > 0 && UInt32(minLuminance) < UInt32(maxLuminance) * 10000
    }

    /// Whether L6 states a light level. 0 / 0 is CTA-861.3's "unknown".
    var statesLightLevel: Bool { maxContentLightLevel != 0 || maxFrameAverageLightLevel != 0 }

    /// `stream`'s HDR10 static metadata rewritten to describe the master. The mastering display's luminance comes from
    /// L6 and its primaries and white point stay the stream's (L6 carries none; master and base layer are graded on
    /// one display), so without a mastering display in `stream` there are no primaries to state and the result has
    /// none either. The light level is L6's, and unknown where L6 says it is unknown: the base layer's figure
    /// describes another grade. The ambient viewing environment is kept.
    func describingMaster(_ stream: HDRStaticMetadata) -> HDRStaticMetadata {
        var out = stream
        if statesLuminance, let base = stream.masteringDisplay as Data?, base.count == 24 {
            var bytes = Data(base.prefix(16))
            for v in [UInt32(maxLuminance) * 10000, UInt32(minLuminance)] {
                withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) }
            }
            out.masteringDisplay = bytes as NSData
        }
        if statesLightLevel {
            var bytes = Data(capacity: 4)
            for v in [maxContentLightLevel, maxFrameAverageLightLevel] {
                withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) }
            }
            out.contentLightLevel = bytes as NSData
        } else {
            out.contentLightLevel = nil
        }
        return out
    }

    /// The same rewrite on a stream's codec parameters, which movenc writes the init's `mdcv` / `clli` from. Returns
    /// what changed, for the log.
    @discardableResult
    func describeMaster(on codecpar: UnsafeMutablePointer<AVCodecParameters>) -> [String] {
        var changed: [String] = []
        if statesLuminance,
           let sd = av_packet_side_data_get(codecpar.pointee.coded_side_data, codecpar.pointee.nb_coded_side_data,
                                            AV_PKT_DATA_MASTERING_DISPLAY_METADATA) {
            sd.pointee.data.withMemoryRebound(to: AVMasteringDisplayMetadata.self, capacity: 1) { m in
                guard m.pointee.has_primaries != 0 else { return }
                m.pointee.max_luminance = AVRational(num: Int32(maxLuminance), den: 1)
                m.pointee.min_luminance = AVRational(num: Int32(minLuminance), den: 10000)
                m.pointee.has_luminance = 1
                changed.append("mdcv luminance \(Double(minLuminance) / 10000) / \(maxLuminance) nits")
            }
        }
        let hasLightLevel = av_packet_side_data_get(codecpar.pointee.coded_side_data, codecpar.pointee.nb_coded_side_data,
                                                    AV_PKT_DATA_CONTENT_LIGHT_LEVEL) != nil
        if statesLightLevel {
            let existing = av_packet_side_data_get(codecpar.pointee.coded_side_data, codecpar.pointee.nb_coded_side_data,
                                                   AV_PKT_DATA_CONTENT_LIGHT_LEVEL).map { UnsafeMutablePointer(mutating: $0) }
            let sd = existing
                ?? av_packet_side_data_new(&codecpar.pointee.coded_side_data, &codecpar.pointee.nb_coded_side_data,
                                           AV_PKT_DATA_CONTENT_LIGHT_LEVEL, MemoryLayout<AVContentLightMetadata>.size, 0)
            if let sd {
                sd.pointee.data.withMemoryRebound(to: AVContentLightMetadata.self, capacity: 1) {
                    $0.pointee.MaxCLL = UInt32(maxContentLightLevel)
                    $0.pointee.MaxFALL = UInt32(maxFrameAverageLightLevel)
                }
                changed.append("clli \(maxContentLightLevel) / \(maxFrameAverageLightLevel)")
            }
        } else if hasLightLevel {
            av_packet_side_data_remove(codecpar.pointee.coded_side_data, &codecpar.pointee.nb_coded_side_data,
                                       AV_PKT_DATA_CONTENT_LIGHT_LEVEL)
            changed.append("clli removed (L6 states it unknown)")
        }
        return changed
    }
}

extension HDRStaticMetadata {
    /// What a buffer carries now.
    init(buffer: CVBuffer) {
        func data(_ key: CFString) -> NSData? { CVBufferCopyAttachment(buffer, key, nil) as? NSData }
        self.init(masteringDisplay: data(kCVImageBufferMasteringDisplayColorVolumeKey),
                  contentLightLevel: data(kCVImageBufferContentLightLevelInfoKey),
                  ambientViewingEnvironment: data(kCVImageBufferAmbientViewingEnvironmentKey))
    }
}
