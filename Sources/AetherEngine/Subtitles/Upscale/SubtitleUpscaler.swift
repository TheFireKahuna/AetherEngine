import CoreGraphics
import CoreVideo
import Foundation
import Metal

/// Upscales a bitmap subtitle (PGS, DVB, DVD, a display set's RGBA picture) 2x with ArtCNN, on the GPU or the
/// Neural Engine (``Backend``).
///
/// ArtCNN is a single-channel model, so the picture is split into its alpha and its premultiplied luma, each plane is
/// run through the network, and the colour comes back as the source's chroma interpolated bilinearly (subtitle
/// colour is near-constant across a glyph: the shape lives in alpha and luma) and scaled by the new alpha. The result
/// is premultiplied, alpha clamped to [0, 1] and colour to [0, alpha], so the network's overshoot cannot paint a halo.
/// Output pixels farther than 5 source pixels from any non-transparent pixel are exactly transparent; the GPU network
/// skips them (and the units only they depend on), which on a subtitle strip is much of the picture.
///
/// One process-wide device, queue and pipeline set (``prewarm()``); each upscaler keeps its working buffers between
/// calls and grows them only for a larger picture, so the steady state allocates nothing. An instance runs one
/// picture at a time (calls are serialised). ``upscale(_:)`` runs a burst and waits, on either backend; on the GPU
/// several pictures can also share a caller's command buffer (``encode(_:into:)``).
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
        /// Skip the units the output does not depend on (GPU). Off, every unit is computed; the output is identical.
        public var skipsTransparent: Bool
        /// Where the networks run. The mask and composite are GPU passes either way.
        public var backend: Backend

        public init(alphaModel: ArtCNNModel = .c4f32, lumaModel: ArtCNNModel = .c4f32, skipsTransparent: Bool = true,
                    backend: Backend = .gpu) {
            self.alphaModel = alphaModel
            self.lumaModel = lumaModel
            self.skipsTransparent = skipsTransparent
            self.backend = backend
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

    public enum Backend: Sendable, Hashable {
        /// Metal `simdgroup_matrix` kernels, skipping transparent units; can join a caller's command buffer.
        case gpu
        /// Core ML on the Neural Engine over fixed tiles (``SubtitleUpscaleNeuralEngine``), leaving the GPU to the
        /// video. Synchronous: ``upscale(_:)`` and the conveniences only.
        case neuralEngine
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
    /// `destination` (writable, twice the size for ``encode(_:into:)``).
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

    /// Tunables, internal so the benchmark can sweep them.
    var variant = SubtitleUpscaleKernels.defaultVariant
    /// Threadgroups a persistent (threadgroup-weights) layer dispatches.
    var persistentGroups = 64
    var simdgroupsPerGroup = SubtitleUpscaleKernels.defaultSimdgroupsPerGroup
    /// Upper bound on the two feature maps (both planes, ping and pong) of one band. A picture whose maps would
    /// exceed it runs in row bands, each with 6 rows of overlap per side; the default fits a 1920-wide strip of
    /// 190 rows (or any cropped display set up to about 196,000 pixels) in one band.
    var featureBudgetBytes = 48 << 20
    /// Output pixels farther than this many source pixels from content are transparent (1...7; see the shader's
    /// notes on the cut). Each pixel less shrinks every layer's work by a pixel of dilation around the content.
    var supportRadius = 5 {
        didSet { precondition((1...7).contains(supportRadius)) }
    }

    /// Compiles the shared pipelines on a background queue, so the first picture does not wait for them; with
    /// `neuralEngine`, also loads the Core ML models and has the Neural Engine compile them.
    public static func prewarm(neuralEngine: Bool = false) {
        DispatchQueue.global(qos: .utility).async {
            _ = try? SubtitleUpscaleKernels.get()
            if neuralEngine { try? SubtitleUpscaleNeuralEngine.prewarm() }
        }
    }

    public init(configuration: Configuration = .default) throws {
        kernels = try SubtitleUpscaleKernels.get()
        _configuration = configuration
        workspace = Workspace(device: kernels.device)
    }

    // MARK: - Encoding

    /// Encodes the 2x upscale of each job into `commandBuffer`, one after another on this upscaler's buffers (GPU
    /// backend). Each destination must be exactly twice its source.
    public func encode(_ jobs: [Job], into commandBuffer: MTLCommandBuffer) throws {
        try lock.withLock {
            guard _configuration.backend == .gpu else { throw UpscaleError.unavailable("the Neural Engine backend runs through upscale(_:)") }
            guard let encoder = commandBuffer.makeComputeCommandEncoder(dispatchType: .serial) else {
                throw UpscaleError.gpu("no compute encoder")
            }
            defer { encoder.endEncoding() }
            for job in jobs { try encodeLocked(job, encoder: encoder) }
        }
    }

    /// Encodes `job` at any destination size into `commandBuffer` (GPU backend): see ``upscale(_:)``.
    public func encodeScaled(_ job: Job, into commandBuffer: MTLCommandBuffer) throws {
        try lock.withLock {
            guard _configuration.backend == .gpu else { throw UpscaleError.unavailable("the Neural Engine backend runs through upscale(_:)") }
            try encodeScaledLocked(job, into: commandBuffer)
        }
    }

    /// Upscales each job and waits. A destination twice its source takes one 2x pass; any other size takes 2x passes
    /// (one, or two when the destination is at least 4x) then a Lanczos-3 resample to the exact size, antialiased
    /// when it reduces. On the GPU the whole burst is one command buffer.
    public func upscale(_ jobs: [Job]) throws {
        try lock.withLock {
            switch _configuration.backend {
            case .gpu:
                try run { commandBuffer in
                    for job in jobs { try encodeScaledLocked(job, into: commandBuffer) }
                }
            case .neuralEngine:
                for job in jobs {
                    let plan = try scalePlan(job)
                    for pass in plan.passes { try neuralEngineLocked(pass) }
                    if let (src, dst) = plan.resample { try run { try encodeResample(src, dst, into: $0) } }
                }
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

    private func encodeScaledLocked(_ job: Job, into commandBuffer: MTLCommandBuffer) throws {
        let plan = try scalePlan(job)
        guard let encoder = commandBuffer.makeComputeCommandEncoder(dispatchType: .serial) else { throw UpscaleError.gpu("no compute encoder") }
        for pass in plan.passes { try encodeLocked(pass, encoder: encoder) }
        encoder.endEncoding()
        if let (src, dst) = plan.resample { try encodeResample(src, dst, into: commandBuffer) }
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
        var wp: UInt32 = 0
        var unitsX: UInt32 = 0
        var row0: Int32 = 0
        var rows: UInt32 = 0
        var outRow0: UInt32 = 0
        var outRow1: UInt32 = 0
        var featureStride: UInt32 = 0
        var pixelStride: UInt32 = 0
        var wordsX: UInt32 = 0
        var listCapacity: UInt32 = 0
        var skip: UInt32 = 0
        var straightAlpha: UInt32 = 0
        var originX: Int32 = 0
        var originY: Int32 = 0
        var pictureWidth: UInt32 = 0
        var pictureHeight: UInt32 = 0
        var support: UInt32 = 0
    }

    /// The rectangle the network runs on: the content (`bounds` within the picture, integral; the whole picture
    /// without bounds) grown by `support` + 6 pixels, the deepest a kept output pixel's features reach (the support
    /// plus 6 of feature dependency). It may extend past the picture: the picture is a crop of a transparent canvas,
    /// so the output depends on the content alone, never on how tightly the bitmap was cropped. Beyond the region
    /// everything is transparent, and the zero padding at its edges reaches only pixels the composite discards.
    static func region(bounds: CGRect?, width: Int, height: Int, support: Int) -> (minX: Int, minY: Int, width: Int, height: Int, isEmpty: Bool) {
        let reach = support + 6
        var b = CGRect(x: 0, y: 0, width: width, height: height)
        if let bounds { b = bounds.integral.intersection(b) }
        guard !b.isNull, !b.isEmpty else { return (0, 0, 0, 0, true) }
        return (Int(b.minX) - reach, Int(b.minY) - reach, Int(b.width) + 2 * reach, Int(b.height) + 2 * reach, false)
    }

    /// Row bands of a `height`-row picture whose padded rows are `pitch` pixels: (first band row, band rows, first
    /// output row, output rows). Bands overlap by 6 rows per side, the deepest a kept pixel's feature dependency
    /// reaches beyond its own row (layer 0 reads the picture itself).
    static func bands(height: Int, pitch: Int, maxPixels: Int) -> [(row0: Int, rows: Int, out0: Int, out1: Int)] {
        let maxRows = max(maxPixels / pitch - 2, 13)
        if height <= maxRows { return [(0, height, 0, height)] }
        var bands: [(Int, Int, Int, Int)] = []
        var out0 = 0
        while out0 < height {
            let row0 = max(out0 - 6, 0)
            let row1 = min(row0 + maxRows, height)
            let out1 = row1 == height ? height : row1 - 6
            bands.append((row0, row1 - row0, out0, out1))
            out0 = out1
        }
        return bands
    }

    /// Validates `job`, clears its destination outside the region and encodes the region's content mask (either
    /// backend's first passes). Nil when the region is empty: the destination is then all transparent.
    private func encodeMask(_ job: Job, encoder: MTLComputeCommandEncoder) throws -> Geometry? {
        let pw = job.source.width, ph = job.source.height
        guard pw > 0, ph > 0 else { throw UpscaleError.size("empty source") }
        guard job.destination.width == 2 * pw, job.destination.height == 2 * ph else {
            throw UpscaleError.size("destination \(job.destination.width)x\(job.destination.height) is not 2x \(pw)x\(ph)")
        }
        let region = Self.region(bounds: job.contentBounds, width: pw, height: ph, support: supportRadius)
        var g = Geometry()
        g.support = UInt32(supportRadius)
        g.originX = Int32(region.minX); g.originY = Int32(region.minY)
        g.pictureWidth = UInt32(pw); g.pictureHeight = UInt32(ph)
        g.width = UInt32(region.width); g.height = UInt32(region.height)
        g.straightAlpha = job.sourceAlpha == .straight ? 1 : 0
        let geometrySize = MemoryLayout<Geometry>.stride
        if region.isEmpty || region.minX > 0 || region.minY > 0 || region.minX + region.width < pw || region.minY + region.height < ph {
            encoder.setComputePipelineState(kernels.clearOutside)
            encoder.setTexture(job.destination, index: 0)
            encoder.setBytes(&g, length: geometrySize, index: 0)
            dispatch(encoder, kernels.clearOutside, width: pw, height: ph)
        }
        guard !region.isEmpty else { return nil }
        let h = region.height
        let wordsX = (region.width + 31) / 32
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
        encoder.setBuffer(ws.square, offset: 0, index: 1)
        encoder.setBytes(&g, length: geometrySize, index: 2)
        encoder.dispatchThreads(MTLSize(width: wordsX, height: h, depth: 7), threadsPerThreadgroup: MTLSize(width: 32, height: 4, depth: 1))
        return g
    }

    private func encodeLocked(_ job: Job, encoder: MTLComputeCommandEncoder) throws {
        let config = _configuration
        guard var g = try encodeMask(job, encoder: encoder) else { return }
        let geometrySize = MemoryLayout<Geometry>.stride
        let w = Int(g.width), h = Int(g.height)
        let unitsX = (w + 7) / 8
        guard unitsX <= 0xffff else { throw UpscaleError.size("source wider than \(0xffff * 8)") }
        let pitch = 8 + unitsX * 8 + 8
        let maxPixels = featureBudgetBytes / (2 * 2 * 32 * 2)
        let bands = Self.bands(height: h, pitch: pitch, maxPixels: maxPixels)
        guard bands.allSatisfy({ $0.rows <= 0xffff }) else { throw UpscaleError.size("band taller than 65535 rows") }
        let bandRows = bands.map(\.rows).max()!
        let pixelStride = pitch * (bandRows + 2)
        let listCapacity = bandRows * unitsX
        try workspace.reserveFeatures(pixelStride: pixelStride, listCapacity: listCapacity)
        let ws = workspace

        g.wp = UInt32(pitch); g.unitsX = UInt32(unitsX)
        g.featureStride = UInt32(pixelStride * 32); g.pixelStride = UInt32(pixelStride)
        g.listCapacity = UInt32(listCapacity); g.skip = config.skipsTransparent ? 1 : 0

        let alpha = kernels.buffers(config.alphaModel)
        let luma = kernels.buffers(config.lumaModel)
        let shared = config.alphaModel == config.lumaModel
        let variant = self.variant
        let mb = variant.unitsPerSimdgroup
        let sgs = simdgroupsPerGroup
        var unitsPerGroup = [UInt32](repeating: 0, count: 21)
        for layer in 0..<7 {
            for (k, model) in [alpha, alpha, luma].enumerated() {
                unitsPerGroup[layer * 3 + k] = UInt32(layer == 0 ? SubtitleUpscaleKernels.firstLayerThreads / model.features : sgs * mb)
            }
        }
        let featureBytes = pixelStride * 32 * 2

        for band in bands {
            g.row0 = Int32(band.row0); g.rows = UInt32(band.rows)
            g.outRow0 = UInt32(band.out0); g.outRow1 = UInt32(band.out1)

            encoder.setComputePipelineState(kernels.bandReset)
            encoder.setBuffer(ws.counts, offset: 0, index: 0)
            encoder.dispatchThreads(MTLSize(width: 8, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 1, depth: 1))

            encoder.setComputePipelineState(kernels.bandLists)
            encoder.setBuffer(ws.square, offset: 0, index: 0)
            encoder.setBuffer(ws.lists, offset: 0, index: 1)
            encoder.setBuffer(ws.counts, offset: 0, index: 2)
            encoder.setBytes(&g, length: geometrySize, index: 3)
            encoder.dispatchThreads(MTLSize(width: band.rows * unitsX, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

            encoder.setComputePipelineState(kernels.bandArguments)
            encoder.setBuffer(ws.counts, offset: 0, index: 0)
            encoder.setBuffer(ws.arguments, offset: 0, index: 1)
            encoder.setBytes(&unitsPerGroup, length: 21 * 4, index: 2)
            encoder.dispatchThreads(MTLSize(width: 21, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))

            encoder.setComputePipelineState(kernels.planes)
            encoder.setTexture(job.source, index: 0)
            encoder.setBuffer(ws.planes, offset: 0, index: 0)
            encoder.setBytes(&g, length: geometrySize, index: 1)
            dispatch(encoder, kernels.planes, width: pitch, height: band.rows + 2)

            encoder.setComputePipelineState(kernels.clearPads)
            var channels = SIMD2<UInt32>(UInt32(alpha.features), UInt32(luma.features))
            encoder.setBuffer(ws.maps, offset: 0, index: 0)
            encoder.setBytes(&g, length: geometrySize, index: 1)
            encoder.setBytes(&channels, length: 8, index: 2)
            encoder.dispatchThreads(MTLSize(width: 2 * pitch + 2 * band.rows, height: 4, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))

            // (plane base, argument slot, model) per dispatch of a layer.
            let groups: [(UInt32, Int, SubtitleUpscaleKernels.ModelBuffers)] = shared ? [(0, 0, alpha)] : [(0, 1, alpha), (1, 2, luma)]
            // Ping-pong: layer L reads map (L + 1) % 2 and writes L % 2; map 0 is P (offset 0), map 1 is Q.
            func map(_ index: Int) -> Int { index * 2 * featureBytes }

            for (base, slot, model) in groups {
                var planeBase = base
                encoder.setComputePipelineState(kernels.first(features: model.features))
                encoder.setBuffer(ws.planes, offset: 0, index: 0)
                encoder.setBuffer(ws.maps, offset: map(0), index: 1)
                encoder.setBuffer(model.first, offset: 0, index: 2)
                encoder.setBuffer(ws.lists, offset: 0, index: 3)
                encoder.setBuffer(ws.counts, offset: 0, index: 4)
                encoder.setBytes(&g, length: geometrySize, index: 5)
                encoder.setBytes(&planeBase, length: 4, index: 6)
                encoder.dispatchThreadgroups(indirectBuffer: ws.arguments, indirectBufferOffset: slot * 12,
                                             threadsPerThreadgroup: MTLSize(width: SubtitleUpscaleKernels.firstLayerThreads, height: 1, depth: 1))
            }
            for layer in 1...6 {
                let mode = layer <= 4 ? 0 : (layer == 5 ? 1 : 2)
                for (base, slot, model) in groups {
                    var planeBase = base
                    let pipeline = try kernels.convolution(features: model.features, mode: mode, variant: variant)
                    encoder.setComputePipelineState(pipeline)
                    encoder.setBuffer(ws.maps, offset: map((layer + 1) % 2), index: 0)
                    if mode == 2 {
                        encoder.setBuffer(ws.outputs, offset: 0, index: 1)
                    } else {
                        encoder.setBuffer(ws.maps, offset: map(layer % 2), index: 1)
                    }
                    encoder.setBuffer(model.blocks[layer - 1], offset: 0, index: 2)
                    encoder.setBuffer(model.bias[layer - 1], offset: 0, index: 3)
                    encoder.setBuffer(ws.lists, offset: layer * listCapacity * 4, index: 4)
                    encoder.setBuffer(ws.counts, offset: layer * 4, index: 5)
                    encoder.setBytes(&g, length: geometrySize, index: 6)
                    encoder.setBytes(&planeBase, length: 4, index: 7)
                    encoder.setBuffer(ws.planes, offset: 0, index: 8)
                    encoder.setBuffer(model.first, offset: 0, index: 9)
                    if variant.threadgroupWeights {
                        encoder.dispatchThreadgroups(MTLSize(width: persistentGroups, height: shared ? 2 : 1, depth: 1),
                                                     threadsPerThreadgroup: MTLSize(width: sgs * 32, height: 1, depth: 1))
                    } else {
                        encoder.dispatchThreadgroups(indirectBuffer: ws.arguments, indirectBufferOffset: (layer * 3 + slot) * 12,
                                                     threadsPerThreadgroup: MTLSize(width: sgs * 32, height: 1, depth: 1))
                    }
                }
            }

            encoder.setComputePipelineState(kernels.composite)
            encoder.setTexture(job.source, index: 0)
            encoder.setTexture(job.destination, index: 1)
            encoder.setBuffer(ws.outputs, offset: 0, index: 0)
            encoder.setBuffer(ws.square, offset: 0, index: 1)
            encoder.setBytes(&g, length: geometrySize, index: 2)
            dispatch(encoder, kernels.composite, width: w, height: band.out1 - band.out0)
        }
    }

    // MARK: - Neural Engine

    /// Mirrors `UpTiles` in the shader.
    struct Tiles {
        var keptX: Int32 = 0
        var keptY: Int32 = 0
        var columns: UInt32 = 0
        var count: UInt32 = 0
        var slots: UInt32 = 0
        var coreWidth: UInt32 = 0
        var coreHeight: UInt32 = 0
        var tileWidth: UInt32 = 0
        var tileHeight: UInt32 = 0
    }

    /// The model windows over `kept` (picture coordinates): one per core, its picture position, 7 pixels before
    /// the core (the network's reach), reading transparency wherever it leaves the picture.
    static func tileOrigins(kept: (x: Int, y: Int, width: Int, height: Int)) -> (columns: Int, origins: [SIMD2<Int32>]) {
        let cw = SubtitleUpscaleNeuralEngine.coreWidth, ch = SubtitleUpscaleNeuralEngine.coreHeight
        let columns = (kept.width + cw - 1) / cw, rows = (kept.height + ch - 1) / ch
        var origins: [SIMD2<Int32>] = []
        for ty in 0..<rows {
            for tx in 0..<columns { origins.append(SIMD2(Int32(kept.x + tx * cw - 7), Int32(kept.y + ty * ch - 7))) }
        }
        return (columns, origins)
    }

    /// One 2x pass with the networks on the Neural Engine: the mask and the tile windows on the GPU, the
    /// predictions, then the composite on the GPU. Waits for each step.
    private func neuralEngineLocked(_ job: Job) throws {
        let config = _configuration
        var g = Geometry()
        var tiles = Tiles()
        var count = 0
        var slots = 0
        try run { commandBuffer in
            guard let encoder = commandBuffer.makeComputeCommandEncoder(dispatchType: .serial) else { throw UpscaleError.gpu("no compute encoder") }
            defer { encoder.endEncoding() }
            guard let made = try encodeMask(job, encoder: encoder) else { return }
            g = made
            // The kept area: the picture pixels within the support of the content bounds.
            let pw = job.source.width, ph = job.source.height
            var b = CGRect(x: 0, y: 0, width: pw, height: ph)
            if let bounds = job.contentBounds {
                b = bounds.integral.insetBy(dx: -CGFloat(supportRadius), dy: -CGFloat(supportRadius)).intersection(b)
            }
            let kept = (x: Int(b.minX), y: Int(b.minY), width: Int(b.width), height: Int(b.height))
            let layout = Self.tileOrigins(kept: kept)
            count = layout.origins.count
            let batch = ArtCNNCoreMLModels.batch
            slots = (count + batch - 1) / batch * batch
            tiles = Tiles(keptX: Int32(kept.x), keptY: Int32(kept.y), columns: UInt32(layout.columns), count: UInt32(count), slots: UInt32(slots),
                          coreWidth: UInt32(SubtitleUpscaleNeuralEngine.coreWidth), coreHeight: UInt32(SubtitleUpscaleNeuralEngine.coreHeight),
                          tileWidth: UInt32(ArtCNNCoreMLModels.tileWidth), tileHeight: UInt32(ArtCNNCoreMLModels.tileHeight))
            try workspace.reserveTiles(slots)
            let ws = workspace
            layout.origins.withUnsafeBytes { ws.origins.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            encoder.setComputePipelineState(kernels.tileGather)
            encoder.setTexture(job.source, index: 0)
            encoder.setBuffer(ws.tileInput, offset: 0, index: 0)
            encoder.setBuffer(ws.origins, offset: 0, index: 1)
            encoder.setBytes(&g, length: MemoryLayout<Geometry>.stride, index: 2)
            encoder.setBytes(&tiles, length: MemoryLayout<Tiles>.stride, index: 3)
            encoder.dispatchThreads(MTLSize(width: ArtCNNCoreMLModels.tileWidth, height: ArtCNNCoreMLModels.tileHeight, depth: count),
                                    threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
        }
        guard count > 0 else { return }
        let ws = workspace
        // The slots past `count` hold stale windows; their outputs are never read.
        if config.alphaModel == config.lumaModel, slots == count {
            try SubtitleUpscaleNeuralEngine.predict(try SubtitleUpscaleNeuralEngine.model(config.alphaModel), input: ws.tileInput,
                                                    output: ws.tileOutput, first: 0, count: 2 * slots)
        } else {
            try SubtitleUpscaleNeuralEngine.predict(try SubtitleUpscaleNeuralEngine.model(config.alphaModel), input: ws.tileInput,
                                                    output: ws.tileOutput, first: 0, count: count)
            try SubtitleUpscaleNeuralEngine.predict(try SubtitleUpscaleNeuralEngine.model(config.lumaModel), input: ws.tileInput,
                                                    output: ws.tileOutput, first: slots, count: count)
        }
        try run { commandBuffer in
            guard let encoder = commandBuffer.makeComputeCommandEncoder(dispatchType: .serial) else { throw UpscaleError.gpu("no compute encoder") }
            defer { encoder.endEncoding() }
            encoder.setComputePipelineState(kernels.compositeTiles)
            encoder.setTexture(job.source, index: 0)
            encoder.setTexture(job.destination, index: 1)
            encoder.setBuffer(ws.tileOutput, offset: 0, index: 0)
            encoder.setBuffer(ws.square, offset: 0, index: 1)
            encoder.setBytes(&g, length: MemoryLayout<Geometry>.stride, index: 2)
            encoder.setBytes(&tiles, length: MemoryLayout<Tiles>.stride, index: 3)
            encoder.setBuffer(ws.origins, offset: 0, index: 4)
            dispatch(encoder, kernels.compositeTiles, width: Int(g.width), height: Int(g.height))
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
        private(set) var planes: MTLBuffer!
        private(set) var maps: MTLBuffer!
        private(set) var outputs: MTLBuffer!
        private(set) var lists: MTLBuffer!
        /// The content mask, one bit per pixel: `bits`, its row dilations `rows` and its square dilations `square`
        /// (seven planes each, distances S...S + 6).
        private(set) var bits: MTLBuffer!
        private(set) var rows: MTLBuffer!
        private(set) var square: MTLBuffer!
        /// The Neural Engine backend's model input and output (both planes, `slots` tiles each) and the window
        /// origins, shared with the CPU, which hands them to Core ML.
        private(set) var tileInput: MTLBuffer!
        private(set) var tileOutput: MTLBuffer!
        private(set) var origins: MTLBuffer!
        private var tileCapacity = 0
        let counts: MTLBuffer
        let arguments: MTLBuffer
        private var pixelCapacity = 0
        private var listCapacity = 0
        private var maskCapacity = 0
        private var textures: [Int: MTLTexture] = [:]
        private var textureCache: CVMetalTextureCache?

        init(device: MTLDevice) {
            self.device = device
            counts = device.makeBuffer(length: 32, options: .storageModePrivate)!
            arguments = device.makeBuffer(length: 21 * 12, options: .storageModePrivate)!
        }

        private func make(_ length: Int) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: max(length, 16), options: .storageModePrivate) else {
                throw UpscaleError.unavailable("no \(length)-byte buffer")
            }
            return b
        }

        func reserveFeatures(pixelStride: Int, listCapacity lists: Int) throws {
            if pixelStride > pixelCapacity {
                // Whatever a skipped unit holds reaches only pixels the composite discards: a matrix product's
                // output row depends on its own input row alone, so not even a NaN crosses into a kept pixel.
                planes = try make(2 * pixelStride * 2)
                maps = try make(4 * pixelStride * 32 * 2)
                outputs = try make(2 * pixelStride * 4 * 2)
                pixelCapacity = pixelStride
            }
            if lists > listCapacity {
                self.lists = try make(7 * lists * 4)
                listCapacity = lists
            }
        }

        func reserveTiles(_ slots: Int) throws {
            guard slots > tileCapacity else { return }
            let window = ArtCNNCoreMLModels.tileWidth * ArtCNNCoreMLModels.tileHeight
            func shared(_ length: Int) throws -> MTLBuffer {
                guard let b = device.makeBuffer(length: length, options: .storageModeShared) else { throw UpscaleError.unavailable("no \(length)-byte buffer") }
                return b
            }
            tileInput = try shared(2 * slots * window * 2)
            tileOutput = try shared(2 * slots * 4 * window * 2)
            origins = try shared(slots * 8)
            tileCapacity = slots
        }

        func reserveMask(height: Int, wordsX: Int) throws {
            let mask = height * wordsX
            if mask > maskCapacity {
                bits = try make(mask * 4)
                rows = try make(7 * mask * 4)
                square = try make(7 * mask * 4)
                maskCapacity = mask
            }
        }

        /// Scratch RGBA16F textures for ``encodeScaled(_:into:)``: slots 0 and 1 the 2x passes, 2 the resample's
        /// first axis.
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
