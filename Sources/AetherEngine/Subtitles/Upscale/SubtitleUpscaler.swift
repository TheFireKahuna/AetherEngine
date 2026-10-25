import CoreGraphics
import CoreVideo
import Foundation
import Metal

/// Upscales a bitmap subtitle (PGS, DVB, DVD, a display set's RGBA picture) 2x with ArtCNN on the Neural Engine,
/// leaving the GPU to the video (``SubtitleUpscaleNeuralEngine``; GPU passes prepare its input and composite its output).
///
/// ArtCNN is a single-channel model, so the picture is split into its alpha and its premultiplied luma, each plane is
/// run through the network, and the colour comes back as the source's chroma interpolated bilinearly (subtitle
/// colour is near-constant across a glyph: the shape lives in alpha and luma) and scaled by the new alpha. The result
/// is premultiplied, alpha clamped to [0, 1] and colour to [0, alpha], so the network's overshoot cannot paint a halo.
/// Output pixels farther than 5 source pixels from any non-transparent pixel are exactly transparent, so the
/// network runs only on the content bounds grown by that support (``SubtitleUpscaleTilePlan``).
///
/// One process-wide device, queue, pipeline set and model set (``prewarm()``); each upscaler keeps its
/// working buffers and window surfaces between calls, so the steady state allocates nothing. An instance runs one
/// picture at a time (calls are serialised); ``upscale(_:)`` runs a burst and waits.
public final class SubtitleUpscaler: @unchecked Sendable {

    /// How the source's colour relates to its alpha. The engine's bitmap subtitles are premultiplied.
    public enum SourceAlpha: Sendable, Hashable {
        case premultiplied
        case straight
    }

    public struct Configuration: Sendable, Hashable {
        /// The network on the alpha plane: the outline's outer edge, against the video.
        public var alphaModel: ArtCNNModel
        /// The network on the premultiplied luma plane: the fill's edge against the outline, the highest-contrast
        /// edge of a light subtitle with a dark outline.
        public var lumaModel: ArtCNNModel

        public init(alphaModel: ArtCNNModel = .c4f32, lumaModel: ArtCNNModel = .c4f32) {
            self.alphaModel = alphaModel
            self.lumaModel = lumaModel
        }

        /// C4F32 on both planes.
        public static let `default` = Configuration()
        public static let c4f32 = Configuration()
        /// C4F32 on luma, C4F16 on alpha, about two thirds of C4F32's work: the colour stays C4F32's (a mean
        /// difference of 0.01 8-bit codes on glyph strips), the outline's outer edge takes C4F16's shape (a mean
        /// 0.8 codes of alpha). The other split, C4F32 on alpha, costs the same and changes the colour as much as
        /// C4F16 everywhere does, because the fill edge is where a subtitle's contrast is.
        public static let balanced = Configuration(alphaModel: .c4f16, lumaModel: .c4f32)
        public static let c4f16 = Configuration(alphaModel: .c4f16, lumaModel: .c4f16)
    }

    public enum UpscaleError: Error, CustomStringConvertible {
        case unavailable(String)
        case size(String)
        case gpu(String)
        public var description: String {
            switch self {
            case .unavailable(let s): "subtitle upscaler unavailable: \(s)"
            case .size(let s): "subtitle upscaler size: \(s)"
            case .gpu(let s): "subtitle upscaler GPU error: \(s)"
            }
        }
    }

    /// One picture to upscale: `source` (any float-readable colour texture: BGRA8, RGBA8, RGBA16F) into
    /// `destination` (writable, any size; see ``upscale(_:)``).
    public struct Job {
        public var source: MTLTexture
        public var destination: MTLTexture
        public var sourceAlpha: SourceAlpha
        /// Source pixels outside this rectangle are fully transparent (a display set's object rectangles, or
        /// ``contentBounds(_:width:height:bytesPerRow:alphaOffset:)``). The network then runs on these bounds grown
        /// by its reach instead of the whole canvas; nil runs it on the whole picture. The output is the same
        /// either way as long as the promise holds.
        public var contentBounds: CGRect?
        public init(source: MTLTexture, destination: MTLTexture, sourceAlpha: SourceAlpha = .premultiplied, contentBounds: CGRect? = nil) {
            self.source = source
            self.destination = destination
            self.sourceAlpha = sourceAlpha
            self.contentBounds = contentBounds
        }
    }

