import CoreVideo
import Testing
import AetherLibavutil
@testable import AetherEngine

/// Display buffers and their frames for the deinterlacer tests: the filter takes what
/// `PlanarFrameFinisher` writes, a buffer with `SoftwareVideoDecoder.displayBufferAttributes`,
/// described by its decoded frame.
enum DeinterlaceTestInput {

    /// Whether the linked build and this machine can build the graph at all (a Metal device; CI VMs
    /// may have none). Built once: the probe stands up and tears down a whole filter graph.
    static let available = DeinterlaceFilter.prewarmHardwarePipeline()
    static let needsHardware: Comment = "needs yadif_videotoolbox and a Metal device"

    /// A buffer of `type`, every plane filled with alternating light and dark rows, so the two fields
    /// differ and the kernel has something to interpolate.
    static func buffer(_ type: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                       width: Int = 64, height: Int = 64) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, type,
                                  SoftwareVideoDecoder.displayBufferAttributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                memset(base + row * stride, row % 2 == 0 ? 0xC0 : 0x40, stride)
            }
        }
        return buffer
    }

    /// The decoded frame a buffer stands for: an interlaced, top-field-first picture at `pts`.
    static func properties(pts: Int64, sar: AVRational = AVRational(num: 1, den: 1)) -> UnsafeMutablePointer<AVFrame> {
        let f = av_frame_alloc()!
        f.pointee.pts = pts
        f.pointee.sample_aspect_ratio = sar
        f.pointee.flags |= AV_FRAME_FLAG_INTERLACED | AV_FRAME_FLAG_TOP_FIELD_FIRST
        return f
    }

    struct Run {
        /// Output PTS converted through `outputTimeBase`.
        var seconds: [Double] = []
        var built = true
    }

    /// Pushes `count` buffers made by `make` (one per frame, at pts 0, 1, ...) and pulls everything the
    /// filter puts out, handing each output frame to `onFrame` before it is unreferenced.
    static func run(_ filter: DeinterlaceFilter, count: Int64, timeBase: AVRational = AVRational(num: 1, den: 30),
                    sar: AVRational = AVRational(num: 1, den: 1),
                    make: () -> CVPixelBuffer? = { buffer() },
                    onFrame: ((UnsafeMutablePointer<AVFrame>) -> Void)? = nil) -> Run {
        var run = Run()
        let out = av_frame_alloc()!
        defer { var o: UnsafeMutablePointer<AVFrame>? = out; av_frame_free(&o) }
        for pts in Int64(0)..<count {
            guard let pb = make() else { run.built = false; return run }
            var f: UnsafeMutablePointer<AVFrame>? = properties(pts: pts, sar: sar)
            defer { av_frame_free(&f) }
            guard filter.ensureGraph(buffer: pb, properties: f!, timeBase: timeBase),
                  filter.push(pb, properties: f!) >= 0 else { run.built = false; return run }
            let outTB = filter.outputTimeBase
            while filter.pull(into: out) >= 0 {
                if out.pointee.pts != Int64.min {
                    run.seconds.append(Double(out.pointee.pts) * Double(outTB.num) / Double(outTB.den))
                }
                onFrame?(out)
                av_frame_unref(out)
            }
        }
        return run
    }

    static func pixelBuffer(of frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        guard frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue, let raw = frame.pointee.data.3 else { return nil }
        return Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(raw)).takeUnretainedValue()
    }
}
