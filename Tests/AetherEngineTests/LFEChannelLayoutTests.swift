import Testing
import Foundation
import AudioToolbox
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// A source's LFE keeps a channel of its own through the software host's resampler and the HLS
/// bridge's encoder, and the bridge's PCM carries every channel where the player will read it.
@Suite("LFE through the channel layouts")
struct LFEChannelLayoutTests {

    private func output(_ name: String) -> ResamplerOutput {
        var layout = AVChannelLayout()
        #expect(av_channel_layout_from_string(&layout, name) >= 0)
        defer { av_channel_layout_uninit(&layout) }
        return withUnsafePointer(to: &layout) { ResamplerOutput(source: $0) }
    }

    @Test("LFE sources the count defaults would drop keep their own order and an exact tag")
    func softwareHostExact() {
        #expect(output("3.1") == ResamplerOutput(channels: 4, exactLayout: "3.1", tag: kAudioChannelLayoutTag_DVD_10))
        #expect(output("4.1") == ResamplerOutput(channels: 5, exactLayout: "4.1", tag: kAudioChannelLayoutTag_DVD_11))
        #expect(output("FL+FR+LFE+BC") == ResamplerOutput(channels: 4, exactLayout: "FL+FR+LFE+BC",
                                                         tag: kAudioChannelLayoutTag_DVD_5))
        #expect(output("FL+FR+LFE+BL+BR") == ResamplerOutput(channels: 5, exactLayout: "FL+FR+LFE+BL+BR",
                                                            tag: kAudioChannelLayoutTag_DVD_6))
    }

    @Test("any other 4- or 5-channel LFE source goes to 5.1; the rest keep their count's layout")
    func softwareHostFallback() {
        #expect(output("FL+FR+LFE+SL+SR") == ResamplerOutput(channels: 6))
        #expect(output("2.1") == ResamplerOutput(channels: 3), "2.1 has its own tag, WAVE_2_1")
        #expect(output("4.0") == ResamplerOutput(channels: 4))
        #expect(output("quad") == ResamplerOutput(channels: 4))
        #expect(output("5.0") == ResamplerOutput(channels: 5))
        #expect(output("5.1") == ResamplerOutput(channels: 6))
        #expect(output("7.1") == ResamplerOutput(channels: 8))
        #expect(output("stereo") == ResamplerOutput(channels: 2))
    }

    /// #401's rule for the exact layouts: the tag names, channel for channel, the order the
    /// resampler writes. tvOS 27.2 expands these tags identically (research notes §3.25).
    @Test("each exact tag names the resampler's order channel for channel", arguments: exactResamplerLayouts.map(\.name))
    func exactTagMatchesOrder(name: String) throws {
        let out = output(name)
        var layout = AVChannelLayout()
        out.makeLayout(into: &layout)
        defer { av_channel_layout_uninit(&layout) }
        let written: [AudioChannelLabel] = (0..<out.channels).map { index in
            switch av_channel_layout_channel_from_index(&layout, UInt32(index)) {
            case AV_CHAN_FRONT_LEFT: kAudioChannelLabel_Left
            case AV_CHAN_FRONT_RIGHT: kAudioChannelLabel_Right
            case AV_CHAN_FRONT_CENTER: kAudioChannelLabel_Center
            case AV_CHAN_LOW_FREQUENCY: kAudioChannelLabel_LFEScreen
            case AV_CHAN_BACK_CENTER: kAudioChannelLabel_CenterSurround
            case AV_CHAN_BACK_LEFT: kAudioChannelLabel_LeftSurround      // the only surround pair
            case AV_CHAN_BACK_RIGHT: kAudioChannelLabel_RightSurround
            default: kAudioChannelLabel_Unknown
            }
        }
        var tag = out.tag
        var size: UInt32 = 0
        try #require(AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, 4, &tag, &size) == noErr)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        try #require(AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, 4, &tag, &size, raw) == noErr)
        let acl = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        let stamped = withUnsafePointer(to: &acl.pointee.mChannelDescriptions) {
            UnsafeBufferPointer(start: UnsafeRawPointer($0).assumingMemoryBound(to: AudioChannelDescription.self),
                                count: Int(acl.pointee.mNumberChannelDescriptions)).map(\.mChannelLabel)
        }
        #expect(stamped == written)
    }

    private func sourceIs(_ layout: String) -> (String) -> Bool { { $0 == layout } }

    @Test("E-AC-3 keeps an LFE source's own layout where it can, 5.1 otherwise")
    func eac3Layout() {
        #expect(AudioBridge.eac3LayoutName(channels: 4, hasLFE: true, sourceIs: sourceIs("3.1")) == "3.1")
        #expect(AudioBridge.eac3LayoutName(channels: 5, hasLFE: true, sourceIs: sourceIs("4.1")) == "4.1")
        #expect(AudioBridge.eac3LayoutName(channels: 4, hasLFE: true, sourceIs: sourceIs("FL+FR+LFE+BC")) == "FL+FR+LFE+BC")
        #expect(AudioBridge.eac3LayoutName(channels: 5, hasLFE: true, sourceIs: sourceIs("FL+FR+LFE+BL+BR")) == "5.1",
                "2/2 + LFE is not one FFmpeg's E-AC-3 encoder takes")
        #expect(AudioBridge.eac3LayoutName(channels: 3, hasLFE: true, sourceIs: sourceIs("2.1")) == nil, "E-AC-3 carries 2.1")
        #expect(AudioBridge.eac3LayoutName(channels: 4, hasLFE: false, sourceIs: sourceIs("4.0")) == nil)
        #expect(AudioBridge.eac3LayoutName(channels: 6, hasLFE: true, sourceIs: sourceIs("5.1")) == nil)
    }

    /// A bridge in `mode` for 48 kHz 24-bit PCM in the layout `name`: its output, and whether that keeps the layout.
    private func bridged(_ name: String, mode: AudioBridgeMode) throws -> (output: AudioBridge.Output, keepsLayout: Bool) {
        let par = try #require(avcodec_parameters_alloc())
        var p: UnsafeMutablePointer<AVCodecParameters>? = par
        defer { avcodec_parameters_free(&p) }
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_PCM_S24LE
        par.pointee.sample_rate = 48_000
        par.pointee.format = AV_SAMPLE_FMT_S32.rawValue
        try #require(av_channel_layout_from_string(&par.pointee.ch_layout, name) >= 0)
        let bridge = try AudioBridge(srcCodecpar: par, srcTimeBase: AVRational(num: 1, den: 48_000), mode: mode)
        defer { bridge.close() }
        let out = try #require(bridge.encoderCodecpar)
        return (bridge.output, av_channel_layout_compare(&out.pointee.ch_layout, &par.pointee.ch_layout) == 0)
    }

    /// PCM goes out as `ipcm`, whose `chnl` names every channel's speaker, so the bridge has no layout of
    /// its own to impose: every layout up to 8 channels, LFE or not, comes out as the source's.
    @Test("PCM output keeps the source's own layout", arguments: ["2.1", "3.0", "quad", "4.0", "3.1", "4.1",
                                                                  "FL+FR+LFE+BC", "FL+FR+LFE+BL+BR", "5.1", "5.1(side)", "7.1"])
    func pcmKeepsTheSourceLayout(name: String) throws {
        let out = try bridged(name, mode: .lossless)
        #expect(out.output == .pcm)
        #expect(out.keepsLayout)
    }

    @Test("the E-AC-3 bridge opens its encoder on every layout it keeps", arguments: AudioBridge.exactEAC3Layouts)
    func eac3TakesExactLayouts(name: String) throws {
        let out = try bridged(name, mode: .surroundCompat)
        #expect(out.output == .eac3)
        #expect(out.keepsLayout)
    }
}
