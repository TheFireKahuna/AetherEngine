import Foundation
import CoreMedia
import CoreVideo
import Testing
import AetherLibavutil
import AetherLibavcodec
@testable import AetherEngine

/// The software decoder tells the display layer where its subsampled chroma sits
/// (`kCVImageBufferChromaLocation{Top,Bottom}FieldKey`), from the frame's `chroma_location`.
@Suite("Software decoder chroma location")
struct SoftwareChromaLocationTests {

    @Test("4:2:0 maps every FFmpeg siting to its CoreVideo constant")
    func fourTwoZero() {
        let cases: [(AVChromaLocation, CFString)] = [
            (AVCHROMA_LOC_LEFT, kCVImageBufferChromaLocation_Left),
            (AVCHROMA_LOC_CENTER, kCVImageBufferChromaLocation_Center),
            (AVCHROMA_LOC_TOPLEFT, kCVImageBufferChromaLocation_TopLeft),
            (AVCHROMA_LOC_TOP, kCVImageBufferChromaLocation_Top),
            (AVCHROMA_LOC_BOTTOMLEFT, kCVImageBufferChromaLocation_BottomLeft),
            (AVCHROMA_LOC_BOTTOM, kCVImageBufferChromaLocation_Bottom),
        ]
        for (location, expected) in cases {
            #expect(SoftwareVideoDecoder.chromaLocation(location, output: .yuv420, isJPEG: false) == expected)
        }
    }

    @Test("unspecified is left, the MPEG convention, and centre for a JPEG-family picture")
    func unspecified() {
        #expect(SoftwareVideoDecoder.chromaLocation(AVCHROMA_LOC_UNSPECIFIED, output: .yuv420, isJPEG: false)
                == kCVImageBufferChromaLocation_Left)
        #expect(SoftwareVideoDecoder.chromaLocation(AVCHROMA_LOC_UNSPECIFIED, output: .yuv420, isJPEG: true)
                == kCVImageBufferChromaLocation_Center)
    }

    @Test("4:2:2 keeps only the horizontal siting; 4:4:4 has none")
    func otherSubsampling() {
        #expect(SoftwareVideoDecoder.chromaLocation(AVCHROMA_LOC_TOPLEFT, output: .yuv422, isJPEG: false)
                == kCVImageBufferChromaLocation_Left)
        #expect(SoftwareVideoDecoder.chromaLocation(AVCHROMA_LOC_TOP, output: .yuv422, isJPEG: false)
                == kCVImageBufferChromaLocation_Center)
        #expect(SoftwareVideoDecoder.chromaLocation(AVCHROMA_LOC_LEFT, output: .yuv444, isJPEG: false) == nil)
    }

    @Test("a decoded 4:2:0 stream carries the siting on both fields")
    func decodedBufferCarriesIt() throws {
        let data = try #require(Data(base64Encoded: SoftwareDecoderOutputFormatTests.av1TenBitBase64,
                                     options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        defer { demuxer.close() }
        let videoIndex = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIndex))
        let box = Box()
        let decoder = SoftwareVideoDecoder()
        decoder.decodesSingleThreaded = true
        try decoder.open(stream: stream) { buffer, _, _ in box.keep(buffer) }
        defer { decoder.close() }
        while let pkt = try? demuxer.readPacket() {
            if pkt.pointee.stream_index == videoIndex { decoder.decode(packet: pkt) }
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        let buffer = try #require(box.first)
        for key in [kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey] {
            #expect(CVBufferCopyAttachment(buffer, key, nil) as? String == kCVImageBufferChromaLocation_Left as String)
        }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: CVPixelBuffer?
        func keep(_ b: CVPixelBuffer) { lock.withLock { if buffer == nil { buffer = b } } }
        var first: CVPixelBuffer? { lock.withLock { buffer } }
    }}
