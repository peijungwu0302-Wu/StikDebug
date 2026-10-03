import Combine
import Foundation

enum TutorialFlow: String, CaseIterable, Identifiable {
    case firstPoint, firstRoute, restore, coordinates, favorite, savedRoute, interruption, cellular
    var id: String { rawValue }
    var titleKey: String { "tutorial.flow.\(rawValue)" }
}

enum TutorialTarget: String, CaseIterable {
    case coordinateEntry, simulate, routeMode, routeEditor, routeEditorConfirm, startRoute
    case pauseRoute, resumeRoute, stopAndHold, restore, favorite, myTab, favoriteLibrary
    case saveRoute, routeLibrary, openSavedRoute, recovery, cellularSettings
}

enum TutorialPlaybackState: Equatable {
    case idle, running, paused, reconnecting, stopped, completed, error
}

/// Values are observed from production state. This contains no credentials, logs,
/// private names, or storage contents. Success revisions are emitted by successful
/// production operations, never by a UI button tap.
struct GuidedTutorialSnapshot: Equatable {
    var selectedCoordinate: RouteCoordinate?
    var activeCoordinate: RouteCoordinate?
    var simulationIdle = true
    var playback: TutorialPlaybackState = .idle
    var waypointCount = 0
    var favoriteIDs: Set<UUID> = []
    var routeIDs: Set<UUID> = []
    var mapFocusRevision: UUID?
    var simulationSuccessRevision: UUID?
    var restoreSuccessRevision: UUID?
    var selectedFavoriteID: UUID?
    var previewRouteID: UUID?
    var loadedRouteID: UUID?
    var tab = "map"
    var editorVisible = false
    var coordinateEntryVisible = false
    var quickRouteIsRoute = false
    var productionError = false
    var recoveryAlert = false
    var connectionPreparing = false
    var connectionReady = false
}

enum TutorialStepID: String {
    case enterCoordinate, selectCoordinate, simulate, buildRoute, editRoute, confirmRoute
    case startRoute, pauseRoute, resumeRoute, stopAndHold, restore, saveFavorite
    case openMy, reopenFavorite, saveRoute, reopenRoute, inspectInterruption
    case recoverConnection, inspectCellular, awaitCellularSuccess
}

struct TutorialStep: Equatable {
    let id: TutorialStepID
    let target: TutorialTarget
    var titleKey: String { "tutorial.step.\(id.rawValue).title" }
    var instructionKey: String { "tutorial.step.\(id.rawValue).body" }
}

/// An observer only: navigation and actual user actions stay in existing views.
/// It has no references to simulation, persistence, settings, or network services.
@MainActor
final class GuidedTutorialCoordinator: ObservableObject {
    @Published private(set) var flow: TutorialFlow?
    @Published private(set) var stepIndex = 0
    @Published private(set) var completedFlow: TutorialFlow?
    @Published private(set) var isSuspended = false
    private var baseline = GuidedTutorialSnapshot()
    private var selectedTarget: RouteCoordinate?
    private var createdFavoriteID: UUID?
    private var createdRouteID: UUID?

    var isActive: Bool { flow != nil }
    var steps: [TutorialStep] { flow.map(Self.steps(for:)) ?? [] }
    var step: TutorialStep? { steps.indices.contains(stepIndex) ? steps[stepIndex] : nil }

    static func steps(for flow: TutorialFlow) -> [TutorialStep] {
        func s(_ id: TutorialStepID, _ target: TutorialTarget) -> TutorialStep {
            TutorialStep(id: id, target: target)
        }
        switch flow {
        case .firstPoint, .coordinates:
            return [s(.enterCoordinate, .coordinateEntry), s(.selectCoordinate, .coordinateEntry), s(.simulate, .simulate)]
        case .firstRoute:
            return [s(.buildRoute, .routeMode), s(.editRoute, .routeEditor), s(.confirmRoute, .routeEditorConfirm),
                    s(.startRoute, .startRoute), s(.pauseRoute, .pauseRoute), s(.resumeRoute, .resumeRoute), s(.stopAndHold, .stopAndHold)]
        case .restore:
            return [s(.restore, .restore)]
        case .favorite:
            return [s(.enterCoordinate, .coordinateEntry), s(.selectCoordinate, .coordinateEntry),
                    s(.saveFavorite, .favorite), s(.openMy, .myTab), s(.reopenFavorite, .favoriteLibrary)]
        case .savedRoute:
            return [s(.buildRoute, .routeMode), s(.saveRoute, .saveRoute), s(.openMy, .myTab),
                    s(.reopenRoute, .routeLibrary), s(.startRoute, .startRoute)]
        case .interruption:
            return [s(.inspectInterruption, .recovery), s(.recoverConnection, .recovery)]
        case .cellular:
            return [s(.inspectCellular, .cellularSettings), s(.awaitCellularSuccess, .recovery)]
        }
    }

    func start(_ flow: TutorialFlow, snapshot: GuidedTutorialSnapshot) {
        clear()
        completedFlow = nil
        self.flow = flow
        baseline = snapshot
    }

    func skip() { clear(); completedFlow = nil }
    func interrupt() { skip() }
    func targetUnavailable() { interrupt() }
    func suspend() { if isActive { isSuspended = true } }
    func resume(snapshot: GuidedTutorialSnapshot) {
        guard isActive else { return }
        isSuspended = false
        observe(snapshot)
    }

