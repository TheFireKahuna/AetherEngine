import Compression
import Foundation

/// One zlib-wrapped block (RFC 1950: a two-byte header, a deflate stream, a four-byte Adler-32),
/// inflated. Matroska's ContentCompression algorithm 0 stores subtitle frames this way; libavformat
/// inflates them before it hands a packet over, and so does every engine path that reads a block
/// itself (`MatroskaCueIndex.readFrame`), so a frame is the same bytes whichever path read it.
enum ZlibBlock {
    /// The most an inflated block may grow to: a subtitle frame, never a film.
    static let maximumInflatedBytes = 8 * 1024 * 1024

    static func inflate(_ src: UnsafePointer<UInt8>, size: Int) -> [UInt8]? {
        guard size > 6 else { return nil }
        return inflateDeflate(src.advanced(by: 2), size: size - 2 - 4, sizeHint: size)
    }

    /// A raw deflate stream, inflated: the body of a zlib block and of a gzip member alike.
    /// `sizeHint` sizes the first attempt, which doubles until the result fits.
    static func inflateDeflate(_ stream: UnsafePointer<UInt8>, size: Int, sizeHint: Int) -> [UInt8]? {
        guard size > 0 else { return nil }
        var capacity = max(sizeHint * 8, 4096)
        while capacity <= maximumInflatedBytes {
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }
            let written = compression_decode_buffer(dst, capacity, stream, size, nil, COMPRESSION_ZLIB)
            if written > 0 && written < capacity { return Array(UnsafeBufferPointer(start: dst, count: written)) }
            if written == 0 { return nil }
            capacity *= 2
        }
        return nil
    }

    static func inflate(_ bytes: [UInt8]) -> [UInt8]? {
        bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.flatMap { inflate($0, size: buffer.count) }
        }
    }
}
