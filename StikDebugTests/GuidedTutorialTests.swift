import Foundation
import Testing
@testable import RouteLocation

@MainActor
struct GuidedTutorialTests {
    private let demo = RouteCoordinate(latitude: 25.033964, longitude: 121.564468)

    @Test func libraryTargetsFollowTheVisibleProductionSection() {
        let tutorial = GuidedTutorialCoordinator()
        for flow in [TutorialFlow.savedRoute, .favorite] {
            let (initial, states) = scenario(flow)
            tutorial.start(flow, snapshot: initial)
            for state in states.dropLast(flow == .savedRoute ? 2 : 1) { tutorial.observe(state) }
            #expect(tutorial.currentTarget(librarySection: "other") == .routeLibrary)
            if flow == .savedRoute {
                #expect(tutorial.currentTarget(librarySection: "routes") == .openSavedRoute)
                #expect(tutorial.highlightedRouteID != nil)
            } else {
                #expect(tutorial.currentTarget(librarySection: "places") == .favoriteLibrary)
                #expect(tutorial.highlightedFavoriteID != nil)
            }
            tutorial.skip()
        }
    }

    @Test func everyTutorialInstructionHasBothLocalizations() throws {
        var keys = TutorialFlow.allCases.map(\.titleKey)
        keys += TutorialFlow.allCases.flatMap { flow in
            GuidedTutorialCoordinator.steps(for: flow).flatMap { [$0.titleKey, $0.instructionKey] }
        }
        keys += ["tutorial.center.title", "tutorial.center.intro", "tutorial.section.quick",
                 "tutorial.section.common", "tutorial.section.connection", "tutorial.coach.title",
                 "tutorial.skip", "tutorial.target.unavailable", "tutorial.progress",
                 "tutorial.completed", "tutorial.demo.coordinate"]
        for language in ["en", "zh-Hant"] {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for key in Set(keys) {
                let value = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
                #expect(value != "MISSING" && !value.isEmpty, "Missing \(language) tutorial translation: \(key)")
            }
        }
    }

    /// Each entry is a real observable state transition, not a synthetic button
    /// click. These scenarios also enumerate every step for the skip checks.
    private func scenario(_ flow: TutorialFlow) -> (GuidedTutorialSnapshot, [GuidedTutorialSnapshot]) {
        var state = GuidedTutorialSnapshot()
        if flow == .restore {
            state.activeCoordinate = demo
            state.simulationIdle = false
        }
        let initial = state
        var results: [GuidedTutorialSnapshot] = []
        func emit(_ update: (inout GuidedTutorialSnapshot) -> Void) {
            update(&state)
            results.append(state)
        }
        func select() {
            emit { $0.coordinateEntryVisible = true }
            emit {
                $0.coordinateEntryVisible = false
                $0.selectedCoordinate = demo
                $0.mapFocusRevision = UUID()
            }
        }
        switch flow {
        case .firstPoint, .coordinates:
            select()
            emit {
                $0.activeCoordinate = demo
                $0.simulationIdle = false
                $0.simulationSuccessRevision = UUID()
            }
        case .firstRoute:
            emit { $0.quickRouteIsRoute = true; $0.waypointCount = 2 }
            emit { $0.editorVisible = true }
            emit { $0.editorVisible = false }
            emit { $0.playback = .running; $0.simulationIdle = false; $0.activeCoordinate = demo }
            emit { $0.playback = .paused }
            emit { $0.playback = .running }
            emit { $0.playback = .stopped }
        case .restore:
            emit { $0.simulationIdle = true; $0.activeCoordinate = nil; $0.restoreSuccessRevision = UUID() }
        case .favorite:
            select()
            let id = UUID()
            emit { $0.favoriteIDs = [id] }
            emit { $0.tab = "my" }
            emit {
                $0.tab = "map"
                $0.selectedFavoriteID = id
                // Reopening a favorite focuses/selects it through the real
                // production model path, which emits a fresh selection
                // revision even when it is the same coordinate as before.
                $0.selectedPlaceRevision = UUID()
                $0.mapFocusRevision = UUID()
            }
        case .savedRoute:
            let id = UUID()
            emit { $0.quickRouteIsRoute = true; $0.waypointCount = 2 }
            emit { $0.routeIDs = [id] }
            emit { $0.tab = "my" }
            emit { $0.previewRouteID = id }
            emit { $0.loadedRouteID = id; $0.playback = .running }
        case .interruption:
            emit { $0.productionError = true; $0.playback = .error }
            emit {
                $0.productionError = false; $0.playback = .running; $0.connectionReady = true
                $0.simulationIdle = false; $0.activeCoordinate = demo; $0.simulationSuccessRevision = UUID()
            }
        case .cellular:
            emit { $0.connectionPreparing = true }
            emit {
                $0.connectionPreparing = false; $0.connectionReady = true; $0.simulationIdle = false
                $0.activeCoordinate = demo; $0.simulationSuccessRevision = UUID()
            }
        }
        return (initial, results)
    }

