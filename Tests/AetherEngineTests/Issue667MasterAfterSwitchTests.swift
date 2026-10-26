import Foundation
import Testing
@testable import AetherEngine

/// AE#667: an unproven HDR master served while the display mode switch is still running is refused for the
/// mode the panel is leaving, and that refusal was latched as a fact about the panel.
///
/// Measured by the reporter on an Apple TV 4K (3rd gen, tvOS 27.0, HDR10 panel, Match Content on): the
/// pre-flight released at its 2 s cap, the master was served 140 ms later, AVPlayer failed it with `-11868`
/// after 80 ms, and the switch ended 660 ms after the refusal. Every HDR title on that box lost its master.
struct Issue667MasterAfterSwitchTests {

    @Test("An unproven master waits while a switch it saw start is still running")
    func unprovenMasterWaitsForRunningSwitch() {
        #expect(AetherEngine.unprovenMasterAwaitsSwitchEnd(
            routesAsHDR: true, panelPresentsHDR: false, switchRunning: true))
    }

    @Test("No running switch, no wait: the #348 overlap stays where nothing is pending")
    func noRunningSwitchNoWait() {
        #expect(!AetherEngine.unprovenMasterAwaitsSwitchEnd(
            routesAsHDR: true, panelPresentsHDR: false, switchRunning: false))
    }

    @Test("A proven panel already answered, so its master does not wait")
    func provenPanelDoesNotWait() {
        #expect(!AetherEngine.unprovenMasterAwaitsSwitchEnd(
            routesAsHDR: true, panelPresentsHDR: true, switchRunning: true))
    }

    @Test("A media route has no acceptance to wait for")
    func mediaRouteDoesNotWait() {
        #expect(!AetherEngine.unprovenMasterAwaitsSwitchEnd(
            routesAsHDR: false, panelPresentsHDR: false, switchRunning: true))
    }

    @Test("A refusal raised mid-switch does not latch, even on an eligible display")
    func midSwitchRefusalDoesNotLatch() {
        #expect(!MasterFallbackDecision.shouldLatchPanelRefusal(
            code: -11868, servedMasterIsHDR: true, displayEligibleForHDRNow: true, displaySwitchInProgress: true))
        #expect(!MasterFallbackDecision.shouldLatchPanelRefusal(
            code: -11848, servedMasterIsHDR: true, displayEligibleForHDRNow: true, displaySwitchInProgress: true))
    }

    @Test("A refusal after the switch settled still latches")
    func settledRefusalStillLatches() {
        #expect(MasterFallbackDecision.shouldLatchPanelRefusal(
            code: -11868, servedMasterIsHDR: true, displayEligibleForHDRNow: true, displaySwitchInProgress: false))
    }

    /// A policy test cannot see the call site, so this one reads it: the plan decides the route before the
    /// session is built, and an unproven master's wait for the switch's end sits in the routing the session
    /// awaits between `prepare()` and `serve`.
    @Test("The load plans the route, and an unproven master is served after the switch ends")
    func loadSitePlansThenWaitsBeforeServing() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine/AetherEngine.swift")
        let text = try #require(try? String(contentsOf: source, encoding: .utf8))
        let plan = try #require(text.range(of: "Self.plannedPanelRouting("))
        let after = text[plan.upperBound...]
        let wait = try #require(after.range(of: "waitForSwitch(consumesRecord: false, settleCap: .awaitObservedEnd"))
        let serve = try #require(after.range(of: "resolvePanelRouting: resolvePanelRouting"))
        #expect(wait.lowerBound < serve.lowerBound)
    }

    @Test("The plan waits for the switch only for an unproven master")
    func planWaitsOnlyForUnprovenMaster() {
        #expect(AetherEngine.plannedPanelRouting(
            hostAsserts: false, provenForWrite: false, attemptWhenUnproven: true, displayEligibleForHDR: true,
            panelRefusedHDRMaster: false, switchRequested: true) == .decided(routesAsHDR: true, waitsForSwitchEnd: true))
        #expect(AetherEngine.plannedPanelRouting(
            hostAsserts: false, provenForWrite: true, attemptWhenUnproven: true, displayEligibleForHDR: true,
            panelRefusedHDRMaster: false, switchRequested: true) == .decided(routesAsHDR: true, waitsForSwitchEnd: false))
    }
}