    /// The bounding rectangle of the pixels with non-zero alpha in a 4-byte-per-pixel bitmap, nil when there are
    /// none. `alphaOffset` is the alpha byte's position in the pixel (3 for RGBA and BGRA).
    public static func contentBounds(_ base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, alphaOffset: Int) -> CGRect? {
        var x0 = width, x1 = -1, y0 = height, y1 = -1
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            var first = -1, last = -1
            for x in 0..<width where row[4 * x + alphaOffset] != 0 {
                if first < 0 { first = x }
                last = x
            }
            guard first >= 0 else { continue }
            x0 = min(x0, first); x1 = max(x1, last)
            if y0 == height { y0 = y }
            y1 = y
        }
        guard x1 >= 0 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    public var configuration: Configuration {
        get { lock.withLock { _configuration } }
        set { lock.withLock { _configuration = newValue } }
    }

    /// The shared Metal device the upscaler runs on: textures passed in must come from it.
    public var device: MTLDevice { kernels.device }
    /// The shared queue; any queue on ``device`` works.
    public var commandQueue: MTLCommandQueue { kernels.queue }

    let kernels: SubtitleUpscaleKernels
    /// Serialises every call; recursive, so a convenience holds it across its staging and its ``upscale(_:)``.
    private let lock = NSRecursiveLock()
    private var _configuration: Configuration
    private var workspace: Workspace

    /// Wall milliseconds of the last pass's stages, for the benchmark.
    struct NeuralEngineStages {
        var gather = 0.0
        var predict = 0.0
        var composite = 0.0
        var tiles = 0
    }
    var lastNeuralEngineStages = NeuralEngineStages()

    /// Output pixels farther than this many source pixels from content are transparent (1...7; see the shader's
    /// notes on the cut).
    var supportRadius = 5 {
        didSet { precondition((1...7).contains(supportRadius)) }
    }

    /// Compiles the shared pipelines, compiles and loads the Core ML models and has the Neural Engine compile each
    /// function, on a background queue, so the first picture waits for none of it. For app open: a few seconds
    /// after an install, an OS update or a purged cache, under a second otherwise.
    public static func prewarm() {
        DispatchQueue.global(qos: .utility).async {
            _ = try? SubtitleUpscaleKernels.get()
            try? SubtitleUpscaleNeuralEngine.prewarm()
        }
    }

    public init(configuration: Configuration = .default) throws {
        kernels = try SubtitleUpscaleKernels.get()
        _configuration = configuration
        workspace = Workspace(device: kernels.device)
    }

    /// Upscales each job and waits. A destination twice its source takes one 2x pass; any other size takes 2x passes
    /// (one, or two when the destination is at least 4x) then a Lanczos-3 resample to the exact size, antialiased
    /// when it reduces.
    public func upscale(_ jobs: [Job]) throws {
        try lock.withLock {
            for job in jobs {
                let plan = try scalePlan(job)
                for pass in plan.passes { try passLocked(pass) }
                if let (src, dst) = plan.resample { try run { try encodeResample(src, dst, into: $0) } }
            }
        }
    }

    /// The 2x passes `job` takes, into the workspace's intermediates where it needs more than one, and the final
    /// resample (source, destination) when the destination is not exactly 2x.
    private func scalePlan(_ job: Job) throws -> (passes: [Job], resample: (MTLTexture, MTLTexture)?) {
        let sw = job.source.width, sh = job.source.height
        let dw = job.destination.width, dh = job.destination.height
        if dw == 2 * sw, dh == 2 * sh { return ([job], nil) }
        let scale = max(Double(dw) / Double(sw), Double(dh) / Double(sh))
        var passes: [Job] = []
        var current = job.source
        var alpha = job.sourceAlpha
        var bounds = job.contentBounds
        for pass in 0..<(scale >= 4 ? 2 : 1) {
            let target = try workspace.intermediate(pass, width: current.width * 2, height: current.height * 2)
            passes.append(Job(source: current, destination: target, sourceAlpha: alpha, contentBounds: bounds))
            current = target
            alpha = .premultiplied
            // The output is transparent beyond the support of content.
            let grow = CGFloat(2 * supportRadius)
            bounds = bounds.map { $0.isEmpty ? $0 : $0.applying(CGAffineTransform(scaleX: 2, y: 2)).insetBy(dx: -grow, dy: -grow) }
        }
        return (passes, (current, job.destination))
    }