    @Test(arguments: TutorialFlow.allCases)
    func everyFlowCompletesOnlyAfterItsProductionTransitions(_ flow: TutorialFlow) {
        let (initial, states) = scenario(flow)
        let coordinator = GuidedTutorialCoordinator()
        coordinator.start(flow, snapshot: initial)
        #expect(coordinator.isActive)
        #expect(coordinator.steps.count == states.count)
        for (index, state) in states.enumerated() {
            #expect(coordinator.stepIndex == index)
            coordinator.observe(state)
        }
        #expect(!coordinator.isActive)
        #expect(coordinator.step == nil)
        #expect(coordinator.completedFlow == flow)
    }

    @Test(arguments: TutorialFlow.allCases)
    func everyStepCanSkipWithoutChangingProductionState(_ flow: TutorialFlow) {
        let (initial, states) = scenario(flow)
        for skipIndex in states.indices {
            let coordinator = GuidedTutorialCoordinator()
            coordinator.start(flow, snapshot: initial)
            for state in states.prefix(skipIndex) { coordinator.observe(state) }
            let productionBeforeSkip = skipIndex == 0 ? initial : states[skipIndex - 1]
            coordinator.skip()
            #expect(!coordinator.isActive)
            #expect(coordinator.completedFlow == nil)
            // Even subsequent successful production events cannot revive a
            // skipped lesson. There is no service dependency to call on skip.
            for state in states { coordinator.observe(state) }
            #expect(!coordinator.isActive)
            #expect(coordinator.completedFlow == nil)
            #expect(productionBeforeSkip == (skipIndex == 0 ? initial : states[skipIndex - 1]))
        }
    }

    @Test func selectionOrButtonPresentationCannotClaimSimulationSucceeded() {
        let coordinator = GuidedTutorialCoordinator()
        let (initial, states) = scenario(.firstPoint)
        coordinator.start(.firstPoint, snapshot: initial)
        coordinator.observe(states[0])
        coordinator.observe(states[1])
        var state = states[1]
        for _ in 0..<3 { coordinator.observe(state) }
        #expect(coordinator.step?.id == .simulate)
        state.activeCoordinate = demo
        state.simulationIdle = false
        coordinator.observe(state)
        #expect(coordinator.completedFlow == nil, "Active UI alone is not successful production evidence")
        state.simulationSuccessRevision = UUID()
        coordinator.observe(state)
        #expect(coordinator.completedFlow == .firstPoint)
    }

    @Test func cancellingCoordinateEntryDoesNotAcceptAnOldSelection() {
        let coordinator = GuidedTutorialCoordinator()
        var state = GuidedTutorialSnapshot()
        state.selectedCoordinate = demo
        coordinator.start(.coordinates, snapshot: state)
        state.coordinateEntryVisible = true
        coordinator.observe(state)
        state.coordinateEntryVisible = false
        coordinator.observe(state)
        #expect(coordinator.step?.id == .selectCoordinate)
        #expect(coordinator.completedFlow == nil)
    }

    @Test func pauseAndStopCannotStandInForRestoreSuccess() {
        let coordinator = GuidedTutorialCoordinator()
        var state = GuidedTutorialSnapshot()
        state.simulationIdle = false
        state.activeCoordinate = demo
        coordinator.start(.restore, snapshot: state)
        for playback in [TutorialPlaybackState.paused, .stopped, .completed] {
            state.playback = playback
            coordinator.observe(state)
            #expect(coordinator.completedFlow == nil)
        }
        state.simulationIdle = true
        state.activeCoordinate = nil
        coordinator.observe(state)
        #expect(coordinator.completedFlow == nil)
        state.restoreSuccessRevision = UUID()
        coordinator.observe(state)
        #expect(coordinator.completedFlow == .restore)
    }

