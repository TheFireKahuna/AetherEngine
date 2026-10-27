// Tests/AetherEngineTests/Issue377ReaderTransportLogTests.swift
// AE#377: the transport line answered its question in the field (the reporter's CDN turned out to be
// http/1.1, so a connection cap does bind there), but the reuse half of the same line could not be read.
// It was emitted at the FIRST metrics callback for an origin, where "connection new" is what a first
// connection nearly always is, so it said "new" for every http/1.1 origin regardless of whether the
// session went on to reuse that connection a hundred times. These tests pin that the transport verdict
// still lands on the first connection, and that reuse is only claimed once there is a sample behind it.
import XCTest
@testable import AetherEngine

final class Issue377ReaderTransportLogTests: XCTestCase {

    private var tap: EngineLogCapture!

    override func setUp() {
        super.setUp()
        ReaderTransportLog.resetForTesting()
        tap = EngineLogCapture()
    }

    override func tearDown() {
        tap.end()
        tap = nil
        ReaderTransportLog.resetForTesting()
        super.tearDown()
    }

    // MARK: The transport verdict

    func testTransportLineLandsOnTheFirstConnectionAndOnlyOnce() {
        for _ in 0..<5 {
            ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: true,
                                    originKey: "https://cdn.example.com")
        }
        XCTAssertEqual(tap.matching("origin transport:").count, 1)
    }

    func testMultiplexedTransportSaysAConnectionCapBoundsNothing() {
        ReaderTransportLog.note(protocolName: "h2", reusedConnection: false,
                                originKey: "https://cdn.example.com")
        let line = tap.matching("origin transport:").first ?? ""
        XCTAssertTrue(line.contains("h2"), line)
        XCTAssertTrue(line.contains("bounds nothing"), line)
    }

    func testSerialTransportSaysAConnectionCapBoundsRequests() {
        ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: false,
                                originKey: "https://nexus-128.example.st")
        let line = tap.matching("origin transport:").first ?? ""
        XCTAssertTrue(line.contains("http/1.1"), line)
        XCTAssertTrue(line.contains("one request per connection"), line)
        XCTAssertTrue(line.contains("bounds requests"), line)
    }

    func testTransportVerdictIsPerOrigin() {
        ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: false,
                                originKey: "https://portal.example.com")
        ReaderTransportLog.note(protocolName: "h2", reusedConnection: false,
                                originKey: "https://cdn.example.com")
        XCTAssertEqual(tap.matching("origin transport:").count, 2)
    }

    /// A dual-stack origin's line says which family the connection landed on, so a session that fell
    /// back to v4 is visible without a packet capture.
    func testTransportLineNamesTheAddressFamily() {
        ReaderTransportLog.note(protocolName: "h3", reusedConnection: false,
                                originKey: "https://media.example.com",
                                remoteAddress: "2404:e80:8b7d:1::23")
        ReaderTransportLog.note(protocolName: "h2", reusedConnection: false,
                                originKey: "https://cdn.example.com", remoteAddress: "192.168.10.23")
        ReaderTransportLog.note(protocolName: "h2", reusedConnection: false,
                                originKey: "https://other.example.com")
        let lines = tap.matching("origin transport:")
        XCTAssertTrue(lines.contains { $0.contains("h3 over IPv6 at https://media.example.com") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("h2 over IPv4 at https://cdn.example.com") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("h2 at https://other.example.com") }, "\(lines)")
    }

    // MARK: The reuse tally

    /// The defect this file exists for: a first connection is not evidence about reuse, so nothing may
    /// be claimed about it yet.
    func testNoReuseClaimBeforeThereIsASample() {
        ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: false,
                                originKey: "https://cdn.example.com")
        XCTAssertTrue(tap.matching("origin connections:").isEmpty)
        XCTAssertFalse(tap.matching("origin transport:").first?.contains("connection new") ?? false)
    }

    func testReuseIsReportedOnceTheSampleIsInAndCountsBothSides() {
        let size = ReaderTransportLog.reuseSampleSize
        ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: false,
                                originKey: "https://cdn.example.com")
        for _ in 1..<size {
            ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: true,
                                    originKey: "https://cdn.example.com")
        }
        let line = tap.matching("origin connections:").first ?? ""
        XCTAssertTrue(line.contains("\(size - 1) of \(size) reader connections reused"), line)
    }

    func testAnOriginThatNeverReusesSaysWhatThatCosts() {
        for _ in 0..<ReaderTransportLog.reuseSampleSize {
            ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: false,
                                    originKey: "https://cdn.example.com")
        }
        let line = tap.matching("origin connections:").first ?? ""
        XCTAssertTrue(line.contains("0 of \(ReaderTransportLog.reuseSampleSize)"), line)
        XCTAssertTrue(line.contains("fresh handshake"), line)
    }

    /// One line per origin, like the transport line: a session reconnecting for an hour must not turn
    /// this into a per-connection trace.
    func testReuseIsReportedOnlyOncePerOrigin() {
        for _ in 0..<(ReaderTransportLog.reuseSampleSize * 4) {
            ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: true,
                                    originKey: "https://cdn.example.com")
        }
        XCTAssertEqual(tap.matching("origin connections:").count, 1)
    }

    func testTalliesDoNotBleedBetweenOrigins() {
        for _ in 0..<(ReaderTransportLog.reuseSampleSize - 1) {
            ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: true,
                                    originKey: "https://portal.example.com")
            ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: true,
                                    originKey: "https://cdn.example.com")
        }
        XCTAssertTrue(tap.matching("origin connections:").isEmpty,
                      "two origins one connection short of the sample must not add up to one sample")
    }
}
