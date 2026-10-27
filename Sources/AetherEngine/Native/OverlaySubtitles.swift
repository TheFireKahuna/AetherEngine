import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Metal
import os

/// The session's subtitle cues drawn into the overlay's pictures while Picture in Picture is up. The window takes the
/// overlay's layer and nothing above it, so neither AVKit's subtitle layer nor the host's own reaches it.
///
/// Each picture with a cue on it is copied into a picture of its own with the cues over it (the picture handed in may
/// be shown again: the decode keeps its pictures). The cue set is drawn once (``SubtitleFrameCompositor/renderOverlay``,
/// at the picture's display aspect, at most 1080 lines) and turned into the picture's own coding once
/// (`subtitle_prepare`); every picture then costs a blend of its luma and of its chroma. Pictures come back in the
/// order they were handed in, those without a cue unchanged.
///
/// Text cues follow the viewer's system caption style (`SubtitleCaptionStyle`), as AVKit's own drawing does in
/// fullscreen: read when the window first comes up and followed after; bitmaps are drawn as they are. With nothing
/// customised the look is the default one.
final class OverlaySubtitles: @unchecked Sendable {

    struct State: Sendable {
        var active = false
        var cues: [SubtitleCue] = []
        var delaySeconds = 0.0
        /// Source seconds less item seconds: cues are timed on the source's axis, pictures on the item's.
        var sourceShift = 0.0
    }