    @Test func oldSuccessRevisionDoesNotCompleteANewLesson() {
        let coordinator = GuidedTutorialCoordinator()
        var state = GuidedTutorialSnapshot()
        state.restoreSuccessRevision = UUID()
        coordinator.start(.restore, snapshot: state)
        coordinator.observe(state)
        #expect(coordinator.completedFlow == nil)
    }

    @Test(arguments: TutorialFlow.allCases)
    func missingTargetOrBackgroundSafelyEndsAnyFlow(_ flow: TutorialFlow) {
        let coordinator = GuidedTutorialCoordinator()
        coordinator.start(flow, snapshot: GuidedTutorialSnapshot())
        coordinator.targetUnavailable()
        #expect(!coordinator.isActive)
        #expect(coordinator.completedFlow == nil)
        coordinator.start(flow, snapshot: GuidedTutorialSnapshot())
        coordinator.interrupt()
        #expect(!coordinator.isActive)
        #expect(coordinator.completedFlow == nil)
    }

    @Test func productionAlertRetainsOwnershipDuringAnOrdinaryLesson() {
        let coordinator = GuidedTutorialCoordinator()
        var state = GuidedTutorialSnapshot()
        coordinator.start(.firstPoint, snapshot: state)
        state.recoveryAlert = true
        coordinator.observe(state)
        #expect(!coordinator.isActive)
        #expect(coordinator.completedFlow == nil)
    }

    @Test func recoveryRequiresMoreThanHealthyTransportEvidence() {
        let coordinator = GuidedTutorialCoordinator()
        var state = GuidedTutorialSnapshot()
        coordinator.start(.interruption, snapshot: state)
        state.playback = .error
        coordinator.observe(state)
        state.playback = .paused
        state.connectionReady = true
        coordinator.observe(state)
        #expect(coordinator.step?.id == .recoverConnection)
        #expect(coordinator.completedFlow == nil)
    }

    @Test func favoriteReopenRequiresThePersistedFavoriteIdentity() {
        let coordinator = GuidedTutorialCoordinator()
        let (initial, states) = scenario(.favorite)
        coordinator.start(.favorite, snapshot: initial)
        for state in states.prefix(4) { coordinator.observe(state) }
        var wrong = states[4]
        wrong.selectedFavoriteID = UUID()
        coordinator.observe(wrong)
        #expect(coordinator.completedFlow == nil)
        coordinator.observe(states[4])
        #expect(coordinator.completedFlow == .favorite)
    }

    @Test func duplicateExistingFavoriteDoesNotCountAsNewPersistenceSuccess() {
        let coordinator = GuidedTutorialCoordinator()
        let (initial, states) = scenario(.favorite)
        coordinator.start(.favorite, snapshot: initial)
        coordinator.observe(states[0])
        coordinator.observe(states[1])
        coordinator.observe(states[1])
        #expect(coordinator.step?.id == .saveFavorite)
    }

    @Test func suspendedCellularRoundTripOnlyCompletesFromActualForegroundSuccess() {
        let coordinator = GuidedTutorialCoordinator()
        let (initial, states) = scenario(.cellular)
        coordinator.start(.cellular, snapshot: initial)
        coordinator.observe(states[0])
        coordinator.suspend()
        coordinator.observe(states[1])
        #expect(coordinator.isSuspended)
        #expect(coordinator.completedFlow == nil)
        coordinator.resume(snapshot: states[0])
        #expect(!coordinator.isSuspended)
        #expect(coordinator.completedFlow == nil)
        coordinator.suspend()
        coordinator.resume(snapshot: states[1])
        #expect(coordinator.completedFlow == .cellular)
    }

