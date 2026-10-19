import Testing
import CoreVideo
import AetherLibavutil
import AetherLibavcodec
@testable import AetherEngine

// AE#658: the stream facts a stats panel shows, in libav's names plus the labels a viewer reads.
@Suite("Stream format report (AE#658)")
struct StreamFormatReportTests {

    @Test("HDR10 HEVC reads as 10-bit BT.2020 PQ, Main 10")
    func hdr10() {
        let f = VideoStreamFormat(
            pixelFormat: AV_PIX_FMT_YUV420P10LE, declaredBitDepth: 0,
            color: ColorDescription(primaries: AVCOL_PRI_BT2020, transfer: AVCOL_TRC_SMPTE2084,
                                    matrix: AVCOL_SPC_BT2020_NCL, range: AVCOL_RANGE_MPEG),
            codecID: AV_CODEC_ID_HEVC, profile: AV_PROFILE_HEVC_MAIN_10)
        #expect(f.pixelFormat == "yuv420p10le")
        #expect(f.bitDepth == 10)
        #expect(f.profile == "Main 10")
        #expect(f.colorPrimariesLabel == "BT.2020")
        #expect(f.transferLabel == "PQ (SMPTE ST 2084)")
        #expect(f.matrixLabel == "BT.2020 NCL")
        #expect(f.rangeLabel == "Limited")
    }

    @Test("an untagged stream stays untagged instead of reading as BT.709")
    func untagged() {
        let f = VideoStreamFormat(
            pixelFormat: AV_PIX_FMT_YUV420P, declaredBitDepth: 0, color: .unspecified,
            codecID: AV_CODEC_ID_H264, profile: AV_PROFILE_UNKNOWN)
        #expect(f.bitDepth == 8)
        #expect(f.colorPrimaries == nil)
        #expect(f.transfer == nil)
        #expect(f.matrix == nil)
        #expect(f.range == nil)
        #expect(f.profile == nil)
    }

    @Test("HLG and full range get their viewer names")
    func hlgFullRange() {
        let f = VideoStreamFormat(
            pixelFormat: AV_PIX_FMT_YUV420P10LE, declaredBitDepth: 0,
            color: ColorDescription(primaries: AVCOL_PRI_BT2020, transfer: AVCOL_TRC_ARIB_STD_B67,
                                    matrix: AVCOL_SPC_BT2020_NCL, range: AVCOL_RANGE_JPEG),
            codecID: AV_CODEC_ID_HEVC, profile: AV_PROFILE_UNKNOWN)
        #expect(f.transferLabel == "HLG")
        #expect(f.rangeLabel == "Full")
    }

    @Test("an unknown pixel format falls back to the declared sample depth")
    func declaredDepthFallback() {
        let f = VideoStreamFormat(
            pixelFormat: AV_PIX_FMT_NONE, declaredBitDepth: 12, color: .unspecified,
            codecID: AV_CODEC_ID_HEVC, profile: AV_PROFILE_UNKNOWN)
        #expect(f.pixelFormat == nil)
        #expect(f.bitDepth == 12)
    }

    @Test("a name without a label passes through unchanged")
    func unknownLabels() {
        #expect(VideoStreamFormat.primariesLabel("film") == "film")
        #expect(VideoStreamFormat.transferLabel("log100") == "log100")
    }

    @Test("display buffers read as their four-character codes")
    func pixelBuffer() {
        let nv12 = DecodedVideoFormat.fourCC(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let p010 = DecodedVideoFormat.fourCC(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(nv12 == "420v")
        #expect(p010 == "x420")
        #expect(DecodedVideoFormat(frame: .init(pixelFormat: nil, bitDepth: nil, colorPrimaries: nil,
                                                transfer: nil, matrix: nil, range: nil, profile: nil),
                                   pixelBufferFormat: p010).pixelBufferLabel == "P010 (x420)")
        #expect(DecodedVideoFormat(frame: .init(pixelFormat: nil, bitDepth: nil, colorPrimaries: nil,
                                                transfer: nil, matrix: nil, range: nil, profile: nil),
                                   pixelBufferFormat: "sv22").pixelBufferLabel == "P216 (sv22)")
        #expect(DecodedVideoFormat.fourCC(0x0000_0001) == "0x1")
    }

    @Test("a VideoToolbox buffer maps back to the libav format it holds")
    func libavMapping() {
        #expect(DecodedVideoFormat.libavPixelFormat(
            forPixelBufferType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) == AV_PIX_FMT_NV12)
        #expect(DecodedVideoFormat.libavPixelFormat(
            forPixelBufferType: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) == AV_PIX_FMT_P010LE)
        #expect(DecodedVideoFormat.libavPixelFormat(
            forPixelBufferType: kCVPixelFormatType_32BGRA) == AV_PIX_FMT_NONE)
        #expect(DecodedVideoFormat.libavPixelFormat(
            forPixelBufferType: kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange) == AV_PIX_FMT_P216LE)
        #expect(DecodedVideoFormat.libavPixelFormat(
            forPixelBufferType: kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange) == AV_PIX_FMT_P410LE)
    }

    @Test("DTS:X and TrueHD Atmos surface through the profile name")
    func immersiveProfiles() {
        #expect(VideoStreamFormat.profileName(
            codecID: AV_CODEC_ID_DTS, profile: AV_PROFILE_DTS_HD_MA_X) == "DTS-HD MA + DTS:X")
        #expect(VideoStreamFormat.profileName(
            codecID: AV_CODEC_ID_DTS, profile: AV_PROFILE_DTS_HD_MA) == "DTS-HD MA")
        #expect(VideoStreamFormat.profileName(
            codecID: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS) == "Dolby TrueHD + Dolby Atmos")
        #expect(VideoStreamFormat.profileName(codecID: AV_CODEC_ID_AAC, profile: AV_PROFILE_UNKNOWN) == nil)
    }

    @Test("sample format and channel layout use libav's names")
    func audioNames() {
        #expect(Demuxer.sampleFormatName(AV_SAMPLE_FMT_FLTP.rawValue) == "fltp")
        #expect(Demuxer.sampleFormatName(AV_SAMPLE_FMT_S32.rawValue) == "s32")
        #expect(Demuxer.sampleFormatName(AV_SAMPLE_FMT_NONE.rawValue) == nil)

        var layout = AVChannelLayout()
        av_channel_layout_default(&layout, 6)
        #expect(Demuxer.channelLayoutDescription(&layout) == "5.1")
        av_channel_layout_uninit(&layout)
        #expect(Demuxer.channelLayoutDescription(&layout) == nil)
    }
}