    /// The tallest the cues are drawn at: a Picture in Picture window is a fraction of the screen.
    static let rasterLines = 1080

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "aether.software-overlay.subtitles", qos: .userInteractive,
                                      autoreleaseFrequency: .workItem)
    /// The renderer's recommended pixel buffer attributes, for the pool the drawn pictures come from.
    private let bufferAttributes: [String: Any]

    // Delivery: pictures leave in the order they came.
    private struct Pending: @unchecked Sendable {
        let sequence: UInt64
        var result: Drawn?
        let done: @Sendable (CVPixelBuffer) -> Void
    }
    private let delivery = OSAllocatedUnfairLock(initialState: (next: UInt64(0), pending: [Pending]()))

    // Queue state.
    private var gpu: GPU?
    private var gpuFailed = false
    private var pool: (pool: CVPixelBufferPool, format: OSType, width: Int, height: Int)?
    private var prepared: (key: PreparedKey, texture: MTLTexture)?
    private let loggedFailure = OSAllocatedUnfairLock(initialState: false)

    // The caption style: loaded on the first activation (the system read and its observation cost nothing until a
    // window shows cues), then whatever the last change said.
    private let style = OSAllocatedUnfairLock(initialState: (current: SubtitleCaptionStyle.standard, loaded: false))
    private let styleObservation = OSAllocatedUnfairLock<SubtitleCaptionStyle.Observation?>(initialState: nil)

    init(bufferAttributes: [String: Any]) {
        self.bufferAttributes = bufferAttributes
    }

    /// Main actor: whether the window is up, and the cues it shows.
    func update(_ new: State) {
        state.withLock { $0 = new }
        guard !new.active else {
            if !style.withLock({ $0.loaded }) { loadStyle() }
            return
        }
        queue.async { self.pool = nil; self.prepared = nil }
    }

    /// The one system read, with the observation seeded from it.
    private func loadStyle() {
        let initial = SubtitleCaptionStyle.current()
        let observation = SubtitleCaptionStyle.observeChanges(startingFrom: initial) { [weak self] in self?.setStyle($0) }
        // A `setStyle` that got in first is newer than what was just read.
        style.withLock { if !$0.loaded { $0 = (initial, true) } }
        styleObservation.withLock { if $0 == nil { $0 = observation } }
    }

    /// Any thread: the viewer's caption style changed. The next picture with a cue on it is drawn in it; the prepared
    /// cues are keyed by the style, so none drawn in the old one is served again.
    func setStyle(_ new: SubtitleCaptionStyle) {
        style.withLock { $0 = (new, true) }
    }

    /// Whether pictures go through ``draw(on:atItemSeconds:done:)``: while the window is up, and until every picture
    /// handed in before it came down has come back, so none overtakes another.
    var routesPictures: Bool {
        state.withLock { $0.active } || delivery.withLock { !$0.pending.isEmpty }
    }

    /// The picture at `itemSeconds` with the cues on it at that time, handed to `done` once the GPU has drawn them, in
    /// the order pictures were handed in; the picture itself when no cue is on it or it cannot be drawn on.
    func draw(on picture: CVPixelBuffer, atItemSeconds itemSeconds: Double,
              done: @escaping @Sendable (CVPixelBuffer) -> Void) {
        let sequence = delivery.withLock { state -> UInt64 in
            defer { state.next += 1 }
            state.pending.append(Pending(sequence: state.next, result: nil, done: done))
            return state.next
        }
        let job = Job(sequence: sequence, picture: picture)
        queue.async {
            let snapshot = self.state.withLock { $0 }
            let cues = snapshot.active ? SubtitleFrameCompositor.activeCues(
                in: snapshot.cues, at: itemSeconds + snapshot.sourceShift, delaySeconds: snapshot.delaySeconds) : []
            guard !cues.isEmpty else { return self.finish(job.sequence, with: Drawn(picture: job.picture)) }
            self.encode(cues, on: job.picture) { drawn in
                self.finish(job.sequence, with: drawn ?? Drawn(picture: job.picture))
            }
        }
    }

    private struct Job: @unchecked Sendable {
        let sequence: UInt64
        let picture: CVPixelBuffer
    }

    /// A picture the GPU has drawn the cues on.
    private struct Drawn: @unchecked Sendable {
        let picture: CVPixelBuffer
    }

    private func finish(_ sequence: UInt64, with drawn: Drawn) {
        delivery.withLock { state in
            guard let index = state.pending.firstIndex(where: { $0.sequence == sequence }) else { return }
            state.pending[index].result = drawn
            while let first = state.pending.first, let result = first.result {
                state.pending.removeFirst()
                first.done(result.picture)
            }
        }
    }

    // MARK: - GPU

    private struct GPU: @unchecked Sendable {
        let device: MTLDevice
        let submitter: GPUSubmitter
        let library: MTLLibrary
        let textureCache: CVMetalTextureCache
    }

    /// How a picture is coded, as the blend needs it.
    struct Coding: Hashable {
        enum Transfer: UInt32 { case sdr = 0, pq = 1, hlg = 2 }
        var transfer: Transfer
        var bt2020: Bool
        var kr: Float
        var kb: Float
        var bits: Int
        var fullRange: Bool

        /// The format's depth and range; nil for a format the blend does not read.
        static func layout(of format: OSType) -> (bits: Int, fullRange: Bool)? {
            switch format {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange: (8, false)
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_444YpCbCr8BiPlanarFullRange: (8, true)
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange: (10, false)
            case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
                 kCVPixelFormatType_444YpCbCr10BiPlanarFullRange: (10, true)
            case kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange: (16, false)
            default: nil
            }
        }

        init?(of picture: CVPixelBuffer) {
            guard let layout = Self.layout(of: CVPixelBufferGetPixelFormatType(picture)) else { return nil }
            func attachment(_ key: CFString) -> CFString? { CVBufferCopyAttachment(picture, key, nil).map { $0 as! CFString } }
            let transfer = attachment(kCVImageBufferTransferFunctionKey)
            self.transfer = transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ ? .pq
                : transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG ? .hlg : .sdr
            bt2020 = attachment(kCVImageBufferColorPrimariesKey) == kCVImageBufferColorPrimaries_ITU_R_2020
            let matrices: [CFString: (Float, Float)] = [
                kCVImageBufferYCbCrMatrix_ITU_R_2020: (0.2627, 0.0593),
                kCVImageBufferYCbCrMatrix_ITU_R_601_4: (0.299, 0.114),
                kCVImageBufferYCbCrMatrix_SMPTE_240M_1995: (0.212, 0.087),
                kCVImageBufferYCbCrMatrix_ITU_R_709_2: (0.2126, 0.0722),
            ]
            (kr, kb) = attachment(kCVImageBufferYCbCrMatrixKey).flatMap { matrices[$0] }
                ?? (bt2020 ? (0.2627, 0.0593) : (0.2126, 0.0722))
            bits = layout.bits
            fullRange = layout.fullRange
        }

        var maxCode: Float { Float((1 << bits) - 1) }
        var planeFormats: (luma: MTLPixelFormat, chroma: MTLPixelFormat) {
            bits == 8 ? (.r8Unorm, .rg8Unorm) : (.r16Unorm, .rg16Unorm)
        }

        /// `SubtitleEncoding` in SubtitleBlend.metal: the matrix, and Y' and Cb/Cr to codes over the largest code.
        var encoding: (kr: Float, kb: Float, yScale: Float, yOffset: Float, cScale: Float, cOffset: Float) {
            let step = Float(1 << (bits - 8)) / maxCode
            let half = Float(1 << (bits - 1)) / maxCode
            return fullRange ? (kr, kb, 1, 0, 1, half) : (kr, kb, 219 * step, 16 * step, 224 * step, half)
        }
    }

    private struct PreparedKey: Equatable {
        let cueIDs: [Int]
        let width: Int
        let height: Int
        let coding: Coding
        let style: SubtitleCaptionStyle
    }

    /// Queue: draws `cues` on a copy of `picture` and hands it to `completion` once the GPU has; nil when it cannot.
    private func encode(_ cues: [SubtitleCue], on picture: CVPixelBuffer,
                        completion: @escaping @Sendable (Drawn?) -> Void) {
        guard let gpu = readyGPU(), let coding = Coding(of: picture) else {
            fail("no GPU, or a picture format the blend does not read (\(SoftwareOverlayRenderer.fourCC(CVPixelBufferGetPixelFormatType(picture))))")
            return completion(nil)
        }
        let width = CVPixelBufferGetWidth(picture), height = CVPixelBufferGetHeight(picture)
        let raster = Self.rasterSize(of: picture)
        let key = PreparedKey(cueIDs: cues.map(\.id), width: raster.width, height: raster.height, coding: coding,
                              style: style.withLock { $0.current })
        let format = CVPixelBufferGetPixelFormatType(picture)
        do {
            guard let output = outputBuffer(format: format, width: width, height: height) else { throw Failure("no picture from the pool") }
            CVBufferRemoveAllAttachments(output)
            CVBufferPropagateAttachments(picture, output)
            let planes = coding.planeFormats
            let textures = try [(picture, 0, planes.luma), (picture, 1, planes.chroma), (output, 0, planes.luma), (output, 1, planes.chroma)]
                .map { try texture($0.0, plane: $0.1, format: $0.2, cache: gpu.textureCache) }
            let luma = try pipeline("subtitle_blend_luma", Self.blendConstants(bits: coding.bits), key: "\(coding.bits)", gpu)
            let chroma = try pipeline("subtitle_blend_chroma", Self.blendConstants(bits: coding.bits), key: "\(coding.bits)", gpu)

            guard let batch = gpu.submitter.makeBatch(orderedAfterEarlierWork: true), let pass = batch.makePass() else {
                throw Failure("no batch")
            }
            var held: [AnyObject] = [luma, chroma] + textures
            let preparedTexture: MTLTexture
            if let prepared, prepared.key == key {
                preparedTexture = prepared.texture
            } else {
                let made = try prepare(cues, key: key, gpu: gpu, pass: pass, held: &held)
                prepared = (key, made)
                preparedTexture = made
                pass.barrier()
            }
            held.append(preparedTexture)
            for (pipeline, source, destination) in [(luma, textures[0], textures[2]), (chroma, textures[1], textures[3])] {
                let target = CVMetalTextureGetTexture(destination)!
                pass.setPipeline(pipeline)
                pass.setTexture(CVMetalTextureGetTexture(source)!, index: 0)
                pass.setTexture(target, index: 1)
                pass.setTexture(preparedTexture, index: 2)
                pass.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            }
            let resources = Held(held + [output, picture])
            let drawn = Drawn(picture: output)
            batch.commit { [weak self] result in
                withExtendedLifetime(resources) {}
                CVMetalTextureCacheFlush(gpu.textureCache, 0)
                if let error = result.error {
                    if let self {
                        self.fail("the GPU refused the blend: \(error)")
                        self.queue.async { self.prepared = nil }
                    }
                    completion(nil)
                } else {
                    completion(drawn)
                }
            }
        } catch {
            fail("\(error)")
            completion(nil)
        }
    }

    /// Encodes the cue set's raster turned into the picture's coding, into a texture of its own.
    private func prepare(_ cues: [SubtitleCue], key: PreparedKey, gpu: GPU, pass: ComputePass,
                         held: inout [AnyObject]) throws -> MTLTexture {
        guard let image = SubtitleFrameCompositor.renderOverlay(for: cues, frameWidth: CGFloat(key.width),
                                                                frameHeight: CGFloat(key.height), style: key.style),
              let bytes = image.dataProvider?.data, let base = CFDataGetBytePtr(bytes) else {
            throw Failure("the cues could not be drawn")
        }
        let rasterDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: key.width,
                                                                        height: key.height, mipmapped: false)
        rasterDescriptor.usage = .shaderRead
        rasterDescriptor.storageMode = .shared
        let preparedDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: key.width,
                                                                          height: key.height, mipmapped: false)
        preparedDescriptor.usage = [.shaderRead, .shaderWrite]
        preparedDescriptor.storageMode = .private
        guard let raster = gpu.device.makeTexture(descriptor: rasterDescriptor),
              let prepared = gpu.device.makeTexture(descriptor: preparedDescriptor) else { throw Failure("no textures") }
        raster.replace(region: MTLRegionMake2D(0, 0, key.width, key.height), mipmapLevel: 0, withBytes: base,
                       bytesPerRow: image.bytesPerRow)
        let transfer = key.coding.transfer, bt2020 = key.coding.bt2020
        let pipeline = try pipeline("subtitle_prepare", Self.prepareConstants(transfer: transfer, bt2020: bt2020),
                                    key: "\(transfer.rawValue) \(bt2020)", gpu)
        let e = key.coding.encoding
        pass.setPipeline(pipeline)
        pass.setTexture(raster, index: 0)
        pass.setTexture(prepared, index: 1)
        pass.setValue((e.kr, e.kb, e.yScale, e.yOffset, e.cScale, e.cOffset), index: 0)
        pass.dispatchThreads(MTLSize(width: key.width, height: key.height, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        held += [pipeline, raster]
        return prepared
    }

    /// The size the cues are drawn at: the picture's display aspect (its pixel aspect ratio applied), at most
    /// ``rasterLines`` tall, so text keeps its shape once the picture is stretched to display.
    static func rasterSize(of picture: CVPixelBuffer) -> (width: Int, height: Int) {
        let width = Double(CVPixelBufferGetWidth(picture)), height = Double(CVPixelBufferGetHeight(picture))
        var aspect = width / max(height, 1)
        if let ratio = CVBufferCopyAttachment(picture, kCVImageBufferPixelAspectRatioKey, nil) as? [CFString: Any],
           let h = (ratio[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? NSNumber)?.doubleValue,
           let v = (ratio[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? NSNumber)?.doubleValue, h > 0, v > 0 {
            aspect *= h / v
        }
        let lines = min(Int(height), rasterLines)
        return (max(1, Int((Double(lines) * aspect).rounded())), lines)
    }

    private func readyGPU() -> GPU? {
        if let gpu { return gpu }
        guard !gpuFailed else { return nil }
        guard let device = MTLCreateSystemDefaultDevice(),
              let submitter = GPUSubmitter(device: device, label: "OverlaySubtitles"),
              let library = try? EngineShaders.library(for: device) else { gpuFailed = true; return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            gpuFailed = true
            return nil
        }
        gpu = GPU(device: device, submitter: submitter, library: library, textureCache: cache)
        return gpu
    }

    private var pipelines: [String: MTLComputePipelineState] = [:]

    /// `subtitle_prepare`'s constants for a picture of `transfer` and primaries.
    static func prepareConstants(transfer: Coding.Transfer, bt2020: Bool) -> MTLFunctionConstantValues {
        let constants = MTLFunctionConstantValues()
        var transfer = transfer.rawValue, bt2020 = bt2020
        constants.setConstantValue(&transfer, type: .uint, index: 40)
        constants.setConstantValue(&bt2020, type: .bool, index: 41)
        return constants
    }

    /// The blends' constants for a picture of `bits` per sample.
    static func blendConstants(bits: Int) -> MTLFunctionConstantValues {
        let constants = MTLFunctionConstantValues()
        var maxCode = Float((1 << bits) - 1), containerScale: Float = bits == 10 ? 65472.0 / 65535.0 : 1
        constants.setConstantValue(&maxCode, type: .float, index: 42)
        constants.setConstantValue(&containerScale, type: .float, index: 43)
        return constants
    }

    /// Every pipeline the blend makes, for the engine's shader archive.
    static func archivedRequests() -> [(function: String, constants: MTLFunctionConstantValues?)] {
        var requests: [(function: String, constants: MTLFunctionConstantValues?)] = []
        for transfer in [Coding.Transfer.sdr, .pq, .hlg] {
            for bt2020 in [false, true] {
                requests.append(("subtitle_prepare", prepareConstants(transfer: transfer, bt2020: bt2020)))
            }
        }
        for bits in [8, 10, 16] {
            requests.append(("subtitle_blend_luma", blendConstants(bits: bits)))
            requests.append(("subtitle_blend_chroma", blendConstants(bits: bits)))
        }
        return requests
    }

    /// `function` with `constants`, made once and kept: `key` names the constants.
    private func pipeline(_ function: String, _ constants: MTLFunctionConstantValues, key: String,
                          _ gpu: GPU) throws -> MTLComputePipelineState {
        if let known = pipelines[function + " " + key] { return known }
        let made = try gpu.submitter.makeComputePipeline(library: gpu.library, function: function, constants: constants,
                                                         archive: EngineShaders.archive)
        pipelines[function + " " + key] = made
        return made
    }

    private func outputBuffer(format: OSType, width: Int, height: Int) -> CVPixelBuffer? {
        if pool?.format != format || pool?.width != width || pool?.height != height {
            var attributes = bufferAttributes
            attributes[kCVPixelBufferPixelFormatTypeKey as String] = format
            attributes[kCVPixelBufferWidthKey as String] = width
            attributes[kCVPixelBufferHeightKey as String] = height
            attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = attributes[kCVPixelBufferIOSurfacePropertiesKey as String] ?? [String: Any]()
            attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
            var made: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &made)
            pool = made.map { ($0, format, width, height) }
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool.pool, &buffer)
        return buffer
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat,
                         cache: CVMetalTextureCache) throws -> CVMetalTexture {
        var texture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture
        ) == kCVReturnSuccess, let texture else { throw Failure("plane \(plane) as a texture") }
        return texture
    }

    private func fail(_ reason: String) {
        let first = loggedFailure.withLock { logged in
            defer { logged = true }
            return !logged
        }
        if first { EngineLog.emit("[OverlaySubtitles] a picture went on without its subtitles: \(reason)", category: .swPlayback) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// What a committed batch binds, kept until it completes: command buffers retain nothing.
    private final class Held: @unchecked Sendable {
        let objects: [AnyObject]
        init(_ objects: [AnyObject]) { self.objects = objects }
    }
}