    @Test func skippingSuspendedLessonCannotReviveOnForegroundReturn() {
        let coordinator = GuidedTutorialCoordinator()
        let (initial, states) = scenario(.cellular)
        coordinator.start(.cellular, snapshot: initial)
        coordinator.observe(states[0])
        coordinator.suspend()
        coordinator.skip()
        coordinator.resume(snapshot: states[1])
        #expect(!coordinator.isActive)
        #expect(!coordinator.isSuspended)
        #expect(coordinator.completedFlow == nil)
    }

    @Test func reopeningJustSavedLoadedRouteUsesPreviewTransition() {
        let coordinator = GuidedTutorialCoordinator()
        let (initial, original) = scenario(.savedRoute)
        var states = original
        let savedID = states[1].routeIDs.first
        states[1].loadedRouteID = savedID
        states[2].loadedRouteID = savedID
        states[3].loadedRouteID = savedID
        coordinator.start(.savedRoute, snapshot: initial)
        for state in states { coordinator.observe(state) }
        #expect(coordinator.completedFlow == .savedRoute)
    }

    @Test func resumedProductionRouteProvesRecoveryWithoutSinglePointEvent() {
        let coordinator = GuidedTutorialCoordinator()
        var state = GuidedTutorialSnapshot()
        coordinator.start(.interruption, snapshot: state)
        state.playback = .error
        coordinator.observe(state)
        state.playback = .running
        state.connectionReady = true
        state.simulationIdle = false
        state.activeCoordinate = demo
        coordinator.observe(state)
        #expect(coordinator.completedFlow == .interruption)
    }

    @Test func cellularRouteRequiresActualRunningTransitionAfterPreparing() {
        let coordinator = GuidedTutorialCoordinator()
        var state = GuidedTutorialSnapshot()
        coordinator.start(.cellular, snapshot: state)
        state.connectionPreparing = true
        state.playback = .reconnecting
        coordinator.observe(state)
        state.connectionPreparing = false
        state.connectionReady = true
        state.simulationIdle = false
        coordinator.observe(state)
        #expect(coordinator.completedFlow == nil)
        state.playback = .running
        coordinator.observe(state)
        #expect(coordinator.completedFlow == .cellular)
    }

    @Test func selectingAnotherPointRejectsAnOlderTargetSuccess() {
        let coordinator = GuidedTutorialCoordinator()
        let (initial, states) = scenario(.firstPoint)
        coordinator.start(.firstPoint, snapshot: initial)
        coordinator.observe(states[0])
        coordinator.observe(states[1])
        let other = RouteCoordinate(latitude: 25.04, longitude: 121.57)
        var state = states[1]
        state.selectedCoordinate = other
        state.mapFocusRevision = UUID()
        coordinator.observe(state)
        state.activeCoordinate = demo
        state.simulationIdle = false
        state.simulationSuccessRevision = UUID()
        coordinator.observe(state)
        #expect(coordinator.completedFlow == nil)
        state.activeCoordinate = other
        state.simulationSuccessRevision = UUID()
        coordinator.observe(state)
        #expect(coordinator.completedFlow == .firstPoint)
    }

    @Test func coordinateModalMayCompleteThroughItsRealSimulateAction() {
        let coordinator = GuidedTutorialCoordinator()
        let (initial, states) = scenario(.coordinates)
        coordinator.start(.coordinates, snapshot: initial)
        coordinator.observe(states[0])
        coordinator.observe(states[2])
        #expect(coordinator.completedFlow == .coordinates)
    }

    @Test func unrelatedErrorDismissalDoesNotClaimRecoveryOfAlreadyRunningRoute() {
        let coordinator = GuidedTutorialCoordinator()
        var state = GuidedTutorialSnapshot()
        state.playback = .running
        state.simulationIdle = false
        state.activeCoordinate = demo
        state.connectionReady = true
        state.productionError = true
        coordinator.start(.interruption, snapshot: state)
        coordinator.observe(state)
        state.productionError = false
        coordinator.observe(state)
        #expect(coordinator.completedFlow == nil)
    }

    @Test func realLibraryStartMayLoadAndRunInOneProductionSnapshot() {
        let coordinator = GuidedTutorialCoordinator()
        let (initial, states) = scenario(.savedRoute)
        coordinator.start(.savedRoute, snapshot: initial)
        for state in states.prefix(3) { coordinator.observe(state) }
        coordinator.observe(states[4])
        #expect(coordinator.completedFlow == .savedRoute)
    }
}
