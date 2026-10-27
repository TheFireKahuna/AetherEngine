import Foundation
import Metal
import os
import AetherLibavcodec
import AetherLibavutil

/// The memory a libavcodec software decoder writes its pictures into: shared-storage `MTLBuffer`s, so a
/// decoded picture is already where the GPU reads it and ``PlanarFrameFinisher`` turns it into the display
/// buffer without a CPU pass over the pixels.
///
/// Installed as the codec context's `get_buffer2` (every decoder the software route opens through
/// libavcodec has `AV_CODEC_CAP_DR1`). The planes are laid out exactly as `avcodec_default_get_buffer2`
/// lays them out (`update_frame_pool` in libavcodec/get_buffer.c): the decoder's aligned dimensions, the
/// same linesize search, the same per-plane padding. Only the allocation differs: one slab per picture,
/// each plane starting on a 64-byte boundary, all of it inside one buffer the GPU can read. libavcodec's
/// reference counting decides when a slab comes back (reference frames, frame threads, a frame the
/// finisher still reads), through the `AVBufferRef` free callback, which may run on any thread.
///
/// Paletted, bitstream and hardware formats keep libavcodec's own allocator: they have no planes a
/// kernel could read.
final class DecodeFrameAllocator: @unchecked Sendable {

    /// One picture's memory. `contents` is the buffer's CPU address; the planes are offsets into it.
    final class Slab: @unchecked Sendable {
        let buffer: MTLBuffer
        let contents: UnsafeMutableRawPointer
        let length: Int
        fileprivate weak var owner: DecodeFrameAllocator?

        fileprivate init(buffer: MTLBuffer, owner: DecodeFrameAllocator) {
            self.buffer = buffer
            contents = buffer.contents()
            length = buffer.length
            self.owner = owner
        }

        /// The byte offset of `pointer` inside the slab, nil when it is not inside it.
        func offset(of pointer: UnsafeRawPointer) -> Int? {
            let delta = pointer - UnsafeRawPointer(contents)
            return delta >= 0 && delta < length ? delta : nil
        }
    }

    /// Start of every plane inside a slab.
    static let planeAlignment = 64
    /// Kept free slabs of the current size; a burst beyond this is released as it comes back.
    static let maxFreeSlabs = 24