    private func encodeResample(_ src: MTLTexture, _ dst: MTLTexture, into commandBuffer: MTLCommandBuffer) throws {
        let across = try workspace.intermediate(2, width: dst.width, height: src.height)
        guard let encoder = commandBuffer.makeComputeCommandEncoder(dispatchType: .serial) else { throw UpscaleError.gpu("no compute encoder") }
        encoder.setComputePipelineState(kernels.resample)
        for (axis, (from, to)) in [(src, across), (across, dst)].enumerated() {
            var a = UInt32(axis)
            encoder.setTexture(from, index: 0)
            encoder.setTexture(to, index: 1)
            encoder.setBytes(&a, length: 4, index: 0)
            dispatch(encoder, kernels.resample, width: to.width, height: to.height)
        }
        encoder.endEncoding()
    }

    // MARK: - Conveniences

    /// Upscales `pixelBuffer` (32BGRA) 2x, or to `size`, into a new 32BGRA buffer, and waits.
    public func upscale(_ pixelBuffer: CVPixelBuffer, sourceAlpha: SourceAlpha = .premultiplied, size: CGSize? = nil) throws -> CVPixelBuffer {
        try lock.withLock { try upscaleLocked(pixelBuffer, sourceAlpha: sourceAlpha, size: size) }
    }

