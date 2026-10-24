// Tests/AetherEngineTests/IFramePlaylistTextTests.swift
import Testing
import Foundation
@testable import AetherEngine

private final class IFrameMockProvider: HLSSegmentProvider, @unchecked Sendable {
    let served: Bool
    let durations: [Double]
    let supplemental: String?
    let companion: IFrameRenditionFormat?
    let averageBandwidth: Int?
    init(served: Bool, durations: [Double] = [4.0, 4.0, 2.5], supplemental: String? = nil,
         companion: IFrameRenditionFormat? = nil, averageBandwidth: Int? = nil) {
        self.served = served; self.durations = durations; self.supplemental = supplemental
        self.companion = companion; self.averageBandwidth = averageBandwidth
    }
    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { durations.count }
    func segmentDuration(at index: Int) -> Double { durations[index] }
    var playlistType: HLSPlaylistType { .vod }
    var masterCodecs: String? { "hvc1.2.4.L150.B0,ec-3" }
    var masterSupplementalCodecs: String? { supplemental }
    var masterResolution: (width: Int, height: Int)? { (3840, 2160) }
    var masterVideoRange: HLSVideoRange? { .pq }
    var masterBandwidth: Int? { 12_000_000 }
    var masterFrameRate: Double? { 23.976 }
    var masterAverageBandwidth: Int? { averageBandwidth }
    var iFrameRenditionServed: Bool { served }
    var iFrameRenditionFormat: IFrameRenditionFormat? { .keyframes }
    var iFrameCompanionFormat: IFrameRenditionFormat? { companion }
}

struct IFramePlaylistTextTests {
    @Test("master carries one I-frame line, after the variant, with the video codec only")
    func masterLine() {
        let m = HLSLocalServer.buildMasterPlaylistText(provider: IFrameMockProvider(served: true))
        let lines = m.split(separator: "\n").map(String.init)
        let tag = lines.filter { $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") }
        #expect(tag.count == 1)
        #expect(tag[0] == "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=12000000,CODECS=\"hvc1.2.4.L150.B0\","
                + "RESOLUTION=3840x2160,VIDEO-RANGE=PQ,URI=\"iframe.m3u8\"")
        let variantURI = try! #require(lines.firstIndex(of: "media.m3u8"))
        #expect(lines.firstIndex(of: tag[0])! > variantURI)
    }

    @Test("the keyframe tier's AVERAGE-BANDWIDTH is one estimated keyframe over the mean segment, under BANDWIDTH")
    func keyframeAverageBandwidth() {
        // 2.5 frames of 6 Mbit/s at 23.976 over a 3.5 s mean segment.
        let p = IFrameMockProvider(served: true, averageBandwidth: 6_000_000)
        let tag = HLSLocalServer.buildMasterPlaylistText(provider: p)
            .split(separator: "\n").map(String.init)
            .first { $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") }
        #expect(tag == "#EXT-X-I-FRAME-STREAM-INF:AVERAGE-BANDWIDTH=178751,BANDWIDTH=12000000,"
                + "CODECS=\"hvc1.2.4.L150.B0\",RESOLUTION=3840x2160,VIDEO-RANGE=PQ,URI=\"iframe.m3u8\"")
        let heavy = IFrameMockProvider(served: true, durations: [0.05], averageBandwidth: 900_000_000)
        #expect(HLSLocalServer.keyframeAverageBandwidth(provider: heavy, ceiling: 12_000_000) == 12_000_000)
    }