    func observe(_ snapshot: GuidedTutorialSnapshot) {
        guard !isSuspended, let flow, let step else { return }
        // Production alerts keep ownership of interaction. Recovery lessons may
        // observe them; other lessons exit immediately without altering the app.
        if (snapshot.productionError || snapshot.recoveryAlert), flow != .interruption, flow != .cellular {
            interrupt()
            return
        }
        if step.id == .simulate, let coordinate = snapshot.selectedCoordinate,
           coordinate.isValid, coordinate != selectedTarget {
            // Follow the user's current selection. An older request finishing
            // after a newer selection cannot complete the newer lesson target.
            selectedTarget = coordinate
        }
        let priorSuccessRevision = baseline.simulationSuccessRevision
        let priorPlayback = baseline.playback
        guard satisfies(step.id, snapshot) else { return }
        if step.id == .selectCoordinate, (flow == .firstPoint || flow == .coordinates),
           !snapshot.simulationIdle, snapshot.activeCoordinate == selectedTarget,
           snapshot.simulationSuccessRevision != nil, snapshot.simulationSuccessRevision != priorSuccessRevision {
            // The coordinate modal's real Simulate action can both select and
            // successfully simulate. Do not require repeating that operation.
            clear()
            completedFlow = flow
            return
        }
        baseline = snapshot
        if stepIndex + 1 == steps.count {
            clear()
            completedFlow = flow
        } else {
            stepIndex += 1
            // A library's real Start action may load and start together. The
            // same successful running transition proves both operations, even
            // when SwiftUI delivers them in one snapshot.
            if self.step?.id == .startRoute, snapshot.playback == .running, priorPlayback != .running,
               createdRouteID == nil || snapshot.loadedRouteID == createdRouteID {
                if stepIndex + 1 == steps.count {
                    clear()
                    completedFlow = flow
                } else {
                    stepIndex += 1
                }
            }
        }
    }

    private func satisfies(_ step: TutorialStepID, _ state: GuidedTutorialSnapshot) -> Bool {
        switch step {
        case .enterCoordinate:
            return state.coordinateEntryVisible && !baseline.coordinateEntryVisible
        case .selectCoordinate:
            guard !state.coordinateEntryVisible, let coordinate = state.selectedCoordinate, coordinate.isValid else { return false }
            // Entry must resolve into an actual map selection, not merely close.
            guard coordinate != baseline.selectedCoordinate || state.mapFocusRevision != baseline.mapFocusRevision else { return false }
            selectedTarget = coordinate
            return true
        case .simulate:
            return !state.simulationIdle && state.activeCoordinate == selectedTarget &&
                state.simulationSuccessRevision != nil && state.simulationSuccessRevision != baseline.simulationSuccessRevision
        case .buildRoute:
            return state.quickRouteIsRoute && state.waypointCount >= 2
        case .editRoute: return state.editorVisible && !baseline.editorVisible
        case .confirmRoute: return !state.editorVisible && baseline.editorVisible && state.waypointCount >= 2
        case .startRoute:
            let correctRoute = createdRouteID == nil || state.loadedRouteID == createdRouteID
            return correctRoute && state.playback == .running && baseline.playback != .running
        case .pauseRoute: return state.playback == .paused && baseline.playback == .running
        case .resumeRoute: return state.playback == .running && baseline.playback == .paused
        case .stopAndHold:
            return state.playback == .stopped && !state.simulationIdle && state.activeCoordinate != nil
        case .restore:
            return state.simulationIdle && state.activeCoordinate == nil && state.restoreSuccessRevision != nil &&
                state.restoreSuccessRevision != baseline.restoreSuccessRevision
        case .saveFavorite:
            let additions = state.favoriteIDs.subtracting(baseline.favoriteIDs)
            guard additions.count == 1, let id = additions.first else { return false }
            createdFavoriteID = id
            return true
        case .openMy: return state.tab == "my" && baseline.tab != "my"
        case .reopenFavorite:
            guard let id = createdFavoriteID else { return false }
            return state.tab == "map" && state.selectedFavoriteID == id &&
                state.favoriteIDs.contains(id) && state.mapFocusRevision != baseline.mapFocusRevision
        case .saveRoute:
            let additions = state.routeIDs.subtracting(baseline.routeIDs)
            guard additions.count == 1, let id = additions.first else { return false }
            createdRouteID = id
            return true
        case .reopenRoute:
            guard let id = createdRouteID else { return false }
            return state.routeIDs.contains(id) &&
                ((state.previewRouteID == id && baseline.previewRouteID != id) ||
                 (state.loadedRouteID == id && baseline.loadedRouteID != id))
        case .inspectInterruption:
            return state.productionError || state.recoveryAlert || state.playback == .reconnecting || state.playback == .error
        case .recoverConnection:
            let successfulRouteRecovery = state.playback == .running &&
                [.error, .reconnecting, .paused].contains(baseline.playback)
            let successfulPointRecovery = state.simulationSuccessRevision != nil &&
                state.simulationSuccessRevision != baseline.simulationSuccessRevision
            return state.connectionReady && !state.connectionPreparing && !state.productionError && !state.recoveryAlert &&
                !state.simulationIdle && (successfulRouteRecovery || successfulPointRecovery)
        case .inspectCellular: return state.connectionPreparing && !baseline.connectionPreparing
        case .awaitCellularSuccess:
            let successfulRouteRecovery = state.playback == .running && baseline.playback != .running
            let successfulPointRecovery = state.simulationSuccessRevision != nil &&
                state.simulationSuccessRevision != baseline.simulationSuccessRevision
            return state.connectionReady && !state.connectionPreparing && !state.productionError &&
                !state.recoveryAlert && !state.simulationIdle && (successfulRouteRecovery || successfulPointRecovery)
        }
    }

    private func clear() {
        flow = nil
        isSuspended = false
        stepIndex = 0
        selectedTarget = nil
        createdFavoriteID = nil
        createdRouteID = nil
        baseline = GuidedTutorialSnapshot()
    }
}
