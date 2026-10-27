import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

/// docs/startup-determinism.md: the rules a load's start is built from, each decided before the step that needs it.
struct StartupPlanTests {

    // MARK: - The master-or-media answer, before the switch

    @Test("An eligible, unlatched display the load may attempt is planned to the master")
    func eligibleAttemptPlansMaster() {
        #expect(AetherEngine.plannedPanelRouting(
            hostAsserts: false, provenForWrite: false, attemptWhenUnproven: true, displayEligibleForHDR: true,
            panelRefusedHDRMaster: false, switchRequested: false) == .decided(routesAsHDR: true, waitsForSwitchEnd: false))
    }

    @Test("A proof or the host's assertion plans the master without the attempt")
    func proofOrAssertionPlansMaster() {
        #expect(AetherEngine.plannedPanelRouting(
            hostAsserts: false, provenForWrite: true, attemptWhenUnproven: false, displayEligibleForHDR: true,
            panelRefusedHDRMaster: false, switchRequested: true) == .decided(routesAsHDR: true, waitsForSwitchEnd: false))
        #expect(AetherEngine.plannedPanelRouting(
            hostAsserts: true, provenForWrite: false, attemptWhenUnproven: false, displayEligibleForHDR: true,
            panelRefusedHDRMaster: false, switchRequested: true) == .decided(routesAsHDR: true, waitsForSwitchEnd: false))
    }

    @Test("An ineligible display or a latched refusal is planned media-direct")
    func ineligibleOrLatchedPlansMedia() {
        #expect(AetherEngine.plannedPanelRouting(
            hostAsserts: false, provenForWrite: false, attemptWhenUnproven: true, displayEligibleForHDR: false,
            panelRefusedHDRMaster: false, switchRequested: true) == .decided(routesAsHDR: false, waitsForSwitchEnd: false))
        #expect(AetherEngine.plannedPanelRouting(
            hostAsserts: false, provenForWrite: false, attemptWhenUnproven: true, displayEligibleForHDR: true,
            panelRefusedHDRMaster: true, switchRequested: true) == .decided(routesAsHDR: false, waitsForSwitchEnd: false))
    }

    @Test("Without the attempt, a proof or an assertion, only the settled panel answers")
    func unprovenWithoutAttemptWaitsForThePanel() {
        #expect(AetherEngine.plannedPanelRouting(
            hostAsserts: false, provenForWrite: false, attemptWhenUnproven: false, displayEligibleForHDR: true,
            panelRefusedHDRMaster: false, switchRequested: true) == .atSettledPanel)
    }

    @Test("A decided plan agrees with the settled route wherever the readout cannot change it")
    func planAgreesWithSettledRoute() {
        for eligible in [false, true] {
            for latched in [false, true] {
                for attempt in [false, true] {
                    for asserts in [false, true] {
                        let plan = AetherEngine.plannedPanelRouting(
                            hostAsserts: asserts, provenForWrite: false, attemptWhenUnproven: attempt,
                            displayEligibleForHDR: eligible, panelRefusedHDRMaster: latched, switchRequested: false)
                        guard case .decided(let routes, _) = plan else { continue }
                        // An ineligible display has no HDR readout to give; elsewhere the readout reads false.
                        let settled = AetherEngine.sessionRoutesAsHDRPanel(
                            panelPresentsHDR: asserts, attemptWhenUnproven: attempt,
                            displayEligibleForHDR: eligible, panelRefusedHDRMaster: latched)
                        #expect(routes == settled)
                    }
                }
            }
        }
    }

    // MARK: - The start

    @Test("An autostarting VOD load starts prerolled; live, a paused mount and the AirPlay gate do not")
    func prerolledStartScope() {
        #expect(AetherEngine.loadStartsPrerolled(autostart: true, isLive: false, readinessGateRuns: false))
        #expect(!AetherEngine.loadStartsPrerolled(autostart: false, isLive: false, readinessGateRuns: false))
        #expect(!AetherEngine.loadStartsPrerolled(autostart: true, isLive: true, readinessGateRuns: false))
        #expect(!AetherEngine.loadStartsPrerolled(autostart: true, isLive: false, readinessGateRuns: true))
    }

    @Test("Apple's prerolled start places the clock 10 ms ahead")
    func prerolledStartLead() {
        #expect(NativeAVPlayerHost.prerolledStartLeadSeconds == 0.01)
    }

    @Test("A pause observed before the start reaches the host after it plays: nothing is started again")
    func stalePauseAfterPrerolledStart() {
        // The Apple TV's sequence: .paused read just before the start, delivered once the player is .playing.
        #expect(NativeAVPlayerHost.afterPrerolledStart(observed: .paused, current: .playing, playIntent: true) == .restore)
        #expect(NativeAVPlayerHost.afterPrerolledStart(observed: .playing, current: .playing, playIntent: true) == .restore)
    }

    @Test("A start the player stalled out of is played again; one still waiting for its time is left to start")
    func stalledPrerolledStart() {
        #expect(NativeAVPlayerHost.afterPrerolledStart(observed: .paused, current: .paused, playIntent: true) == .restoreAndPlay)
        #expect(NativeAVPlayerHost.afterPrerolledStart(observed: .paused, current: .paused, playIntent: false) == .restore)
        #expect(NativeAVPlayerHost.afterPrerolledStart(observed: .waitingToPlayAtSpecifiedRate, current: .playing,
                                                       playIntent: true) == .wait)
        #expect(NativeAVPlayerHost.afterPrerolledStart(observed: .paused, current: .waitingToPlayAtSpecifiedRate,
                                                       playIntent: true) == .wait)
    }

    // MARK: - The Atmos activator beside an AVPlayer

    @Test("Starting up, the stream plays over a paused host and across the item swap")
    func activatorHoldsThroughStartup() {
        #expect(AtmosOutputActivator.hostVerdict(itemPlaysAPAC: true, hostPaused: true, startingUp: true) == true)
        #expect(AtmosOutputActivator.hostVerdict(itemPlaysAPAC: nil, hostPaused: true, startingUp: true) == true)
    }

    @Test("Once started, the stream follows the host")
    func activatorFollowsHostAfterStartup() {
        #expect(AtmosOutputActivator.hostVerdict(itemPlaysAPAC: true, hostPaused: true, startingUp: false) == false)
        #expect(AtmosOutputActivator.hostVerdict(itemPlaysAPAC: true, hostPaused: false, startingUp: false) == true)
        #expect(AtmosOutputActivator.hostVerdict(itemPlaysAPAC: nil, hostPaused: false, startingUp: false) == nil)
    }

    @Test("An item that plays no APAC releases the stream, starting up or not")
    func activatorReleasesForNonAPAC() {
        #expect(AtmosOutputActivator.hostVerdict(itemPlaysAPAC: false, hostPaused: true, startingUp: true) == nil)
        #expect(AtmosOutputActivator.hostVerdict(itemPlaysAPAC: false, hostPaused: false, startingUp: false) == nil)
    }

    // MARK: - The stored panel proof

    @Test("A stored proof stands only under the configuration it was earned in")
    func proofStandsUnderItsConfiguration() {
        let earned = PanelProof.Configuration(matchingEnabled: true, eligibleForHDR: true)
        #expect(PanelProof.stands(stored: earned, current: earned))
        #expect(!PanelProof.stands(stored: earned, current: .init(matchingEnabled: false, eligibleForHDR: true)))
        #expect(!PanelProof.stands(stored: earned, current: .init(matchingEnabled: true, eligibleForHDR: false)))
        #expect(!PanelProof.stands(stored: nil, current: earned))
    }

    @Test("A memory store keeps what is saved and forgets it on nil")
    func memoryStoreRoundTrip() {
        let store = PanelProof.Store.memory()
        #expect(store.load() == nil)
        let earned = PanelProof.Configuration(matchingEnabled: true, eligibleForHDR: true)
        store.save(earned)
        #expect(store.load() == earned)
        store.save(nil)
        #expect(store.load() == nil)
    }

    @MainActor
    @Test("Forgetting the proof clears the store")
    func forgettingClearsTheStore() {
        let store = PanelProof.Store.memory()
        store.save(.init(matchingEnabled: true, eligibleForHDR: true))
        let controller = DisplayCriteriaController(proofStore: store)
        controller.forgetPanelProof(reason: "test")
        #expect(store.load() == nil)
        #expect(!controller.panelIsProvenToEngageHDR())
    }
}