    @Test("an HDR session keeps its Dolby Vision keyframe tier and adds the 10-bit SDR HEVC tier")
    func masterLineForSDRStills() {
        let p = IFrameMockProvider(served: true, supplemental: "dvh1.08.06/db1p",
                                   companion: .sdrStills(width: 800, height: 450, codecs: "hvc1.2.4.L90.B0",
                                                         bandwidth: 1_050_000, averageBandwidth: 50_000))
        let tag = HLSLocalServer.buildMasterPlaylistText(provider: p)
            .split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") }
        #expect(tag == ["#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=12000000,CODECS=\"hvc1.2.4.L150.B0\","
                        + "SUPPLEMENTAL-CODECS=\"dvh1.08.06/db1p\",RESOLUTION=3840x2160,VIDEO-RANGE=PQ,URI=\"iframe.m3u8\"",
                        "#EXT-X-I-FRAME-STREAM-INF:AVERAGE-BANDWIDTH=50000,BANDWIDTH=1050000,VIDEO-RANGE=SDR,"
                        + "CODECS=\"hvc1.2.4.L90.B0\",RESOLUTION=800x450,URI=\"iframe_sdr.m3u8\""])
    }

    @Test("SDR companion paths parse apart from the keyframe tier's")
    func companionPaths() {
        #expect(HLSLocalServer.parseIFramePath("/iframe_sdr12.mp4", resourceName: "iframe_sdr") == 12)
        #expect(HLSLocalServer.parseIFramePath("/iframe_sdr12.mp4") == nil)
        #expect(HLSLocalServer.parseIFramePath("/iframe_sdr_init.mp4", resourceName: "iframe_sdr") == nil)
    }

    @Test("master is untouched when the rendition is not served")
    func masterWithout() {
        let m = HLSLocalServer.buildMasterPlaylistText(provider: IFrameMockProvider(served: false))
        #expect(!m.contains("I-FRAME"))
        #expect(m.hasSuffix("media.m3u8\n"))
    }

    @Test("SUPPLEMENTAL-CODECS rides on the primary master and is dropped on the reduced one")
    func supplementalFollowsVariant() {
        let p = IFrameMockProvider(served: true, supplemental: "dvh1.08.06/db1p")
        let primary = HLSLocalServer.buildMasterPlaylistText(provider: p)
        let reduced = HLSLocalServer.buildMasterPlaylistText(provider: p, variant: .reducedHDR)
        let tag: (String) -> String = { text in
            text.split(separator: "\n").map(String.init).first { $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") }!
        }
        #expect(tag(primary).contains("SUPPLEMENTAL-CODECS=\"dvh1.08.06/db1p\""))
        #expect(!tag(reduced).contains("SUPPLEMENTAL-CODECS"))
        #expect(tag(reduced).contains("URI=\"iframe.m3u8\""))
    }

    @Test("I-frame playlist mirrors the plan one entry per segment")
    func playlist() {
        let p = IFrameMockProvider(served: true)
        let text = HLSLocalServer.buildIFramePlaylistText(provider: p)
        #expect(text == """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-I-FRAMES-ONLY
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="iframe_init.mp4"
        #EXTINF:4.000,
        iframe0.mp4
        #EXTINF:4.000,
        iframe1.mp4
        #EXTINF:2.500,
        iframe2.mp4
        #EXT-X-ENDLIST

        """)
    }

    @Test("I-frame playlist TARGETDURATION equals the media playlist's")
    func targetDurationMatchesMedia() {
        let p = IFrameMockProvider(served: true, durations: [4.0, 9.6, 4.0])
        let media = HLSLocalServer.buildMediaPlaylistText(provider: p)
        let iframe = HLSLocalServer.buildIFramePlaylistText(provider: p)
        let td: (String) -> String? = { t in
            t.split(separator: "\n").map(String.init).first { $0.hasPrefix("#EXT-X-TARGETDURATION:") }
        }
        #expect(td(media) != nil)
        #expect(td(media) == td(iframe))
    }

    @Test("absolute sub-resource base is honoured like in the media playlist")
    func absoluteBase() {
        let p = IFrameMockProvider(served: true, durations: [4.0])
        let text = HLSLocalServer.buildIFramePlaylistText(
            provider: p, subResourceBaseURL: URL(string: "aether-hls://session/")!)
        #expect(text.contains("#EXT-X-MAP:URI=\"aether-hls://session/iframe_init.mp4\""))
        #expect(text.contains("\naether-hls://session/iframe0.mp4\n"))
    }

    @Test("I-frame segment paths parse to their index, and nothing else does",
          arguments: [("/iframe0.mp4", 0), ("/iframe17.mp4", 17), ("/iframe_init.mp4", nil),
                      ("/iframe-1.mp4", nil), ("/iframeX.mp4", nil), ("/iframe.mp4", nil),
                      ("/iframe3.m4s", nil), ("/seg3.mp4", nil)] as [(String, Int?)])
    func parsePath(path: String, expected: Int?) {
        #expect(HLSLocalServer.parseIFramePath(path) == expected)
    }

    @Test("video codec extraction keeps the video entry and falls back to the whole string",
          arguments: [("hvc1.2.4.L150.B0,ec-3", "hvc1.2.4.L150.B0"), ("mp4a.40.2,avc1.640028", "avc1.640028"),
                      ("dvh1.05.06,ec-3", "dvh1.05.06"), ("av01.0.12M.10", "av01.0.12M.10"),
                      ("xyz1.1", "xyz1.1")])
    func videoCodecs(codecs: String, expected: String) {
        #expect(HLSLocalServer.videoCodecs(of: codecs) == expected)
    }
}
