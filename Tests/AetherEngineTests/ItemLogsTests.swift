import Foundation
import AVFoundation
import Testing
@testable import AetherEngine

/// tvOS / macOS 27 read an item's logs through a completion-handler fetch; the readers must get an answer, not hang.
@Suite("Player item logs")
struct ItemLogsTests {

    private func item() -> AVPlayerItem {
        AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/item.m3u8"))
    }

    @Test("the blocking reads answer well inside their bound for an item with no logs yet")
    func blockingReadsAnswer() {
        let started = Date()
        _ = ItemLogs.access(of: item())
        _ = ItemLogs.errors(of: item())
        #expect(Date().timeIntervalSince(started) < 1.5, "both answered rather than waiting out the bound")
    }

    @Test("the async read answers, and an item with no error log has no codes", .timeLimit(.minutes(1)))
    func asyncReadAnswers() async {
        let codes = await ItemLogs.errorStatusCodes(of: item())
        #expect(codes.isEmpty)
    }
}
