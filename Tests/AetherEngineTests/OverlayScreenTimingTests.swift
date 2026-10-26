#if os(macOS)
// The software overlay's pictures on a real screen. The clip (Fixtures/avsync/mpeg2-barcode.mkv) carries its frame
// number as a 12-bit barcode in the top half and the A/V sync clips' white frame and click at 1.000 s, in MPEG-2, so it
// plays through the overlay. Two reads of the screen:
// - ScreenCaptureKit's frames of the window, read by their barcodes: every picture on screen, in order, none
//   skipped. Its timestamps follow the capture's own cadence (at a fixed 47.95 Hz they slid against the refresh grid
//   by about a millisecond a picture), so they are printed, not judged.
// - The overlay's own buffer-return measurement (``SurfaceReturnWatch``): every picture's buffer taken by the
//   compositor and given back. At a fixed refresh rate its returns lie on the refresh grid to the millisecond.
//
// Opt-in (AE_SCREEN_TESTS=1): it opens a window, needs the screen awake and unlocked, and needs Screen Recording
// permission for the process running the tests (macOS asks on the first run; grant it in System Settings, then run
// again).
import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os
import ScreenCaptureKit
import Testing
@testable import AetherEngine

@Suite("Overlay pictures on screen", .serialized)
@MainActor
struct OverlayScreenTimingTests {
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["AE_SCREEN_TESTS"] == "1" }
    nonisolated static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/avsync/mpeg2-barcode.mkv")

    /// The frame number a picture carries: 12 bands across the top half, least significant bit on the left, each
    /// read at its centre, a quarter of the way down. `luma(x, y)` is a sample in 0...255.
    nonisolated static func frameNumber(width: Int, height: Int, luma: (Int, Int) -> Int) -> Int {
        (0..<12).reduce(0) { n, k in
            n | (luma(Int((Double(k) + 0.5) * Double(width) / 12), height / 4) > 128 ? 1 << k : 0)
        }
    }

    /// The frame number of a decoded picture, from its luma plane (8- or 16-bit).
    nonisolated static func frameNumber(decoded picture: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(picture, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(picture, 0), height = CVPixelBufferGetHeightOfPlane(picture, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(picture, 0)
        let base = CVPixelBufferGetBaseAddressOfPlane(picture, 0)!
        let wide = stride >= 2 * width
        return frameNumber(width: width, height: height) { x, y in
            wide ? Int(base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)[x] >> 8)
                 : Int(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)[x])
        }
    }

    /// One captured frame: its display time (host seconds), the frame number it shows, and whether its bottom half is
    /// the white frame.
    struct Captured: Sendable {
        let host: Double
        let number: Int
        let white: Bool
    }

    /// Takes the window server's frames of one window, the complete ones (new content) only.
    final class Capture: NSObject, SCStreamOutput, @unchecked Sendable {
        let frames = OSAllocatedUnfairLock(initialState: [Captured]())

        func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen,
                  let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  (info[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)) == .complete,
                  let displayTime = info[.displayTime] as? UInt64,
                  let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let green = { (x: Int, y: Int) in Int(base[y * stride + 4 * x + 1]) }
            let number = OverlayScreenTimingTests.frameNumber(width: width, height: height, luma: green)
            let host = CMClockMakeHostTimeFromSystemUnits(displayTime).seconds
            let white = green(width / 2, 3 * height / 4) > 128
            frames.withLock { $0.append(Captured(host: host, number: number, white: white)) }
        }
    }

    @Test("every picture's buffer is taken by the compositor and given back", .enabled(if: enabled),
          .timeLimit(.minutes(2)))
    func buffersReturnedOnScreen() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.fixture.path), "run Scripts/fetch-fixtures.sh")
        let screen = try #require(NSScreen.main)
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let previous = EngineLog.handler
        EngineLog.handler = { line in
            if line.contains("on screen (buffers returned)") || line.contains("renderer metrics") { lines.withLock { $0.append(line) } }
            previous?(line)
        }
        defer { EngineLog.handler = previous }
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(url: Self.fixture, options: LoadOptions())
        let player = try #require(engine.currentAVPlayer)
        player.isMuted = true
        let deadline = Date().addingTimeInterval(30)
        while engine.softwareOverlay == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let renderer = try #require(engine.softwareOverlay)
        let size = CGSize(width: 640, height: 360)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: screen.frame.midX - size.width / 2,
                                                                  y: screen.frame.midY - size.height / 2), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.isReleasedWhenClosed = false
        let content = try #require(window.contentView)
        content.wantsLayer = true
        renderer.layer.frame = content.bounds
        content.layer?.addSublayer(renderer.layer)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        engine.play()
        while lines.withLock({ $0.filter { $0.contains("buffers returned") }.count }) < 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let all = lines.withLock { $0 }
        for line in all { print("[OverlayScreenTiming] \(line)") }
        let line = try #require(all.first { $0.contains("buffers returned") })
        let neverShown = try #require(line.firstMatch(of: /never shown (\d+)/).map { Int($0.1)! })
        let counted = try #require(line.firstMatch(of: /refreshes on screen \[([^\]]*)\]/)).1
            .split(separator: ",").compactMap { Int($0.split(separator: ":").last!.trimmingCharacters(in: .whitespaces)) }
            .reduce(0, +)
        #expect(neverShown == 0, "pictures whose buffer the compositor never took: \(line)")
        // A ten-second window at 24 pictures a second, less the first.
        #expect(counted >= 200, "\(counted) pictures returned in the window: \(line)")
    }

    @Test("every picture reaches the screen, in order, none skipped",
          .enabled(if: enabled), .timeLimit(.minutes(2)))
    func picturesOnScreenAtTheirTime() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.fixture.path), "run Scripts/fetch-fixtures.sh")
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            Issue.record("grant Screen Recording to the app running the tests (System Settings, Privacy & Security), then run again")
            return
        }
        let screen = try #require(NSScreen.main)

        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(url: Self.fixture, options: LoadOptions())
        let player = try #require(engine.currentAVPlayer)
        player.isMuted = true
        let deadline = Date().addingTimeInterval(20)
        while engine.softwareOverlay == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let renderer = try #require(engine.softwareOverlay)
        let timebase = try #require(player.currentItem?.timebase)
        let stamps = OSAllocatedUnfairLock(initialState: [Int: Double]())
        renderer.onPresented = { time, picture in
            let number = Self.frameNumber(decoded: picture)
            stamps.withLock { $0[number] = time.seconds }
        }

        // The overlay's layer in a window of its own, at the picture's size in points.
        let size = CGSize(width: 640, height: 360)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: screen.frame.midX - size.width / 2,
                                                                  y: screen.frame.midY - size.height / 2), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.isReleasedWhenClosed = false
        let content = try #require(window.contentView)
        content.wantsLayer = true
        renderer.layer.frame = content.bounds
        content.layer?.addSublayer(renderer.layer)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))

        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let scWindow = try #require(shareable.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width * screen.backingScaleFactor)
        configuration.height = Int(size.height * screen.backingScaleFactor)
        configuration.minimumFrameInterval = CMTime(seconds: screen.minimumRefreshInterval, preferredTimescale: 1_000_000)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 8
        configuration.showsCursor = false
        let capture = Capture()
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: configuration, delegate: nil)
        try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: DispatchQueue(label: "overlay-screen-capture"))
        try await stream.startCapture()
        engine.play()
        while (stamps.withLock { $0.keys.max() } ?? 0) < 5 * 24, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await stream.stopCapture()

        // Each picture's first display, in capture order, with its item time then.
        var firsts: [(number: Int, host: Double, item: Double, white: Bool)] = []
        for frame in capture.frames.withLock({ $0 }).sorted(by: { $0.host < $1.host }) where frame.number != firsts.last?.number {
            let item = CMSyncConvertTime(CMTime(seconds: frame.host, preferredTimescale: 1_000_000_000),
                                         from: CMClockGetHostTimeClock(), to: timebase).seconds
            firsts.append((frame.number, frame.host, item, frame.white))
        }
        let stamped = stamps.withLock { $0 }
        // Past the start, and short of where the capture stopped.
        let steady = firsts.filter { $0.number >= 12 && $0.number <= 4 * 24 && stamped[$0.number] != nil }
        try #require(steady.count > 48, "captured \(firsts.count) pictures, \(steady.count) in the steady part")

        let skipped = zip(steady, steady.dropFirst()).filter { $0.1.number != $0.0.number + 1 }
            .map { "on screen \($0.0.number) then \($0.1.number)" }
        #expect(skipped.isEmpty, "\(skipped.count) breaks in the order on screen: \(skipped.prefix(10))")
        // The capture's own timing, for reading only.
        let delays = steady.map { ($0.item - stamped[$0.number]!) * 1000 }.sorted()
        print(String(format: "[OverlayScreenTiming] first captured after its time: %.1f / %.1f / %.1f ms (min / median / max)",
                     delays.first ?? 0, delays[delays.count / 2], delays.last ?? 0))
        if let white = firsts.first(where: \.white) {
            print(String(format: "[OverlayScreenTiming] the white picture (%d) first captured at item time %.4f s", white.number, white.item))
        }
    }
}
#endif