    let device: MTLDevice
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var free: [Slab] = []
        var freeLength = 0
        /// Slabs handed out and not yet returned, by address. ``slab(of:)`` looks a buffer's opaque pointer up
        /// here before treating it as a slab: frames from elsewhere carry opaque pointers of their own.
        var live: [UInt: Slab] = [:]
    }

    /// Nil without a Metal device.
    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device else { return nil }
        self.device = device
    }

    /// Makes `ctx` allocate through this allocator. The context's `opaque` holds an unretained reference: the
    /// owner keeps the allocator alive at least as long as the context.
    func install(on ctx: UnsafeMutablePointer<AVCodecContext>) {
        ctx.pointee.opaque = Unmanaged.passUnretained(self).toOpaque()
        ctx.pointee.get_buffer2 = decodeFrameAllocatorGetBuffer
    }

    /// The slab holding `frame`'s pictures, when this allocator made it.
    func slab(of frame: UnsafePointer<AVFrame>) -> Slab? {
        guard let buf = frame.pointee.buf.0, let opaque = av_buffer_get_opaque(buf) else { return nil }
        let key = UInt(bitPattern: opaque)
        return state.withLock { $0.live[key] }
    }

    /// Slabs currently held by libavcodec or by frames, for tests and the log.
    var liveSlabCount: Int { state.withLock { $0.live.count } }

    // MARK: - get_buffer2

    /// The plane layout `update_frame_pool` computes for `frame`'s format and size on `ctx`.
    struct Layout: Equatable {
        var linesizes: [Int32]
        var planeSizes: [Int]
    }

    static func layout(ctx: UnsafeMutablePointer<AVCodecContext>, format: AVPixelFormat,
                       width: Int32, height: Int32) -> Layout? {
        var w = width, h = height
        var strideAlign = [Int32](repeating: 0, count: Int(AV_NUM_DATA_POINTERS))
        avcodec_align_dimensions2(ctx, &w, &h, &strideAlign)
        var linesize = [Int32](repeating: 0, count: 4)
        while true {
            // The linesizes are not aligned one by one: decoders rely on linesize[0] == 2 * linesize[1] for 4:2:2.
            guard av_image_fill_linesizes(&linesize, format, w) >= 0 else { return nil }
            // Widen w by its lowest set bit until every linesize meets its alignment, as libavcodec does.
            w += w & ~(w - 1)
            if !(0..<4).contains(where: { strideAlign[$0] > 0 && linesize[$0] % strideAlign[$0] != 0 }) { break }
        }
        var wide = linesize.map { Int($0) }
        var sizes = [Int](repeating: 0, count: 4)
        guard av_image_fill_plane_sizes(&sizes, format, h, &wide) >= 0 else { return nil }
        let planes = sizes.firstIndex(of: 0) ?? 4
        return Layout(linesizes: Array(linesize.prefix(planes)), planeSizes: Array(sizes.prefix(planes)))
    }

    /// Whether this allocator takes `format`: anything with planes in memory.
    static func takes(_ format: AVPixelFormat) -> Bool {
        guard let desc = av_pix_fmt_desc_get(format)?.pointee else { return false }
        let excluded = UInt64(AV_PIX_FMT_FLAG_PAL) | UInt64(AV_PIX_FMT_FLAG_HWACCEL) | UInt64(AV_PIX_FMT_FLAG_BITSTREAM)
        return desc.flags & excluded == 0
    }

    fileprivate func getBuffer(ctx: UnsafeMutablePointer<AVCodecContext>, frame: UnsafeMutablePointer<AVFrame>,
                               flags: Int32) -> Int32 {
        let format = AVPixelFormat(rawValue: frame.pointee.format)
        guard ctx.pointee.codec_type == AVMEDIA_TYPE_VIDEO, ctx.pointee.hw_frames_ctx == nil, Self.takes(format) else {
            return avcodec_default_get_buffer2(ctx, frame, flags)
        }
        guard let layout = Self.layout(ctx: ctx, format: format, width: frame.pointee.width, height: frame.pointee.height)
        else { return FFmpegErr.einval }

        // libavcodec's own padding per plane (`size[i] + 16 + STRIDE_ALIGN - 1`), with every plane start on the
        // slab's alignment.
        let padding = 16 + Self.planeAlignment
        var offsets: [Int] = []
        var length = 0
        for size in layout.planeSizes {
            offsets.append(length)
            length += (size + padding + Self.planeAlignment - 1) / Self.planeAlignment * Self.planeAlignment
        }
        guard let slab = takeSlab(length: length) else { return FFmpegErr.enomem }
        let opaque = Unmanaged.passRetained(slab).toOpaque()
        guard let ref = av_buffer_create(slab.contents.assumingMemoryBound(to: UInt8.self), slab.length,
                                         decodeFrameAllocatorFree, opaque, 0) else {
            Unmanaged<Slab>.fromOpaque(opaque).release()
            giveBack(slab)
            return FFmpegErr.enomem
        }
        frame.pointee.buf.0 = ref
        withUnsafeMutableBytes(of: &frame.pointee.data) { data in
            let pointers = data.bindMemory(to: UnsafeMutablePointer<UInt8>?.self)
            for i in 0..<pointers.count {
                pointers[i] = i < offsets.count ? (slab.contents + offsets[i]).assumingMemoryBound(to: UInt8.self) : nil
            }
        }
        withUnsafeMutableBytes(of: &frame.pointee.linesize) { sizes in
            let linesizes = sizes.bindMemory(to: Int32.self)
            for i in 0..<linesizes.count { linesizes[i] = i < layout.linesizes.count ? layout.linesizes[i] : 0 }
        }
        frame.pointee.extended_data = withUnsafeMutablePointer(to: &frame.pointee.data) {
            $0.withMemoryRebound(to: UnsafeMutablePointer<UInt8>?.self, capacity: Int(AV_NUM_DATA_POINTERS)) { $0 }
        }
        return 0
    }

    private func takeSlab(length: Int) -> Slab? {
        if let reused: Slab = state.withLock({ state in
            if state.freeLength != length { state.free.removeAll(); state.freeLength = length }
            guard let slab = state.free.popLast() else { return nil }
            state.live[Self.key(slab)] = slab
            return slab
        }) {
            return reused
        }
        // Shared storage is ordinary cached memory on Apple silicon: the decoder's CPU reads and writes of its
        // reference pictures run as they do on av_malloc memory.
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared)
        else { return nil }
        let slab = Slab(buffer: buffer, owner: self)
        state.withLock { $0.live[Self.key(slab)] = slab }
        return slab
    }

    /// The address a slab's `AVBufferRef` carries as its opaque pointer.
    private static func key(_ slab: Slab) -> UInt { UInt(bitPattern: Unmanaged.passUnretained(slab).toOpaque()) }

    // MARK: - Pictures a decoder did not write into a slab

    /// A copy of `frame`'s picture in a slab, for the decoders whose pictures live elsewhere: rawvideo, whose
    /// frames point into the demuxer's packet (for an uncompressed stream the copy is the decode), and the
    /// paletted formats libavcodec allocates itself. Planes 64-byte aligned, palette included. The slab goes
    /// back through ``release(_:)`` once the picture has been read.
    func copy(_ frame: UnsafePointer<AVFrame>) -> (planes: PlanarFrameFinisher.Planes, slab: Slab)? {
        let format = AVPixelFormat(rawValue: frame.pointee.format)
        let width = frame.pointee.width, height = frame.pointee.height
        let size = av_image_get_buffer_size(format, width, height, Int32(Self.planeAlignment))
        guard size > 0, let slab = takeSlab(length: Int(size) + Self.planeAlignment) else { return nil }
        var data = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: 4)
        var linesize = [Int32](repeating: 0, count: 4)
        guard av_image_fill_arrays(&data, &linesize, slab.contents.assumingMemoryBound(to: UInt8.self), format,
                                   width, height, Int32(Self.planeAlignment)) >= 0 else {
            release(slab)
            return nil
        }
        var source = withUnsafeBytes(of: frame.pointee.data) {
            Array($0.bindMemory(to: UnsafeMutablePointer<UInt8>?.self).prefix(4)).map { UnsafePointer($0) }
        }
        var sourceLinesize = withUnsafeBytes(of: frame.pointee.linesize) { Array($0.bindMemory(to: Int32.self).prefix(4)) }
        av_image_copy(&data, &linesize, &source, &sourceLinesize, format, width, height)
        var offsets = [UInt32](repeating: 0, count: 4), sizes = [UInt32](repeating: 0, count: 4)
        for i in 0..<4 {
            guard let pointer = data[i], let offset = slab.offset(of: pointer) else { continue }
            offsets[i] = UInt32(offset)
            sizes[i] = UInt32(linesize[i])
        }
        return (PlanarFrameFinisher.Planes(buffer: slab.buffer, offsets: offsets, linesizes: sizes), slab)
    }

    /// An empty picture of `format` in a slab, planes 64-byte aligned (the inverse-telecine stages' outputs). The slab
    /// goes back through ``release(_:)``.
    func picture(format: AVPixelFormat, width: Int32, height: Int32) -> (planes: PlanarFrameFinisher.Planes, slab: Slab)? {
        let size = av_image_get_buffer_size(format, width, height, Int32(Self.planeAlignment))
        guard size > 0, let slab = takeSlab(length: Int(size) + Self.planeAlignment) else { return nil }
        var data = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: 4)
        var linesize = [Int32](repeating: 0, count: 4)
        guard av_image_fill_arrays(&data, &linesize, slab.contents.assumingMemoryBound(to: UInt8.self), format,
                                   width, height, Int32(Self.planeAlignment)) >= 0 else {
            release(slab)
            return nil
        }
        var offsets = [UInt32](repeating: 0, count: 4), sizes = [UInt32](repeating: 0, count: 4)
        for i in 0..<4 {
            guard let pointer = data[i], let offset = slab.offset(of: pointer) else { continue }
            offsets[i] = UInt32(offset)
            sizes[i] = UInt32(linesize[i])
        }
        return (PlanarFrameFinisher.Planes(buffer: slab.buffer, offsets: offsets, linesizes: sizes), slab)
    }

    /// Returns a slab from ``copy(_:)`` or ``picture(format:width:height:)``.
    func release(_ slab: Slab) { giveBack(slab) }

    fileprivate func giveBack(_ slab: Slab) {
        state.withLock { state in
            state.live[Self.key(slab)] = nil
            if slab.length == state.freeLength, state.free.count < Self.maxFreeSlabs { state.free.append(slab) }
        }
    }
}

private func decodeFrameAllocatorGetBuffer(_ ctx: UnsafeMutablePointer<AVCodecContext>?,
                                           _ frame: UnsafeMutablePointer<AVFrame>?, _ flags: Int32) -> Int32 {
    guard let ctx, let frame, let opaque = ctx.pointee.opaque else { return FFmpegErr.einval }
    return Unmanaged<DecodeFrameAllocator>.fromOpaque(opaque).takeUnretainedValue()
        .getBuffer(ctx: ctx, frame: frame, flags: flags)
}

/// `AVBufferRef` free callback: the last reference to a picture is gone. Any thread.
private func decodeFrameAllocatorFree(_ opaque: UnsafeMutableRawPointer?, _ data: UnsafeMutablePointer<UInt8>?) {
    guard let opaque else { return }
    let slab = Unmanaged<DecodeFrameAllocator.Slab>.fromOpaque(opaque).takeRetainedValue()
    slab.owner?.giveBack(slab)
}
