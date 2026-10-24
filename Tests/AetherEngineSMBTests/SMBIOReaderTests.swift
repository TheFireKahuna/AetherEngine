import XCTest
@testable import AetherEngineSMB

private final class FakeByteRangeSource: ByteRangeSource, @unchecked Sendable {
    let data: Data
    private(set) var closeCount = 0
    let preferredReadSize: Int
    private(set) var reads: [(offset: Int64, length: Int)] = []
    init(_ data: Data, preferredReadSize: Int = 8 * 1024 * 1024) {
        self.data = data
        self.preferredReadSize = preferredReadSize
    }
    var byteSize: Int64 { Int64(data.count) }
    func read(at offset: Int64, length: Int) async throws -> Data {
        reads.append((offset, length))
        guard offset >= 0, offset < data.count, length > 0 else { return Data() }
        let end = min(Int(offset) + length, data.count)
        return data.subdata(in: Int(offset)..<end)
    }
    func close() { closeCount += 1 }
}

private func readN(_ r: SMBIOReader, _ n: Int) -> Data {
    var buf = [UInt8](repeating: 0, count: n)
    let got = buf.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: Int32(n)) }
    return Data(buf.prefix(Int(max(got, 0))))
}

final class SMBIOReaderTests: XCTestCase {
    private let payload = Data((0..<256).map { UInt8($0) })

    func testSequentialReadAdvancesCursor() {
        let r = SMBIOReader(source: FakeByteRangeSource(payload))
        XCTAssertEqual(readN(r, 4), Data([0, 1, 2, 3]))
        XCTAssertEqual(readN(r, 4), Data([4, 5, 6, 7]))
    }

    func testSeekSetThenRead() {
        let r = SMBIOReader(source: FakeByteRangeSource(payload))
        XCTAssertEqual(r.seek(offset: 10, whence: SEEK_SET), 10)
        XCTAssertEqual(readN(r, 2), Data([10, 11]))
    }

    func testSeekCurAndEnd() {
        let r = SMBIOReader(source: FakeByteRangeSource(payload))
        _ = readN(r, 4)
        XCTAssertEqual(r.seek(offset: 4, whence: SEEK_CUR), 8)
        XCTAssertEqual(r.seek(offset: -1, whence: SEEK_END), 255)
        XCTAssertEqual(readN(r, 1), Data([255]))
    }

    func testAvseekSizeReturnsTotalWithoutMovingCursor() {
        let r = SMBIOReader(source: FakeByteRangeSource(payload))
        XCTAssertEqual(r.seek(offset: 8, whence: SEEK_SET), 8)
        XCTAssertEqual(r.seek(offset: 0, whence: 65536), 256) // AVSEEK_SIZE
        XCTAssertEqual(readN(r, 1), Data([8]))               // cursor unmoved
    }

    func testReadAtEofReturnsZero() {
        let r = SMBIOReader(source: FakeByteRangeSource(payload))
        XCTAssertEqual(r.seek(offset: 256, whence: SEEK_SET), 256)
        var buf = [UInt8](repeating: 0, count: 16)
        let got = buf.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 16) }
        XCTAssertEqual(got, 0)
    }

    func testReadSpanningEofTruncates() {
        let r = SMBIOReader(source: FakeByteRangeSource(payload))
        XCTAssertEqual(r.seek(offset: 254, whence: SEEK_SET), 254)
        XCTAssertEqual(readN(r, 16), Data([254, 255]))
    }

    func testInvalidWhenceReturnsNegative() {
        let r = SMBIOReader(source: FakeByteRangeSource(payload))
        XCTAssertLessThan(r.seek(offset: 0, whence: 999), 0)
    }

    func testOwnedSourceClosesOnceIndependentDoesNot() {
        let src = FakeByteRangeSource(payload)
        let primary = SMBIOReader(source: src, ownsSource: true)
        let secondary = primary.makeIndependentReader()
        secondary?.close()
        XCTAssertEqual(src.closeCount, 0) // independent reader must not close shared source
        primary.close()
        primary.close()                   // idempotent
        XCTAssertEqual(src.closeCount, 1)
    }

    func testDiscImageProbeDefaultsOnAndIndependentReaderPreservesOptOut() throws {
        let defaultReader = SMBIOReader(source: FakeByteRangeSource(payload))
        XCTAssertTrue(defaultReader.discImageProbeEnabled)

        let ordinaryMediaReader = SMBIOReader(
            source: FakeByteRangeSource(payload),
            discImageProbeEnabled: false
        )
        XCTAssertFalse(ordinaryMediaReader.discImageProbeEnabled)
        let independent = try XCTUnwrap(ordinaryMediaReader.makeIndependentReader())
        XCTAssertFalse(independent.discImageProbeEnabled)
    }

    func testSmallReadsAreServedFromOneBlock() {
        let src = FakeByteRangeSource(payload)
        let r = SMBIOReader(source: src)
        for i in 0..<16 { XCTAssertEqual(readN(r, 4), Data(((i * 4)..<(i * 4 + 4)).map { UInt8($0) })) }
        XCTAssertEqual(src.reads.count, 1, "each read was its own round trip")
        XCTAssertEqual(src.reads.first?.length, SMBIOReader.blockFloor)
    }

    func testSequentialBlocksGrowToThePreferredReadSize() {
        let big = Data(count: 8 * 1024 * 1024)
        let src = FakeByteRangeSource(big, preferredReadSize: 1024 * 1024)
        let r = SMBIOReader(source: src)
        var total = 0
        while total < big.count {
            let got = readN(r, 256 * 1024).count
            if got == 0 { break }
            total += got
        }
        XCTAssertEqual(total, big.count)
        let kib = 1024
        let ramp: [Int] = [256 * kib, 512 * kib, 1024 * kib, 1024 * kib]
        let lengths: [Int] = src.reads.map { $0.length }
        XCTAssertEqual(Array(lengths.prefix(4)), ramp)
        let rampBytes = 768 * 1024, block = 1024 * 1024
        let expected: Int = 2 + (big.count - rampBytes + block - 1) / block
        XCTAssertEqual(src.reads.count, expected)
    }

    func testSeekOutsideTheBlockFetchesAtTheTarget() {
        let big = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let src = FakeByteRangeSource(big)
        let r = SMBIOReader(source: src)
        _ = readN(r, 4)
        XCTAssertEqual(r.seek(offset: 1_500_000, whence: SEEK_SET), 1_500_000)
        XCTAssertEqual(readN(r, 2), Data([UInt8(truncatingIfNeeded: 1_500_000), UInt8(truncatingIfNeeded: 1_500_001)]))
        XCTAssertEqual(src.reads.last?.offset, 1_500_000)
        XCTAssertEqual(src.reads.last?.length, SMBIOReader.blockFloor, "a jump starts the ramp again")
        // Inside the block the jump fetched: no further round trip.
        XCTAssertEqual(r.seek(offset: 1_500_100, whence: SEEK_SET), 1_500_100)
        let before = src.reads.count
        _ = readN(r, 4)
        XCTAssertEqual(src.reads.count, before)
    }

    func testNegativeSeekDoesNotCorruptCursor() {
        let r = SMBIOReader(source: FakeByteRangeSource(payload))
        XCTAssertEqual(r.seek(offset: 10, whence: SEEK_SET), 10)
        XCTAssertEqual(readN(r, 2), Data([10, 11]))
        XCTAssertLessThan(r.seek(offset: -999, whence: SEEK_SET), 0)
        // Cursor must be unchanged: next read should still start at 12.
        XCTAssertEqual(readN(r, 2), Data([12, 13]))
    }
}
