// Sources/AetherEngine/Video/IFrameRenditionEligibility.swift
import Foundation

/// AE#682: whether a session serves the I-frame rendition, and which. Pure, so the rule is testable without a
/// session. The rendition is all or nothing: AVKit shows a stale picture for a keyframe it cannot fetch, so a
/// session that cannot answer every listed entry lists none.
enum IFrameRenditionEligibility {
    enum AbsentReason: String, Equatable {
        case notRequested, live, planNotKeyframeAligned, sequentialOrigin, heldSourceConnection
        case serialOrigin, noSecondReader, mediaPlaylistRouting
        /// A Dolby Vision Profile 5 / 10.0 source in a build without the `DualLayerDolbyVision`
        /// trait: no entry could be answered with a correct picture.
        case dolbyVisionStillsNotBuiltIn
    }

    /// What the entries are.
    enum Timeline: Equatable {
        /// The plan's own keyframes, which its index lists: each entry is a keyframe at its own time.
        case keyframes
        /// A source with no keyframe list whose demuxer still seeks to a time (a transport or program stream,
        /// a DVD title by its time map): one SDR still a second, each the picture at its time, decoded and
        /// encoded as an intra frame. The dense I-frame rendition of Apple's HLS Authoring Specification
        /// (6.2), and the only form in which every entry sits at its own presentation time (RFC 8216bis
        /// 4.4.3.6) without a read of the whole source.
        case stills
    }

    enum Verdict: Equatable {
        case served(Timeline)
        case absent(AbsentReason)

        var isServed: Bool {
            if case .served = self { return true }
            return false
        }
    }

    struct Inputs {
        var requested: Bool
        var isLive: Bool
        var planBoundariesClaimRandomAccess: Bool
        /// The source's demuxer lands a seek to a time without the container's index
        /// (`Demuxer.seeksToTimeWithoutIndex`).
        var seeksToTimeWithoutIndex: Bool
        var sequentialOrigin: Bool
        var heldSourceConnection: Bool
        var originIsSerial: Bool
        var secondReaderAvailable: Bool
        /// The source's frames cannot become a still in this build (`FrameDecodeContext.yieldsStill`).
        var stillsUnavailable = false
    }

    /// Everything except the master decision, which needs this verdict as one of its inputs.
    static func candidate(_ i: Inputs) -> Verdict {
        guard i.requested else { return .absent(.notRequested) }
        if i.isLive { return .absent(.live) }
        let timeline: Timeline
        if i.planBoundariesClaimRandomAccess {
            timeline = .keyframes
        } else if i.seeksToTimeWithoutIndex {
            timeline = .stills
        } else {
            return .absent(.planNotKeyframeAligned)
        }
        if i.sequentialOrigin { return .absent(.sequentialOrigin) }
        if i.heldSourceConnection { return .absent(.heldSourceConnection) }
        if i.originIsSerial { return .absent(.serialOrigin) }
        guard i.secondReaderAvailable else { return .absent(.noSecondReader) }
        if i.stillsUnavailable { return .absent(.dolbyVisionStillsNotBuiltIn) }
        return .served(timeline)
    }

    static func resolve(candidate: Verdict, servingMaster: Bool) -> Verdict {
        guard candidate.isServed else { return candidate }
        return servingMaster ? candidate : .absent(.mediaPlaylistRouting)
    }
}
