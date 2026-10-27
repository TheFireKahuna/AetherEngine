import XCTest
@testable import AetherEngine

final class FileIOReaderTests: XCTestCase {
    func test_readSeekSize() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fioreader-\(UUID().uuidString).bin")
        let bytes = Data((0..<100).map { UInt8($0) })
        try bytes.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let r = try XCTUnwrap(FileIOReader(url: tmp))
        XCTAssertEqual(r.seek(offset: 0, whence: 65536), 100)   // AVSEEK_SIZE
        XCTAssertEqual(r.seek(offset: 90, whence: SEEK_SET), 90)
        var buf = [UInt8](repeating: 0, count: 20)
        let n = buf.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 20) }
        XCTAssertEqual(n, 10)                                    // clamped at EOF
        XCTAssertEqual(Array(buf.prefix(10)), Array(90..<100))
        r.close()
    }

    func test_readRangeLeavesTheCursor() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fioreader-\(UUID().uuidString).bin")
        let bytes = Data((0..<100).map { UInt8($0) })
        try bytes.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let r = try XCTUnwrap(FileIOReader(url: tmp))
        XCTAssertEqual(r.seek(offset: 10, whence: SEEK_SET), 10)
        XCTAssertEqual(r.readRange(at: 40, count: 5), Data(40..<45))
        XCTAssertEqual(r.readRange(at: 95, count: 20), Data(95..<100))   // clamped at EOF
        XCTAssertEqual(r.readRange(at: 100, count: 4), Data())
        var buf = [UInt8](repeating: 0, count: 3)
        let n = buf.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 3) }
        XCTAssertEqual(n, 3)
        XCTAssertEqual(buf, [10, 11, 12], "a range read moved the cursor")
        r.close()
        XCTAssertNil(r.readRange(at: 0, count: 1))
    }

    func test_initNilForMissingFile() {
        XCTAssertNil(FileIOReader(url: URL(fileURLWithPath: "/no/such/file.iso")))
    }
}
