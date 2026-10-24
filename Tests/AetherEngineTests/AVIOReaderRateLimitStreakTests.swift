import Testing
import Foundation
@testable import AetherEngine

/// Issue #71: under a sustained 429, parse-driven seekReconnect kept resetting unproductiveReconnects
/// so the give-up cap was never reached (infinite gen climb). A separate rate-limit streak that
/// survives seekReconnect must give up cleanly after a bounded number of attempts.
struct AVIOReaderRateLimitStreakTests {

    @Test("recordRateLimitAndShouldGiveUp gives up only after the bounded cap")
    func boundedGiveUp() {
        let reader = AVIOReader(url: URL(string: "https://example.com/x.mp4")!)
        // rateLimitMaxStreak = 6: the first 6 attempts keep trying, the 7th gives up.
        for attempt in 1...6 {
            #expect(reader.recordRateLimitAndShouldGiveUp() == false, "attempt \(attempt) should keep trying")
        }
        #expect(reader.recordRateLimitAndShouldGiveUp() == true, "7th consecutive 429/503 must give up")
    }
}