    private func upscaleLocked(_ pixelBuffer: CVPixelBuffer, sourceAlpha: SourceAlpha, size: CGSize?) throws -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        let dw = size.map { Int($0.width.rounded()) } ?? 2 * w
        let dh = size.map { Int($0.height.rounded()) } ?? 2 * h
        var out: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                                           kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, dw, dh, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &out) == kCVReturnSuccess,
              let out else { throw UpscaleError.unavailable("no output pixel buffer") }
        let source = try workspace.texture(for: pixelBuffer), destination = try workspace.texture(for: out)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let bounds = CVPixelBufferGetBaseAddress(pixelBuffer).map {
            Self.contentBounds($0, width: w, height: h, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), alphaOffset: 3)
        } ?? nil
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        try upscale([Job(source: source.texture, destination: destination.texture, sourceAlpha: sourceAlpha, contentBounds: bounds ?? .zero)])
        withExtendedLifetime((source, destination)) {}
        return out
    }

    /// Upscales `image` 2x, or to `size`, and waits. The result is RGBA, premultiplied last, sRGB.
    public func upscale(_ image: CGImage, size: CGSize? = nil) throws -> CGImage {
        try lock.withLock { try upscaleLocked(image, size: size) }
    }

    private func upscaleLocked(_ image: CGImage, size: CGSize?) throws -> CGImage {
        let w = image.width, h = image.height
        let dw = size.map { Int($0.width.rounded()) } ?? 2 * w
        let dh = size.map { Int($0.height.rounded()) } ?? 2 * h
        let source = try workspace.staging(0, width: w, height: h)
        let destination = try workspace.staging(1, width: dw, height: dh)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        var bounds: CGRect?
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        try pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: info) else { throw UpscaleError.unavailable("no bitmap context") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            source.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: w * 4)
            bounds = Self.contentBounds(raw.baseAddress!, width: w, height: h, bytesPerRow: w * 4, alphaOffset: 3)
        }
        try upscale([Job(source: source, destination: destination, contentBounds: bounds ?? .zero)])
        var result = [UInt8](repeating: 0, count: dw * dh * 4)
        result.withUnsafeMutableBytes { raw in
            destination.getBytes(raw.baseAddress!, bytesPerRow: dw * 4, from: MTLRegionMake2D(0, 0, dw, dh), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(result) as CFData),
              let made = CGImage(width: dw, height: dh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: dw * 4, space: space,
                                 bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: true,
                                 intent: .defaultIntent) else { throw UpscaleError.unavailable("no output image") }
        return made
    }

    /// Runs `encode` in a fresh command buffer on the shared queue and waits for it.
    func run(_ encode: (MTLCommandBuffer) throws -> Void) throws {
        guard let commandBuffer = kernels.queue.makeCommandBuffer() else { throw UpscaleError.gpu("no command buffer") }
        try encode(commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw UpscaleError.gpu("\(error)") }
    }

    // MARK: - One picture

    /// Mirrors `UpGeom` in the shader.
    struct Geometry {
        var width: UInt32 = 0
        var height: UInt32 = 0
        var wordsX: UInt32 = 0
        var straightAlpha: UInt32 = 0
        var originX: Int32 = 0
        var originY: Int32 = 0
        var pictureWidth: UInt32 = 0
        var pictureHeight: UInt32 = 0
        var support: UInt32 = 0
    }

    /// Validates `job`, clears its destination outside the kept area and encodes the kept area's content mask (the
    /// support the composite keeps). Nil when the kept area is empty: the destination is then all transparent.
    private func encodeMask(_ job: Job, kept: Rect, encoder: MTLComputeCommandEncoder) throws -> Geometry? {
        let pw = job.source.width, ph = job.source.height
        guard pw > 0, ph > 0 else { throw UpscaleError.size("empty source") }
        guard job.destination.width == 2 * pw, job.destination.height == 2 * ph else {
            throw UpscaleError.size("destination \(job.destination.width)x\(job.destination.height) is not 2x \(pw)x\(ph)")
        }
        var g = Geometry()
        g.support = UInt32(supportRadius)
        g.originX = Int32(kept.x); g.originY = Int32(kept.y)
        g.pictureWidth = UInt32(pw); g.pictureHeight = UInt32(ph)
        g.width = UInt32(kept.width); g.height = UInt32(kept.height)
        g.straightAlpha = job.sourceAlpha == .straight ? 1 : 0
        let geometrySize = MemoryLayout<Geometry>.stride
        if kept.width == 0 || kept.x > 0 || kept.y > 0 || kept.x + kept.width < pw || kept.y + kept.height < ph {
            encoder.setComputePipelineState(kernels.clearOutside)
            encoder.setTexture(job.destination, index: 0)
            encoder.setBytes(&g, length: geometrySize, index: 0)
            dispatch(encoder, kernels.clearOutside, width: pw, height: ph)
        }
        guard kept.width > 0 else { return nil }
        let h = kept.height
        let wordsX = (kept.width + 31) / 32
        g.wordsX = UInt32(wordsX)
        try workspace.reserveMask(height: h, wordsX: wordsX)
        let ws = workspace
        encoder.setTexture(job.source, index: 0)
        encoder.setComputePipelineState(kernels.maskBits)
        encoder.setBuffer(ws.bits, offset: 0, index: 0)
        encoder.setBytes(&g, length: geometrySize, index: 1)
        // 32 wide, so each simdgroup is one word of one row.
        encoder.dispatchThreads(MTLSize(width: wordsX * 32, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 4, depth: 1))
        encoder.setComputePipelineState(kernels.maskRows)
        encoder.setBuffer(ws.bits, offset: 0, index: 0)
        encoder.setBuffer(ws.rows, offset: 0, index: 1)
        encoder.setBytes(&g, length: geometrySize, index: 2)
        dispatch(encoder, kernels.maskRows, width: wordsX, height: h)
        encoder.setComputePipelineState(kernels.maskColumns)
        encoder.setBuffer(ws.rows, offset: 0, index: 0)
        encoder.setBuffer(ws.support, offset: 0, index: 1)
        encoder.setBytes(&g, length: geometrySize, index: 2)
        dispatch(encoder, kernels.maskColumns, width: wordsX, height: h)
        return g
    }

    // MARK: - One pass

    /// A rectangle in picture coordinates.
    struct Rect: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    /// Mirrors `UpWindow` in the shader.
    struct WindowRecord {
        var x: Int32
        var y: Int32
        var coreX: Int32
        var coreY: Int32
        var coreWidth: UInt32
        var coreHeight: UInt32
    }

    /// The kept area: the picture pixels within the support of the content bounds (the whole picture without
    /// bounds), which hold every output pixel that is not exactly transparent.
    private func keptArea(_ job: Job) -> Rect {
        let picture = CGRect(x: 0, y: 0, width: job.source.width, height: job.source.height)
        var b = picture
        if let bounds = job.contentBounds {
            // Content first: empty bounds hold nothing to grow.
            let content = bounds.integral.intersection(picture)
            guard !content.isNull, !content.isEmpty else { return Rect(x: 0, y: 0, width: 0, height: 0) }
            b = content.insetBy(dx: -CGFloat(supportRadius), dy: -CGFloat(supportRadius)).intersection(picture)
        }
        guard !b.isNull, !b.isEmpty else { return Rect(x: 0, y: 0, width: 0, height: 0) }
        return Rect(x: Int(b.minX), y: Int(b.minY), width: Int(b.width), height: Int(b.height))
    }

    /// One 2x pass: the mask and the window gather on the GPU, a prediction per window and plane on the Neural
    /// Engine, then the composite on the GPU, each window's planes shared between them through its IOSurfaces. Waits
    /// for each step.
    private func passLocked(_ job: Job) throws {
        let config = _configuration
        let kept = keptArea(job)
        let plan = SubtitleUpscaleTilePlan.plan(
            kept: (kept.x, kept.y, kept.width, kept.height),
            nanosecondsPerPixel: SubtitleUpscaleTilePlan.nanosecondsPerPixel(config.alphaModel)
                + SubtitleUpscaleTilePlan.nanosecondsPerPixel(config.lumaModel),
            nanosecondsPerCall: 2 * SubtitleUpscaleTilePlan.nanosecondsPerCall)
        let surfaces = try workspace.surfaces.surfaces(for: plan.windows)
        let records = plan.windows.map { w in
            let core = CGRect(x: w.x + SubtitleUpscaleTilePlan.reach, y: w.y + SubtitleUpscaleTilePlan.reach,
                              width: w.width - 2 * SubtitleUpscaleTilePlan.reach, height: w.height - 2 * SubtitleUpscaleTilePlan.reach)
                .intersection(CGRect(x: kept.x, y: kept.y, width: kept.width, height: kept.height))
            return WindowRecord(x: Int32(w.x), y: Int32(w.y), coreX: Int32(core.minX), coreY: Int32(core.minY),
                                coreWidth: UInt32(core.width), coreHeight: UInt32(core.height))
        }
        var g = Geometry()
        var stages = NeuralEngineStages()
        var mark = DispatchTime.now().uptimeNanoseconds
        func lap() -> Double {
            let now = DispatchTime.now().uptimeNanoseconds
            defer { mark = now }
            return Double(now - mark) / 1e6
        }
        defer { lastNeuralEngineStages = stages }
        var empty = false
        try run { commandBuffer in
            guard let encoder = commandBuffer.makeComputeCommandEncoder(dispatchType: .serial) else { throw UpscaleError.gpu("no compute encoder") }
            defer { encoder.endEncoding() }
            guard let made = try encodeMask(job, kept: kept, encoder: encoder) else { empty = true; return }
            g = made
            encoder.setComputePipelineState(kernels.tileGather)
            encoder.setTexture(job.source, index: 0)
            encoder.setBytes(&g, length: MemoryLayout<Geometry>.stride, index: 0)
            for (k, var record) in records.enumerated() {
                encoder.setTexture(surfaces[k].alphaIn.texture, index: 1)
                encoder.setTexture(surfaces[k].lumaIn.texture, index: 2)
                encoder.setBytes(&record, length: MemoryLayout<WindowRecord>.stride, index: 1)
                encoder.dispatchThreads(MTLSize(width: plan.windows[k].width, height: plan.windows[k].height, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
            }
        }
        stages.gather = lap()
        stages.tiles = records.count
        guard !empty, !records.isEmpty else { return }
        for s in surfaces {
            try SubtitleUpscaleNeuralEngine.predict(try SubtitleUpscaleNeuralEngine.model(config.alphaModel, s.shape), input: s.alphaIn, output: s.alphaOut)
            try SubtitleUpscaleNeuralEngine.predict(try SubtitleUpscaleNeuralEngine.model(config.lumaModel, s.shape), input: s.lumaIn, output: s.lumaOut)
        }
        stages.predict = lap()
        defer { stages.composite = lap() }
        try run { commandBuffer in
            guard let encoder = commandBuffer.makeComputeCommandEncoder(dispatchType: .serial) else { throw UpscaleError.gpu("no compute encoder") }
            defer { encoder.endEncoding() }
            encoder.setComputePipelineState(kernels.compositeTiles)
            encoder.setTexture(job.source, index: 0)
            encoder.setTexture(job.destination, index: 1)
            encoder.setBuffer(workspace.support, offset: 0, index: 0)
            encoder.setBytes(&g, length: MemoryLayout<Geometry>.stride, index: 1)
            for (k, var record) in records.enumerated() where record.coreWidth > 0 && record.coreHeight > 0 {
                encoder.setTexture(surfaces[k].alphaOut.texture, index: 2)
                encoder.setTexture(surfaces[k].lumaOut.texture, index: 3)
                encoder.setBytes(&record, length: MemoryLayout<WindowRecord>.stride, index: 2)
                dispatch(encoder, kernels.compositeTiles, width: Int(record.coreWidth), height: Int(record.coreHeight))
            }
        }
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let tw = pipeline.threadExecutionWidth
        let th = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / tw, 8))
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }

    // MARK: - Working set

    /// The buffers one picture's passes use, grown to the largest picture seen and kept.
    final class Workspace {
        let device: MTLDevice
        /// The content mask, one bit per pixel of the kept area: `bits`, its row dilation `rows` and its square
        /// dilation `support`, by S.
        private(set) var bits: MTLBuffer!
        private(set) var rows: MTLBuffer!
        private(set) var support: MTLBuffer!
        /// The window surfaces, shared by Metal and Core ML.
        let surfaces: SubtitleUpscaleNeuralEngine.Surfaces.Pool
        private var maskCapacity = 0
        private var textures: [Int: MTLTexture] = [:]
        private var textureCache: CVMetalTextureCache?

        init(device: MTLDevice) {
            self.device = device
            surfaces = SubtitleUpscaleNeuralEngine.Surfaces.Pool(device: device)
        }

        private func make(_ length: Int) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: max(length, 16), options: .storageModePrivate) else {
                throw UpscaleError.unavailable("no \(length)-byte buffer")
            }
            return b
        }

        func reserveMask(height: Int, wordsX: Int) throws {
            let mask = height * wordsX
            if mask > maskCapacity {
                bits = try make(mask * 4)
                rows = try make(mask * 4)
                support = try make(mask * 4)
                maskCapacity = mask
            }
        }

        /// Scratch RGBA16F textures for ``upscale(_:)`` at other sizes: slots 0 and 1 the 2x passes, 2 the
        /// resample's first axis.
        func intermediate(_ slot: Int, width: Int, height: Int) throws -> MTLTexture {
            try texture(slot, width: width, height: height, format: .rgba16Float, storage: .private)
        }

        /// Shared RGBA8 textures for the CGImage path: slot 0 the source, 1 the destination.
        func staging(_ slot: Int, width: Int, height: Int) throws -> MTLTexture {
            try texture(10 + slot, width: width, height: height, format: .rgba8Unorm, storage: .shared)
        }

        private func texture(_ slot: Int, width: Int, height: Int, format: MTLPixelFormat, storage: MTLStorageMode) throws -> MTLTexture {
            if let t = textures[slot], t.width == width, t.height == height { return t }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = storage
            guard let t = device.makeTexture(descriptor: d) else { throw UpscaleError.unavailable("no \(width)x\(height) texture") }
            textures[slot] = t
            return t
        }

        func texture(for pixelBuffer: CVPixelBuffer) throws -> (texture: MTLTexture, backing: CVMetalTexture) {
            if textureCache == nil {
                var cache: CVMetalTextureCache?
                CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
                textureCache = cache
            }
            guard let cache = textureCache, CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
                throw UpscaleError.unavailable("pixel buffer is not 32BGRA")
            }
            var texture: CVMetalTexture?
            let attributes = [kCVMetalTextureUsage: NSNumber(value: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue)] as CFDictionary
            guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, attributes, .bgra8Unorm,
                                                            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer),
                                                            0, &texture) == kCVReturnSuccess,
                  let texture, let metal = CVMetalTextureGetTexture(texture) else {
                throw UpscaleError.unavailable("no texture for the pixel buffer")
            }
            return (metal, texture)
        }
    }
}
