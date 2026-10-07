import Combine
import CoreLocation
import Foundation
import SwiftUI
import UIKit
import UserNotifications

enum PlaybackRecoveryPreference: String, CaseIterable, Identifiable {
    case ask
    case automatic

    var id: String { rawValue }
    var title: String { L10n.text(self == .ask ? "暫停並詢問" : "自動恢復定位") }
}

@MainActor
final class RouteLocationModel: ObservableObject {
    @Published private(set) var successfulRestoreRevision = UUID()
    @Published private(set) var successfulSinglePointRevision = UUID()
    @Published var selectedCoordinate: RouteCoordinate?
    @Published private(set) var selectedPlaceRevision = UUID()
    @Published private(set) var waypoints: [RouteCoordinate] = []
    @Published var routeName = L10n.text("新路線") {
        didSet {
            guard !restoreRouteConfigurationAfterRejectedEdit else { return }
            guard !isAnyRouteActive else { restoreRouteConfiguration(oldValue, setter: { self.routeName = $0 }); return }
        }
    }
    @Published var routeMode: RouteMode = .straight {
        didSet {
            guard !restoreRouteConfigurationAfterRejectedEdit else { return }
            guard !isAnyRouteActive else { restoreRouteConfiguration(oldValue, setter: { self.routeMode = $0 }); return }
            routeInputsChanged()
        }
    }
    @Published var navigationTransport: NavigationTransportMode = .automobile {
        didSet {
            guard !restoreRouteConfigurationAfterRejectedEdit else { return }
            guard !isAnyRouteActive else { restoreRouteConfiguration(oldValue, setter: { self.navigationTransport = $0 }); return }
            routeInputsChanged()
        }
    }
    @Published var isClosedLoop = true {
        didSet {
            guard !restoreRouteConfigurationAfterRejectedEdit else { return }
            guard !isAnyRouteActive else { restoreRouteConfiguration(oldValue, setter: { self.isClosedLoop = $0 }); return }
            if !isClosedLoop, playbackMode != .once { playbackMode = .once }
            routeInputsChanged()
        }
    }
    @Published var playbackMode: RoutePlaybackMode = .infiniteLoop {
        didSet {
            guard !restoreRouteConfigurationAfterRejectedEdit else { return }
            guard !isAnyRouteActive else { restoreRouteConfiguration(oldValue, setter: { self.playbackMode = $0 }); return }
            let normalized = playbackMode.normalized(isClosedLoop: isClosedLoop)
            if normalized != playbackMode { playbackMode = normalized }
        }
    }
    @Published var speedKmh: Double {
        didSet {
            let normalized = PlaybackSpeedPolicy.clamp(speedKmh)
            if normalized != speedKmh {
                speedKmh = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: Self.speedKey)
        }
    }
    @Published var mapInteractionStyle: MapInteractionStyle {
        didSet { UserDefaults.standard.set(mapInteractionStyle.rawValue, forKey: Self.mapStyleKey) }
    }
    @Published var modeSwitchConfirmation: ModeSwitchConfirmation {
        didSet { UserDefaults.standard.set(modeSwitchConfirmation.rawValue, forKey: Self.modeSwitchKey) }
    }
    @Published var quickRouteMode: QuickRouteInteractionMode = .singlePoint
    @Published private(set) var simulationMode: SimulationMode = .idle
    @Published var pendingSinglePointCoordinate: RouteCoordinate?
    @Published var showModeSwitchAlert = false
    @Published var showBootstrapPreflightSheet = false
    @Published var showPlaybackRecoveryConsent = false
    @Published var playbackRecoveryPreference: PlaybackRecoveryPreference {
        didSet { UserDefaults.standard.set(playbackRecoveryPreference.rawValue, forKey: Self.playbackRecoveryPreferenceKey) }
    }
    @Published private(set) var pendingBootstrapTargetCoordinate: RouteCoordinate?
    private(set) var locationAlreadyWrittenByBootstrap: RouteCoordinate?
    @Published var previewingRoute: SavedRoute?
    @Published var showActiveRouteSwitchAlert = false
    @Published var pendingSwitchRoute: SavedRoute?
    @Published var showEndRouteOptions = false
    private var pendingBootstrapAction: (@MainActor () -> Void)?
    private var playbackRecoveryContinuation: CheckedContinuation<Bool, Never>?
    @Published private(set) var geometry = RouteGeometry(coordinates: [])
    @Published private(set) var navigationGeometryNeedsRecalculation = false
    @Published private(set) var favorites: [FavoriteLocation] = []
    @Published private(set) var savedRoutes: [SavedRoute] = []
    @Published private(set) var recentLocations: [RecentLocation] = []
    @Published var librarySortOption: LibrarySortOption {
        didSet { UserDefaults.standard.set(librarySortOption.rawValue, forKey: Self.librarySortKey) }
    }
    @Published private(set) var manualFavoriteOrder: [UUID] = []
    @Published var showFavoriteTimestamps: Bool {
        didSet { UserDefaults.standard.set(showFavoriteTimestamps, forKey: Self.showFavoriteTimestampsKey) }
    }
    @Published private(set) var isResolvingNavigation = false
    @Published var presentedError: String?
    @Published var statusMessage: String?
    @Published private(set) var mapFocusRevision = UUID()

    let playback: RoutePlaybackEngine
    let connectionMonitor: ConnectionMonitor
    private let persistence: RoutePersistenceStore
    // Serialize candidate construction through publication across actor awaits.
    // A cancelled waiter still takes/releases its turn without performing work.
    private var persistenceMutationInProgress = false
    private var persistenceMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private let navigationResolver = NavigationRouteResolver()
    private let simulationService: any LocationSimulationSink
    private var teleportTask: Task<Void, Never>?
    private var restoreRouteConfigurationAfterRejectedEdit = false
    private var singlePointHoldGeneration = 0
    /// Each user retarget request owns a generation.  A delayed write or
    /// recovery from an older request may finish, but it must not commit a
    /// stale coordinate after a newer request has won.
    private var singlePointRetargetGeneration = 0
    private var loadedRouteID: UUID?
    private var cancellables: Set<AnyCancellable> = []
    private var persistenceLoadTask: Task<Void, Never>?
    #if DEBUG
    var testPlaybackAfterBootstrapCompletion: (@MainActor () -> Void)?
    var testPlaybackStartInvocationCount: Int = 0
    var testRetryDelayHandler: (@MainActor (TimeInterval) async throws -> Void)?
    var testBeforeRecoveredLibrariesPublish: (@MainActor () async -> Void)?
    var testPersistenceMutationQueued: (@MainActor () -> Void)?
    var testTeleportCompletion: (@MainActor () -> Void)?
    #endif
    private static let speedKey = "RouteLocation.lastSpeedKmh"
    private static let mapStyleKey = "RouteLocation.mapInteractionStyle"
    private static let modeSwitchKey = "RouteLocation.modeSwitchConfirmation"
    private static let librarySortKey = "RouteLocation.librarySortOption"
    private static let showFavoriteTimestampsKey = "RouteLocation.showFavoriteTimestamps"
    private static let playbackRecoveryPreferenceKey = "RouteLocation.playbackRecoveryPreference"
    private static let manualFavoriteOrderKey = "RouteLocation.manualFavoriteOrder"

    var hasLoadedRoute: Bool { loadedRouteID != nil }
    var favoriteRoutes: [SavedRoute] { savedRoutes.filter(\.isFavorite) }

    init(
        persistence: RoutePersistenceStore = RoutePersistenceStore(),
        simulationService: any LocationSimulationSink = DeviceLocationSimulationService(),
        connectionMonitor: ConnectionMonitor? = nil
    ) {
        let connectionMonitor = connectionMonitor ?? ConnectionMonitor.shared
        self.persistence = persistence
        self.simulationService = simulationService
        self.connectionMonitor = connectionMonitor
        let savedSpeed = UserDefaults.standard.double(forKey: Self.speedKey)
        speedKmh = PlaybackSpeedPolicy.clamp(savedSpeed > 0 ? savedSpeed : 18.6)

        if let savedStyleRaw = UserDefaults.standard.string(forKey: Self.mapStyleKey),
           let savedStyle = MapInteractionStyle(rawValue: savedStyleRaw) {
            mapInteractionStyle = savedStyle
        } else {
            mapInteractionStyle = .quickRoute
        }

        if let savedConfirmRaw = UserDefaults.standard.string(forKey: Self.modeSwitchKey),
           let savedConfirm = ModeSwitchConfirmation(rawValue: savedConfirmRaw) {
            modeSwitchConfirmation = savedConfirm
        } else {
            modeSwitchConfirmation = .askFirst
        }
        librarySortOption = LibrarySortOption(rawValue: UserDefaults.standard.string(forKey: Self.librarySortKey) ?? "newest") ?? .newest
        if let data = UserDefaults.standard.data(forKey: Self.manualFavoriteOrderKey),
           let values = try? JSONDecoder().decode([UUID].self, from: data) {
            manualFavoriteOrder = values
        }
        showFavoriteTimestamps = UserDefaults.standard.object(forKey: Self.showFavoriteTimestampsKey) as? Bool ?? true
        playbackRecoveryPreference = PlaybackRecoveryPreference(rawValue: UserDefaults.standard.string(forKey: Self.playbackRecoveryPreferenceKey) ?? "ask") ?? .ask

        playback = RoutePlaybackEngine(sink: simulationService, connectionMonitor: connectionMonitor)
        playback.assistedRecoveryAction = { [weak self] coordinate in
            guard let self else { return false }
            return await self.performAssistedPlaybackRecovery(coordinate: coordinate)
        }
        HealthStepSyncService.shared.attach(to: playback)

        playback.$state
            .sink { [weak self] state in
                guard let self else { return }
                self.syncPlaybackState(state)
            }
            .store(in: &cancellables)

        persistenceLoadTask = Task { [weak self] in
            await self?.loadPersistedData()
        }
    }

    private func performAssistedPlaybackRecovery(coordinate: RouteCoordinate?) async -> Bool {
        guard ShortcutBootstrapService.shared.isShortcutAssistedEnabled else { return false }
        let appIsActive = UIApplication.shared.applicationState == .active
        if playbackRecoveryPreference == .ask || !appIsActive {
            showPlaybackRecoveryConsent = true
            if !appIsActive { schedulePlaybackRecoveryNotification() }
            let approved = await withCheckedContinuation { continuation in
                playbackRecoveryContinuation = continuation
            }
            guard approved else { return false }
        }
        return await withCheckedContinuation { continuation in
            CellularAssistedBootstrapStateMachine.shared.startAssistedBootstrap(
                targetCoordinate: coordinate,
                reason: .playbackFailureRecovery
            ) { result in
                continuation.resume(returning: (try? result.get()) != nil)
            }
        }
    }

    private func performStalePreparedSessionRecovery(_ coordinate: RouteCoordinate) async throws -> BootstrapProceedDisposition {
        try await withCheckedThrowingContinuation { continuation in
            CellularAssistedBootstrapStateMachine.shared.startAssistedBootstrap(
                targetCoordinate: coordinate,
                reason: .stalePreparedSessionRecovery
            ) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func schedulePlaybackRecoveryNotification() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = L10n.text("RouteLocation 路線已暫停")
            content.body = L10n.text("需要重新建立定位連線。")
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "RouteLocation.playback-recovery",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    func approvePlaybackRecovery() {
        showPlaybackRecoveryConsent = false
        let continuation = playbackRecoveryContinuation
        playbackRecoveryContinuation = nil
        continuation?.resume(returning: true)
    }

    func declinePlaybackRecovery() {
        showPlaybackRecoveryConsent = false
        let continuation = playbackRecoveryContinuation
        playbackRecoveryContinuation = nil
        continuation?.resume(returning: false)
    }

    /// The single user-facing stop boundary for route playback. Resolving the
    /// consent continuation before stopping increments the playback engine's
    /// recovery generation, so no suspended recovery task can revive the
    /// route or overwrite the terminal stopped state later.
    func stopRoutePlayback(clearMarker: Bool = true) {
        declinePlaybackRecovery()
        pendingBootstrapAction = nil
        pendingBootstrapTargetCoordinate = nil
        showBootstrapPreflightSheet = false
        CellularAssistedBootstrapStateMachine.shared.cancel()
        playback.stop(clearMarker: clearMarker)
        showPlaybackRecoveryConsent = false
    }

    /// Ends a route and invalidates any suspended recovery continuation. The
    /// playback engine's generation guard makes this terminal even if a
    /// transport callback returns after the user has dismissed the route.
    func endPlaybackRecovery() {
        stopRoutePlayback()
    }

    var estimatedLapDuration: TimeInterval? {
        let metersPerSecond = PlaybackMath.metersPerSecond(kmh: speedKmh)
        guard geometry.totalDistance > 0, metersPerSecond > 0 else { return nil }
        return geometry.totalDistance / metersPerSecond
    }

    func select(_ coordinate: CLLocationCoordinate2D) {
        let value = RouteCoordinate(coordinate)
        guard value.isValid else { return }
        previewingRoute = nil
        selectedCoordinate = value
        selectedPlaceRevision = UUID()
    }

    /// Clears only the pending map selection. It deliberately does not stop a
    /// single-point simulation or restore the device's real location.
    func clearSelectedPlace() {
        selectedCoordinate = nil
    }

    func focusOnMap(_ coordinate: RouteCoordinate) {
        guard coordinate.isValid else { return }
        previewingRoute = nil
        selectedCoordinate = coordinate
        selectedPlaceRevision = UUID()
        mapFocusRevision = UUID()
    }

    func addSelectedWaypoint() {
        guard let selectedCoordinate else { return }
        if addWaypoint(selectedCoordinate) { self.selectedCoordinate = nil }
    }

    func addSelectedWaypointAndSwitchToRoute() {
        guard let selectedCoordinate else { return }
        if addWaypointAndSwitchToRoute(selectedCoordinate) { self.selectedCoordinate = nil }
    }

    @discardableResult
    func addWaypoint(_ coordinate: RouteCoordinate, notifyIfLocked: Bool = true) -> Bool {
        guard canMutateRouteDraft(notifyIfLocked: notifyIfLocked) else { return false }
        guard coordinate.isValid else { presentedError = RouteLocationError.insufficientWaypoints.localizedDescription; return false }
        // A saved-route preview is a separate, read-only snapshot. Explicitly
        // editing the draft dismisses it first, then mutates only the existing
        // draft rather than loading or replacing it with the previewed route.
        previewingRoute = nil
        if waypoints.last != coordinate {
            waypoints.append(coordinate)
            routeInputsChanged()
        }
        return true
    }

    @discardableResult
    func addWaypointAndSwitchToRoute(_ coordinate: RouteCoordinate) -> Bool {
        guard addWaypoint(coordinate, notifyIfLocked: true) else { return false }
        quickRouteMode = .route
        ToastManager.shared.show(L10n.text("已加入路線"), kind: .success)
        return true
    }

    @discardableResult
    func replaceWaypoints(_ coordinates: [RouteCoordinate]) -> Bool {
        guard canMutateRouteDraft(notifyIfLocked: true) else { return false }
        waypoints = coordinates.filter(\.isValid)
        routeInputsChanged()
        quickRouteMode = .route
        previewingRoute = nil
        statusMessage = L10n.text("已匯入路線預覽。")
        return true
    }

    @discardableResult
    func appendWaypoints(_ coordinates: [RouteCoordinate]) -> Bool {
        guard canMutateRouteDraft(notifyIfLocked: true) else { return false }
        let values = coordinates.filter(\.isValid)
        guard !values.isEmpty else { return false }
        for coordinate in values where waypoints.last != coordinate { waypoints.append(coordinate) }
        routeInputsChanged()
        quickRouteMode = .route
        previewingRoute = nil
        statusMessage = L10n.text("已附加航點並預覽路線。")
        return true
    }

    func removeWaypoints(at offsets: IndexSet) {
        guard canMutateRouteDraft(notifyIfLocked: true) else { return }
        waypoints.remove(atOffsets: offsets)
        routeInputsChanged()
    }

    func moveWaypoints(from offsets: IndexSet, to destination: Int) {
        guard canMutateRouteDraft(notifyIfLocked: true) else { return }
        waypoints.move(fromOffsets: offsets, toOffset: destination)
        routeInputsChanged()
    }

    func updateWaypoint(at index: Int, latitude: Double, longitude: Double) {
        guard canMutateRouteDraft(notifyIfLocked: true) else { return }
        guard waypoints.indices.contains(index) else { return }
        let updated = RouteCoordinate(latitude: latitude, longitude: longitude)
        guard updated.isValid else { presentedError = CoordinateImportError.invalidCoordinate(line: index + 1).localizedDescription; return }
        waypoints[index] = updated
        routeInputsChanged()
    }

    func clearWaypoints() {
        guard canMutateRouteDraft(notifyIfLocked: true) else { return }
        waypoints = []
        loadedRouteID = nil
        routeInputsChanged()
    }

    func undoLastWaypoint() {
        guard canMutateRouteDraft(notifyIfLocked: true) else { return }
        guard !waypoints.isEmpty else { return }
        waypoints.removeLast()
        routeInputsChanged()
    }

    func clearCurrentDraft() {
        guard canMutateRouteDraft(notifyIfLocked: true) else { return }
        waypoints = []
        loadedRouteID = nil
        routeName = L10n.text("新路線")
        geometry = RouteGeometry(coordinates: [])
        navigationGeometryNeedsRecalculation = false
        statusMessage = L10n.text("路線草稿已清除。")
    }

    func clearCurrentRoute() {
        guard canMutateRouteDraft(notifyIfLocked: true) else { return }
        navigationResolver.cancel()
        stopRoutePlayback(clearMarker: true)
        if simulationMode.isRouteSimulation {
            simulationMode = .idle
        }
        loadedRouteID = nil
        routeName = L10n.text("新路線")
        selectedCoordinate = nil
        waypoints = []
        routeMode = .straight
        navigationTransport = .automobile
        isClosedLoop = true
        playbackMode = .infiniteLoop
        geometry = RouteGeometry(coordinates: [])
        navigationGeometryNeedsRecalculation = false
        statusMessage = L10n.text("路線已清除。")
    }

    func recalculateNavigation() async {
        guard canMutateRouteDraft(notifyIfLocked: true) else { return }
        guard !isResolvingNavigation else { return }
        isResolvingNavigation = true
        defer { isResolvingNavigation = false }
        do {
            let resolved = try await navigationResolver.resolve(waypoints: waypoints, closedLoop: isClosedLoop, transport: navigationTransport)
            guard canMutateRouteDraft(notifyIfLocked: true) else { return }
            geometry = resolved
            navigationGeometryNeedsRecalculation = false
            statusMessage = L10n.text("導航路線已計算完成，可以儲存。")
        } catch is CancellationError {
            return
        } catch {
            presentedError = error.localizedDescription
        }
    }

    @discardableResult
    func saveCurrentRoute(named requestedName: String? = nil, asCopy: Bool = false) async -> Bool {
        guard canMutateRouteDraft(notifyIfLocked: true) else { return false }
        return await persistCurrentRoute(named: requestedName, asCopy: asCopy)
    }

    /// Imports a parsed coordinate list as a real SavedRoute without touching
    /// the current editable map draft. Persistence succeeds before the route
    /// is published or shown as a map preview.
    @discardableResult
    func importSavedRoute(_ coordinates: [RouteCoordinate], named requestedName: String? = nil) async -> SavedRoute? {
        guard canMutateRouteDraft(notifyIfLocked: true) else { return nil }
        await acquirePersistenceMutation()
        defer { releasePersistenceMutation() }
        await waitForInitialPersistenceLoad()
        guard !Task.isCancelled, !isAnyRouteActive else {
            if isAnyRouteActive { showRouteEditingLockedMessage() }
            return nil
        }
        guard let route = ImportedSavedRouteFactory.make(
            coordinates: coordinates,
            requestedName: requestedName,
            existingNames: savedRoutes.map(\.name),
            speedKmh: speedKmh
        ) else {
            presentedError = RouteLocationError.insufficientWaypoints.localizedDescription
            return nil
        }
        do {
            try await persistence.saveRoute(route)
            savedRoutes.append(route)
            previewingRoute = route
            mapFocusRevision = UUID()
            statusMessage = L10n.text("路線已匯入並儲存，可在我的路線中再次使用。")
            return route
        } catch {
            presentedError = L10n.format("無法匯入路線：%@", error.localizedDescription)
            return nil
        }
    }

    private func persistCurrentRoute(named requestedName: String?, asCopy: Bool) async -> Bool {
        await acquirePersistenceMutation()
        defer { releasePersistenceMutation() }
        await waitForInitialPersistenceLoad()
        guard !Task.isCancelled else { return false }
        do {
            guard waypoints.count >= 2 else { throw RouteLocationError.insufficientWaypoints }
            if routeMode == .navigation, navigationGeometryNeedsRecalculation { throw RouteLocationError.navigationNeedsRecalculation }
            guard geometry.coordinates.count > 1, geometry.totalDistance > 0 else { throw RouteLocationError.emptyGeometry }
            let now = Date()
            let existing = asCopy ? nil : savedRoutes.first { $0.id == loadedRouteID }
            let trimmedName = (requestedName ?? routeName).trimmingCharacters(in: .whitespacesAndNewlines)
            let desiredName = trimmedName.isEmpty ? L10n.text("新路線") : trimmedName
            let existingNames = savedRoutes.filter { $0.id != existing?.id }.map(\.name)
            let finalName = UniqueNameGenerator.makeUnique(base: desiredName, existing: existingNames, fallback: L10n.text("新路線"))
            let route = SavedRoute(
                id: existing?.id ?? UUID(), name: finalName,
                waypoints: waypoints, resolvedGeometry: geometry, routeMode: routeMode,
                navigationTransportMode: navigationTransport, isClosedLoop: isClosedLoop,
                preferredSpeedKmh: speedKmh, playbackMode: playbackMode,
                navigationGeometryNeedsRecalculation: false, isFavorite: existing?.isFavorite ?? false,
                lastUsedAt: existing?.lastUsedAt,
                createdAt: existing?.createdAt ?? now, updatedAt: now
            )
            try await persistence.saveRoute(route)
            loadedRouteID = route.id
            if !isAnyRouteActive { routeName = finalName }
            await reloadRoutes()
            statusMessage = L10n.text("路線已儲存，可離線播放。")
            return true
        } catch {
            presentedError = error.localizedDescription
            return false
        }
    }

    /// Favorites a route draft without replacing the normal Save Route flow.
    /// Existing loaded routes are updated in place; new drafts are persisted
    /// once and then marked favorite, so tapping the star never creates an
    /// accidental duplicate copy.
    @discardableResult
    func favoriteCurrentRoute(named requestedName: String? = nil) async -> Bool {
        guard await persistCurrentRoute(named: requestedName, asCopy: false),
              let loadedRouteID,
              let route = savedRoutes.first(where: { $0.id == loadedRouteID }) else { return false }
        if !route.isFavorite { await toggleFavoriteRoute(route) }
        return true
    }

    var currentSavedRoute: SavedRoute? {
        guard let loadedRouteID else { return nil }
        return savedRoutes.first { $0.id == loadedRouteID }
    }

    var currentRouteIsFavorite: Bool { currentSavedRoute?.isFavorite == true }

    @discardableResult
    func toggleFavoriteCurrentRoute() async -> Bool {
        guard let route = currentSavedRoute else { return false }
        await toggleFavoriteRoute(route)
        return savedRoutes.first(where: { $0.id == route.id })?.isFavorite == !route.isFavorite
    }

    func currentRouteCopyText() -> String? {
        try? RouteCopySerializer.serialize(RouteCopyDocument(
            name: playback.routeName.isEmpty ? routeName : playback.routeName,
            waypoints: waypoints,
            isClosedLoop: isClosedLoop,
            playbackMode: playbackMode
        ))
    }

    func renameRoute(_ route: SavedRoute, to requestedName: String) async {
        await acquirePersistenceMutation()
        defer { releasePersistenceMutation() }
        await waitForInitialPersistenceLoad()
        guard !Task.isCancelled, let route = savedRoutes.first(where: { $0.id == route.id }) else { return }
        guard !isActiveRoute(route) else { showRouteEditingLockedMessage(); return }
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { presentedError = L10n.text("請輸入路線名稱。"); return }
        var updated = route
        updated.name = name
        updated.updatedAt = .now
        do {
            try await persistence.saveRoute(updated)
            if loadedRouteID == updated.id { routeName = name }
            await reloadRoutes()
            statusMessage = L10n.text("路線已重新命名。")
        } catch { presentedError = L10n.format("無法重新命名路線：%@", error.localizedDescription) }
    }

    func toggleFavoriteRoute(_ route: SavedRoute) async {
        await acquirePersistenceMutation()
        defer { releasePersistenceMutation() }
        await waitForInitialPersistenceLoad()
        guard !Task.isCancelled, let route = savedRoutes.first(where: { $0.id == route.id }) else { return }
        var updated = route
        updated.isFavorite.toggle()
        updated.updatedAt = .now
        do {
            try await persistence.saveRoute(updated)
            await reloadRoutes()
            statusMessage = L10n.text(updated.isFavorite ? "已加入喜愛路線。" : "已從喜愛路線移除。")
        } catch { presentedError = L10n.format("無法更新喜愛路線：%@", error.localizedDescription) }
    }

    var isAnyRouteActive: Bool {
        simulationMode.isRouteSimulation ||
        playback.state == .running ||
        playback.state == .paused ||
        playback.state == .reconnecting
    }

    func syncPlaybackState(_ state: PlaybackRunState) {
        switch state {
        case .completed:
            // Natural finite/one-shot completion leaves the final DVT
            // coordinate active.  Convert the route into a single-point hold
            // instead of claiming that simulation is idle or clearing the
            // device location.  startSinglePointHold does not change the
            // playback engine state, so repeated .completed publications do
            // not recurse.
            guard simulationMode.isRouteSimulation, let finalCoordinate = playback.currentCoordinate else { return }
            startSinglePointHold(at: finalCoordinate)
            statusMessage = L10n.text("路線播放完成，目前停留在最後位置。")
        case .stopped:
            if simulationMode.isRouteSimulation {
                simulationMode = .idle
                if let currentSavedRoute { routeName = currentSavedRoute.name }
            }
        case .paused:
            if case .routePlaying = simulationMode {
                simulationMode = .routePaused
            }
        case .running:
            if case .routePaused = simulationMode {
                simulationMode = .routePlaying
            }
        default:
            break
        }
    }

    func isActiveRoute(_ route: SavedRoute) -> Bool {
        isAnyRouteActive && loadedRouteID == route.id
    }

    func isActiveRoute(id: UUID) -> Bool {
        isAnyRouteActive && loadedRouteID == id
    }

    func canEditRoute(_ route: SavedRoute? = nil) -> Bool {
        !isAnyRouteActive
    }

    func requestEditRoute(_ route: SavedRoute) -> Bool {
        guard canEditRoute(route) else {
            presentedError = L10n.text("目前正在執行路線，請先結束目前路線後再編輯。")
            return false
        }
        loadRoute(route)
        // Editing turns the preview into the editable draft. Keeping the old
        // preview snapshot alive would let the stale route remain visible and
        // startable after the user has begun editing it.
        previewingRoute = nil
        return true
    }

    var activeSimulatedCoordinate: RouteCoordinate? {
        switch simulationMode {
        case .singlePoint(let coordinate):
            return coordinate
        case .routePlaying, .routePaused:
            return playback.currentCoordinate
        case .idle:
            return nil
        }
    }

    func loadRoute(_ route: SavedRoute) {
        guard canMutateRouteDraft(notifyIfLocked: true) else { return }
        navigationResolver.cancel()
        loadedRouteID = route.id
        routeName = route.name
        waypoints = route.waypoints
        routeMode = route.routeMode
        navigationTransport = route.navigationTransportMode
        isClosedLoop = route.isClosedLoop
        speedKmh = route.preferredSpeedKmh
        playbackMode = route.playbackMode.normalized(isClosedLoop: route.isClosedLoop)
        geometry = route.resolvedGeometry
        navigationGeometryNeedsRecalculation = route.navigationGeometryNeedsRecalculation
        statusMessage = L10n.text("已載入快取路線，沒有重新計算導航。")
    }

    func previewRoute(_ route: SavedRoute) {
        // Previewing a different saved route is read-only with respect to the
        // immutable active playback snapshot.  Starting or editing it remains
        // guarded by the route-switch/edit flows.
        previewingRoute = route
        mapFocusRevision = UUID()
    }

    func cancelRoutePreview() {
        previewingRoute = nil
        mapFocusRevision = UUID()
    }

    func requestStartRoute(_ route: SavedRoute) {
        if isAnyRouteActive {
            if isActiveRoute(route) {
                statusMessage = L10n.format("目前正在模擬「%@」。", route.name)
                return
            }
            pendingSwitchRoute = route
            showActiveRouteSwitchAlert = true
        } else {
            Task {
                await startRoute(route)
            }
        }
    }

    func startRoute(_ route: SavedRoute) async {
        guard canMutateRouteDraft(notifyIfLocked: true) else { return }
        previewingRoute = nil
        loadRoute(route)
        await startPlayback()
    }

    func confirmSwitchToRoute(_ route: SavedRoute) async {
        showActiveRouteSwitchAlert = false
        pendingSwitchRoute = nil
        stopRoutePlayback(clearMarker: false)
        previewingRoute = nil
        loadRoute(route)
        await startPlayback()
        statusMessage = L10n.format("已切換至路線「%@」。", route.name)
    }

    func markRouteUsed(id: UUID) async {
        guard let updated = await persistRouteUsage(id: id) else { return }
        if let coordinate = updated.waypoints.first {
            await recordRecent(coordinate: coordinate, title: updated.name, kind: "route-start")
        }
    }

    private func persistRouteUsage(id: UUID) async -> SavedRoute? {
        await acquirePersistenceMutation()
        defer { releasePersistenceMutation() }
        await waitForInitialPersistenceLoad()
        guard !Task.isCancelled, let index = savedRoutes.firstIndex(where: { $0.id == id }) else { return nil }
        var updated = savedRoutes[index]
        updated.lastUsedAt = Date()
        do {
            try await persistence.saveRoute(updated)
            savedRoutes[index] = updated
            return updated
        } catch { return nil }
    }

    func deleteRoute(_ route: SavedRoute) async {
        await acquirePersistenceMutation()
        defer { releasePersistenceMutation() }
        await waitForInitialPersistenceLoad()
        guard !Task.isCancelled else { return }
        guard !isActiveRoute(route) else { showRouteEditingLockedMessage(); return }
        do {
            try await persistence.deleteRoute(id: route.id)
            if previewingRoute?.id == route.id { cancelRoutePreview() }
            if loadedRouteID == route.id { loadedRouteID = nil }
            await reloadRoutes()
        } catch { presentedError = L10n.format("無法刪除路線：%@", error.localizedDescription) }
    }

    func addFavorite(name: String, note: String? = nil, coordinate: RouteCoordinate? = nil) async {
        let target = coordinate ?? selectedCoordinate
        await acquirePersistenceMutation()
        defer { releasePersistenceMutation() }
        guard await canMutateFavorites() else { return }
        guard let target, target.isValid else { presentedError = L10n.text("請先選擇有效座標。"); return }
        await appendFavorite(name: name, note: note, coordinate: target)
    }

    /// Adds a recent location without creating a second favorite for the same
    /// coordinate.  Explicitly named favorites may still share names; the
    /// coordinate identity is what makes this action idempotent.
    func addFavoriteIfNeeded(name: String, note: String? = nil, coordinate: RouteCoordinate) async {
        await acquirePersistenceMutation()
        defer { releasePersistenceMutation() }
        guard await canMutateFavorites() else { return }
        guard coordinate.isValid else { return }
        if let existing = favorites.first(where: {
            abs($0.latitude - coordinate.latitude) < 0.000001 &&
            abs($0.longitude - coordinate.longitude) < 0.000001
        }) {
            var candidate = favorites
            guard let index = candidate.firstIndex(where: { $0.id == existing.id }) else { return }
            candidate[index].lastUsedAt = Date()
            guard await persistFavoriteCandidate(candidate) else { return }
            ToastManager.shared.show(L10n.format("已在收藏中：%@", existing.name), kind: .info)
            return
        }
        await appendFavorite(name: name, note: note, coordinate: coordinate)
    }

    /// Called only while holding the favorite mutation turn.
    private func appendFavorite(name: String, note: String?, coordinate: RouteCoordinate) async {
        let finalName = UniqueNameGenerator.makeUnique(base: name, existing: favorites.map(\.name), fallback: L10n.text("新地點"))
        let value = FavoriteLocation(name: finalName, coordinate: coordinate, note: note)
        var candidate = favorites
        candidate.append(value)
        guard await persistFavoriteCandidate(candidate) else { return }
        ToastManager.shared.show(L10n.format("已收藏「%@」", value.name), kind: .success)
    }

    func isFavorite(coordinate: RouteCoordinate) -> Bool {
        favorites.contains {
            abs($0.latitude - coordinate.latitude) < 0.000001 &&
            abs($0.longitude - coordinate.longitude) < 0.000001
        }
    }

    func moveFavorites(from offsets: IndexSet, to destination: Int) async {
        let originalOrder = favorites.map(\.id)
        let validOffsets = IndexSet(offsets.filter { favorites.indices.contains($0) })
        guard !validOffsets.isEmpty, (0...favorites.count).contains(destination) else { return }
        await acquirePersistenceMutation()
        defer { releasePersistenceMutation() }
        guard await canMutateFavorites() else { return }
        // The preflight suspends. Old offsets describe the requested move only
        // while this exact ID order still exists; preserve any newer edits.
        guard favorites.map(\.id) == originalOrder else { return }
        var candidate = favorites
        candidate.move(fromOffsets: validOffsets, toOffset: destination)
        guard await persistFavoriteCandidate(candidate) else { return }
        manualFavoriteOrder = candidate.map(\.id)
        persistManualFavoriteOrder()
    }

    func setManualFavoriteOrder(_ ids: [UUID]) async {
        await acquirePersistenceMutation()
        defer { releasePersistenceMutation() }
        guard await canMutateFavorites() else { return }
        var seen = Set<UUID>()
        let ordered = ids.compactMap { id -> FavoriteLocation? in
            guard seen.insert(id).inserted else { return nil }
            return favorites.first { $0.id == id }
        }
        let candidate = ordered + favorites.filter { !seen.contains($0.id) }
        guard await persistFavoriteCandidate(candidate) else { return }
        manualFavoriteOrder = candidate.map(\.id)
        persistManualFavoriteOrder()
    }

    func suggestedFavoriteName() -> String {
        UniqueNameGenerator.makeUnique(base: L10n.text("新地點"), existing: favorites.map(\.name), fallback: L10n.text("新地點"))
    }

    func suggestedRouteName() -> String {
        UniqueNameGenerator.makeUnique(base: L10n.text("新路線"), existing: savedRoutes.map(\.name), fallback: L10n.text("新路線"))
    }

    /// The favorite action is an in-place update for a loaded route. Keep its
    /// current name in the naming alert so tapping Favorite is never an
    /// accidental rename; unsaved drafts still receive a unique suggestion.
    func suggestedFavoriteRouteName() -> String {
        if hasLoadedRoute, !routeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return routeName
        }
        return suggestedRouteName()
    }

    func updateFavorite(_ favorite: FavoriteLocation, name: String, note: String?) async {
        await acquirePersistenceMutation()
        defer { releasePersistenceMutation() }
        guard await canMutateFavorites() else { return }
        guard let index = favorites.firstIndex(where: { $0.id == favorite.id }) else { return }
        var candidate = favorites
        candidate[index].name = name
        candidate[index].note = note
        candidate[index].updatedAt = .now
        await persistFavoriteCandidate(candidate)
    }

    @discardableResult
    func markFavoriteUsed(_ favorite: FavoriteLocation) async -> Bool {
        await acquirePersistenceMutation()
        defer { releasePersistenceMutation() }
        guard await canMutateFavorites() else { return false }
        guard let index = favorites.firstIndex(where: { $0.id == favorite.id }) else { return false }
        var candidate = favorites
        candidate[index].lastUsedAt = Date()
        return await persistFavoriteCandidate(candidate)
    }

    func deleteFavorites(at offsets: IndexSet) async {
        let requestedIDs = Set(offsets.compactMap { index in
            favorites.indices.contains(index) ? favorites[index].id : nil
        })
        await deleteFavorites(ids: requestedIDs)
    }

    func deleteFavorites(ids requestedIDs: Set<UUID>) async {
        guard !requestedIDs.isEmpty else { return }
        await acquirePersistenceMutation()
        defer { releasePersistenceMutation() }
        guard await canMutateFavorites() else { return }
        let candidate = favorites.filter { !requestedIDs.contains($0.id) }
        guard await persistFavoriteCandidate(candidate) else { return }
        let ids = Set(favorites.map(\.id))
        manualFavoriteOrder = manualFavoriteOrder.filter { ids.contains($0) }
        persistManualFavoriteOrder()
    }

    var isCellularBootstrapPreparationNeeded: Bool {
        let hasActiveDVT = connectionMonitor.activeDVTSessionAvailable || LocationDataPathHealth.shared.hasRecentSuccess
            || LocationSimulationCommandQueue.shared.sync { location_simulation_session_snapshot().isPrepared }
        guard !hasActiveDVT else { return false }
        guard connectionMonitor.currentTransport != .wifi else { return false }
        // directOnly still needs a real production preparation attempt; it
        // simply refuses the assisted DataOff/DataOn fallback. Automatic
        // cellular cold starts use the known-good assisted transaction.
        return connectionMonitor.currentTransport == .cellular || connectionMonitor.isCellularAvailable
    }

    func requestBootstrapIfCellular(targetCoordinate: RouteCoordinate? = nil, action: @escaping @MainActor () -> Void) {
        self.pendingBootstrapTargetCoordinate = targetCoordinate
        self.pendingBootstrapAction = action

        BootstrapCoordinator.shared.coordinateSimulation(
            targetCoordinate: targetCoordinate,
            onRequestPreflight: { [weak self] in
                guard let self else { return }
                TunnelManager.shared.cellularBootstrapRequested = true
                self.showBootstrapPreflightSheet = true
            },
            onProceed: { [weak self] disposition in
                guard let self else { return }
                if disposition == .locationAlreadyWritten, let targetCoordinate {
                    self.locationAlreadyWrittenByBootstrap = targetCoordinate
                } else {
                    self.locationAlreadyWrittenByBootstrap = nil
                }
                self.pendingBootstrapTargetCoordinate = nil
                self.pendingBootstrapAction = nil
                action()
            },
            onError: { [weak self] error in
                guard let self else { return }
                self.pendingBootstrapTargetCoordinate = nil
                self.pendingBootstrapAction = nil
                self.presentedError = error.localizedDescription
            }
        )
    }

    func startAssistedBootstrapFromPreflight() {
        guard let action = pendingBootstrapAction else { return }
        let target = pendingBootstrapTargetCoordinate
        BootstrapCoordinator.shared.executeAssistedBootstrap(
            targetCoordinate: target,
            onProceed: { [weak self] disposition in
                guard let self else { return }
                if disposition == .locationAlreadyWritten, let target {
                    self.locationAlreadyWrittenByBootstrap = target
                } else {
                    self.locationAlreadyWrittenByBootstrap = nil
                }
                self.showBootstrapPreflightSheet = false
                self.pendingBootstrapAction = nil
                self.pendingBootstrapTargetCoordinate = nil
                action()
            },
            onError: { [weak self] error in
                guard let self else { return }
                self.showBootstrapPreflightSheet = false
                self.pendingBootstrapAction = nil
                self.pendingBootstrapTargetCoordinate = nil
                self.presentedError = error.localizedDescription
            }
        )
    }

    func confirmBootstrapPreflightRecheck() {
        showBootstrapPreflightSheet = false
        TunnelManager.shared.cellularBootstrapRequested = true
        let action = pendingBootstrapAction
        pendingBootstrapAction = nil
        pendingBootstrapTargetCoordinate = nil
        locationAlreadyWrittenByBootstrap = nil
        action?()
    }

    func confirmBootstrapPreflightForce() {
        showBootstrapPreflightSheet = false
        TunnelManager.shared.cellularBootstrapRequested = true
        let action = pendingBootstrapAction
        pendingBootstrapAction = nil
        pendingBootstrapTargetCoordinate = nil
        locationAlreadyWrittenByBootstrap = nil
        action?()
    }

    func cancelBootstrapPreflight() {
        showBootstrapPreflightSheet = false
        pendingBootstrapAction = nil
        pendingBootstrapTargetCoordinate = nil
        locationAlreadyWrittenByBootstrap = nil
        TunnelManager.shared.cellularBootstrapRequested = false
        CellularAssistedBootstrapStateMachine.shared.cancel()
    }

    func requestSinglePointSimulation(at coordinate: RouteCoordinate? = nil) {
        guard let target = coordinate ?? selectedCoordinate, target.isValid else {
            presentedError = L10n.text("請先選擇座標。")
            return
        }
        if simulationMode.isRouteSimulation {
            if modeSwitchConfirmation == .askFirst {
                pendingSinglePointCoordinate = target
                showModeSwitchAlert = true
                return
            }
        }
        if case .singlePoint = simulationMode {
            // A single-point simulation is already a prepared target.  A new
            // target is a direct retarget and must not clear the simulated
            // location or re-enter cellular cold bootstrap.
            let generation = beginSinglePointRetarget()
            Task { [weak self] in
                await self?.executeTeleport(
                    to: target,
                    generation: generation,
                    preservesSinglePointKeepAlive: true
                )
            }
            return
        }
        requestBootstrapIfCellular(targetCoordinate: target) { [weak self] in
            guard let self else { return }
            Task { await self.executeTeleport(to: target) }
        }
    }

    func confirmModeSwitchToSinglePoint() async {
        guard let target = pendingSinglePointCoordinate else { return }
        pendingSinglePointCoordinate = nil
        showModeSwitchAlert = false
        await executeTeleport(to: target)
    }

    func cancelModeSwitch() {
        pendingSinglePointCoordinate = nil
        showModeSwitchAlert = false
    }

    private func startSinglePointHold(at target: RouteCoordinate) {
        singlePointHoldGeneration &+= 1
        let generation = singlePointHoldGeneration
        teleportTask?.cancel()
        selectedCoordinate = target
        simulationMode = .singlePoint(target)
        connectionMonitor.reportSession(.connected)
        LocationSessionCoordinator.shared.markSessionHealthy()
        BackgroundKeepAliveService.shared.acquire()
        teleportTask = Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                guard let self else { return }
                guard !Task.isCancelled, generation == self.singlePointHoldGeneration else { return }
                do {
                    try await self.simulationService.setCoordinate(target)
                    guard !Task.isCancelled, generation == self.singlePointHoldGeneration else { return }
                    consecutiveFailures = 0
                    self.connectionMonitor.reportSession(.connected)
                    LocationSessionCoordinator.shared.markSessionHealthy()
                } catch {
                    consecutiveFailures += 1
                    LocationSessionCoordinator.shared.markSessionDegraded(error: error)
                    guard PlaybackReconnectPolicy.shouldRetry(error), consecutiveFailures < 4 else {
                        self.presentedError = error.localizedDescription
                        self.connectionMonitor.reportSession(.error(error.localizedDescription))
                        BackgroundKeepAliveService.shared.release()
                        return
                    }
                    guard LocationRecoveryPolicy.shouldRecover(consecutiveFailures: consecutiveFailures) else { continue }
                    self.connectionMonitor.reportSession(.reconnecting(attempt: consecutiveFailures))
                    markTunnelDisconnected()
                    startTunnelInBackground(showErrorUI: false)
                }
            }
        }
    }

    func executeTeleport(to target: RouteCoordinate) async {
        let generation = beginSinglePointRetarget()
        let preservesSinglePointKeepAlive: Bool
        if case .singlePoint = simulationMode {
            preservesSinglePointKeepAlive = true
        } else {
            preservesSinglePointKeepAlive = false
        }
        await executeTeleport(
            to: target,
            generation: generation,
            preservesSinglePointKeepAlive: preservesSinglePointKeepAlive
        )
    }

    private func executeTeleport(
        to target: RouteCoordinate,
        generation: Int,
        preservesSinglePointKeepAlive: Bool
        ) async {
        guard generation == singlePointRetargetGeneration else { return }
        cancelSinglePointHold()
        // A single-point → single-point retarget does not need to stop the
        // already-stopped playback engine.  Avoid releasing its shared
        // keep-alive lease while the existing location session is healthy.
        if !preservesSinglePointKeepAlive {
            stopRoutePlayback(clearMarker: false)
        }
        let alreadyWritten = (locationAlreadyWrittenByBootstrap == target)
        locationAlreadyWrittenByBootstrap = nil

        if alreadyWritten {
            guard generation == singlePointRetargetGeneration else { return }
            startSinglePointHold(at: target)
            successfulSinglePointRevision = UUID()
            statusMessage = L10n.text("已成功模擬所選位置。")
            notifyTeleportCompletionForTesting()
            await recordRecent(coordinate: target, kind: "simulate", retargetGeneration: generation)
            return
        }

        let hadPreparedSession = LocationSimulationCommandQueue.shared.sync {
            location_simulation_session_snapshot().isPrepared
        }
        let forceStaleSessionRecovery = PreparedSessionRecoveryPolicy.shouldForceAssistedRecovery(
            preparedSession: hadPreparedSession,
            transport: connectionMonitor.currentTransport,
            wifiAvailable: connectionMonitor.isWifiAvailable,
            shortcutAssistedEnabled: ShortcutBootstrapService.shared.isShortcutAssistedEnabled
        )

        do {
            try await setCoordinateWithBoundedRecovery(
                target,
                skipLegacyTransportRecovery: forceStaleSessionRecovery,
                retargetGeneration: generation
            )
            guard generation == singlePointRetargetGeneration else { return }
            startSinglePointHold(at: target)
            successfulSinglePointRevision = UUID()
            statusMessage = L10n.text("已成功模擬所選位置。")
            notifyTeleportCompletionForTesting()
            await recordRecent(coordinate: target, kind: "simulate", retargetGeneration: generation)
        } catch {
            // A newer request may have taken ownership while the old write
            // was retrying.  In that case do not clean shared handles or
            // publish an error for the stale operation.
            guard generation == singlePointRetargetGeneration else { return }
            if forceStaleSessionRecovery {
                LocationSimulationCommandQueue.shared.sync {
                    cleanup_prepared_location_simulation_session()
                }
                LocationDataPathHealth.shared.invalidateAfterConfirmedStaleSessionFailure(error)
                LocationSessionCoordinator.shared.endSession()
                do {
                    let disposition = try await performStalePreparedSessionRecovery(target)
                    guard generation == singlePointRetargetGeneration else { return }
                    if disposition == .needsLocationWrite {
                        try await simulationService.setCoordinate(target)
                        guard generation == singlePointRetargetGeneration else { return }
                    }
                    guard generation == singlePointRetargetGeneration else { return }
                    startSinglePointHold(at: target)
                    successfulSinglePointRevision = UUID()
                    statusMessage = L10n.text("已成功模擬所選位置。")
                    notifyTeleportCompletionForTesting()
                    await recordRecent(coordinate: target, kind: "simulate", retargetGeneration: generation)
                    return
                } catch {
                    guard generation == singlePointRetargetGeneration else { return }
                    LocationSessionCoordinator.shared.markSessionDegraded(error: error)
                    presentedError = error.localizedDescription
                    return
                }
            }
            LocationSessionCoordinator.shared.markSessionDegraded(error: error)
            presentedError = error.localizedDescription
        }
    }

    func teleport(to coordinate: RouteCoordinate? = nil) async {
        if simulationMode.isRouteSimulation, modeSwitchConfirmation == .askFirst {
            requestSinglePointSimulation(at: coordinate)
        } else {
            guard let target = coordinate ?? selectedCoordinate, target.isValid else {
                presentedError = L10n.text("請先選擇座標。")
                return
            }
            await executeTeleport(to: target)
        }
    }

    func startPlayback() async {
        guard !isAnyRouteActive else { showRouteEditingLockedMessage(); return }
        if isCellularBootstrapPreparationNeeded {
            let firstCoord = geometry.coordinates.first
            requestBootstrapIfCellular(targetCoordinate: firstCoord) { [weak self] in
                guard let self else { return }
                Task { await self.startPlaybackAfterBootstrapPreparation() }
            }
            return
        }

        await startPlaybackAfterBootstrapPreparation()
    }

    private func startPlaybackAfterBootstrapPreparation() async {
        cancelSinglePointHold()
        locationAlreadyWrittenByBootstrap = nil
        #if DEBUG
        testPlaybackStartInvocationCount += 1
        defer {
            let completion = testPlaybackAfterBootstrapCompletion
            testPlaybackAfterBootstrapCompletion = nil
            completion?()
        }
        #endif
        do {
            if playbackMode == .infiniteLoop, !isClosedLoop { throw RouteLocationError.loopRequiresClosedRoute }
            if routeMode == .navigation, navigationGeometryNeedsRecalculation { throw RouteLocationError.navigationNeedsRecalculation }
            try await playback.start(routeName: routeName, geometry: geometry, speedKmh: speedKmh, mode: playbackMode)
            simulationMode = .routePlaying
            LocationSessionCoordinator.shared.markSessionHealthy()
            if let loadedRouteID {
                await markRouteUsed(id: loadedRouteID)
            }
        } catch { presentedError = error.localizedDescription }
    }

    /// End route playback but keep the last simulated coordinate active.
    /// Does NOT restore real location. Shows options to keep position or restore.
    func endRoute() {
        guard let lastCoord = playback.currentCoordinate else {
            stopRoutePlayback(clearMarker: false)
            return
        }
        stopRoutePlayback(clearMarker: false)
        startSinglePointHold(at: lastCoord)
        showEndRouteOptions = true
        statusMessage = L10n.text("路線已結束，目前位置仍為模擬位置。")
    }

    /// Stops route movement while intentionally keeping the last simulated
    /// coordinate active.  Player overflow actions use this direct semantic;
    /// it does not restore GPS and does not present a second confirmation.
    func stopAndHoldCurrentLocation() {
        guard let lastCoord = playback.currentCoordinate else {
            stopRoutePlayback(clearMarker: false)
            return
        }
        stopRoutePlayback(clearMarker: false)
        startSinglePointHold(at: lastCoord)
        showEndRouteOptions = false
        statusMessage = L10n.text("路線已停止，目前位置仍為模擬位置。")
    }

    func returnToRealLocation() async {
        // Restoring the real location supersedes any retarget still waiting
        // on a command/recovery boundary.
        _ = beginSinglePointRetarget()
        cancelSinglePointHold()
        stopRoutePlayback(clearMarker: true)
        LocationSessionCoordinator.shared.markRestoringRealLocation()
        do {
            do {
                try await simulationService.clearSimulatedLocation()
            } catch {
                LogManager.shared.addWarningLog("First clear simulated location attempt failed, retrying once: \(error)")
                try await Task.sleep(for: .milliseconds(500))
                try await simulationService.clearSimulatedLocation()
            }
            BackgroundKeepAliveService.shared.release()
            let retained = LocationSimulationCommandQueue.shared.sync {
                location_simulation_session_snapshot().isPrepared
            }
            if retained {
                connectionMonitor.reportSession(.connected)
                LocationSessionCoordinator.shared.markPreparedSessionRetained()
            } else {
                connectionMonitor.reportSession(.idle)
                LocationSessionCoordinator.shared.endSession()
            }
            simulationMode = .idle
            statusMessage = retained
                ? L10n.text("已恢復真實位置。下一次模擬可快速開始。")
                : L10n.text("已恢復裝置的真實位置。")
            successfulRestoreRevision = UUID()
            DeveloperDiagnosticsStore.shared.record(
                category: .lifecycle,
                action: "RESTORE_REAL_LOCATION_SUCCESS",
                details: [:]
            )
        } catch {
            DeveloperDiagnosticsStore.shared.record(
                category: .lifecycle,
                action: "RESTORE_REAL_LOCATION_FAILURE",
                details: ["error": error.localizedDescription]
            )
            presentedError = error.localizedDescription
        }
    }

    private func routeInputsChanged() {
        guard !isAnyRouteActive else { return }
        guard !waypoints.isEmpty else { geometry = RouteGeometry(coordinates: []); navigationGeometryNeedsRecalculation = routeMode == .navigation; return }
        if routeMode == .straight {
            geometry = RouteBuilder.straightGeometry(waypoints: waypoints, closedLoop: isClosedLoop)
            navigationGeometryNeedsRecalculation = false
        } else {
            navigationGeometryNeedsRecalculation = true
        }
    }

    private func canMutateRouteDraft(notifyIfLocked: Bool) -> Bool {
        guard !isAnyRouteActive else {
            if notifyIfLocked { showRouteEditingLockedMessage() }
            return false
        }
        return true
    }

    private func showRouteEditingLockedMessage() {
        let message = L10n.text("路線播放中，請先停止路線再編輯。")
        statusMessage = message
        ToastManager.shared.show(message, kind: .info)
    }

    private func restoreRouteConfiguration<Value>(_ previous: Value, setter: (Value) -> Void) {
        restoreRouteConfigurationAfterRejectedEdit = true
        setter(previous)
        restoreRouteConfigurationAfterRejectedEdit = false
        showRouteEditingLockedMessage()
    }

    private func setCoordinateWithBoundedRecovery(
        _ coordinate: RouteCoordinate,
        skipLegacyTransportRecovery: Bool = false,
        retargetGeneration: Int? = nil
    ) async throws {
        let delays: [TimeInterval] = [0, 0.5, 1, 2]
        var lastError: Error?
        for (index, delay) in delays.enumerated() {
            try ensureRetargetGenerationIsCurrent(retargetGeneration)
            if delay > 0 {
                do {
                    try await waitForBoundedRecoveryDelay(delay, retargetGeneration: retargetGeneration)
                } catch {
                    throw error
                }
                try ensureRetargetGenerationIsCurrent(retargetGeneration)
            }
            try ensureRetargetGenerationIsCurrent(retargetGeneration)
            do {
                try ensureRetargetGenerationIsCurrent(retargetGeneration)
                try await simulationService.setCoordinate(coordinate)
                try ensureRetargetGenerationIsCurrent(retargetGeneration)
                return
            } catch {
                try ensureRetargetGenerationIsCurrent(retargetGeneration)
                lastError = error
                TunnelManager.shared.reportLocationFailure(error, transport: connectionMonitor.currentTransport)
                guard PlaybackReconnectPolicy.shouldRetry(error) else { throw error }
                if skipLegacyTransportRecovery { throw error }
                try ensureRetargetGenerationIsCurrent(retargetGeneration)
                connectionMonitor.reportSession(.reconnecting(attempt: index + 1))
                try ensureRetargetGenerationIsCurrent(retargetGeneration)
                markTunnelDisconnected()
                try ensureRetargetGenerationIsCurrent(retargetGeneration)
                startTunnelInBackground(showErrorUI: false)
            }
        }
        throw lastError ?? LocationSimulationError.deviceTunnelUnavailable
    }

    private func waitForBoundedRecoveryDelay(
        _ delay: TimeInterval,
        retargetGeneration: Int?
    ) async throws {
        #if DEBUG
        if retargetGeneration != nil, let handler = testRetryDelayHandler {
            try await handler(delay)
            return
        }
        #endif
        try await Task.sleep(for: .seconds(delay))
    }

    private func ensureRetargetGenerationIsCurrent(_ generation: Int?) throws {
        guard generation == nil || generation == singlePointRetargetGeneration else {
            throw RetargetOperationSuperseded()
        }
    }

    private func loadPersistedData() async {
        var errors: [String] = []
        do {
            favorites = try await persistence.loadFavorites()
            let loadedIDs = Set(favorites.map(\.id))
            manualFavoriteOrder = manualFavoriteOrder.filter { loadedIDs.contains($0) }
            manualFavoriteOrder.append(contentsOf: favorites.map(\.id).filter { !manualFavoriteOrder.contains($0) })
            persistManualFavoriteOrder()
        } catch { errors.append(error.localizedDescription) }
        do {
            savedRoutes = try await persistence.loadRoutes()
            let legacyRoutes = savedRoutes.filter { $0.name == "New Route" }
            for route in legacyRoutes {
                var updated = route
                updated.name = L10n.text("新路線")
                try await persistence.saveRoute(updated)
            }
            if !legacyRoutes.isEmpty { savedRoutes = try await persistence.loadRoutes() }
        } catch { errors.append(error.localizedDescription) }
        do {
            recentLocations = try await persistence.loadRecentLocations()
        } catch { errors.append(error.localizedDescription) }
        if !errors.isEmpty {
            presentedError = L10n.format("無法載入已儲存資料：%@", errors.joined(separator: "\n"))
        }
    }

    private func reloadRoutes() async {
        do { savedRoutes = try await persistence.loadRoutes() }
        catch { presentedError = error.localizedDescription }
    }

    private func canMutateFavorites() async -> Bool {
        await waitForInitialPersistenceLoad()
        guard !Task.isCancelled else { return false }
        do {
            try await persistence.ensureFavoritesWritable()
            return !Task.isCancelled
        } catch {
            presentedError = L10n.format("無法儲存喜愛地點：%@", error.localizedDescription)
            return false
        }
    }

    @discardableResult
    private func persistFavoriteCandidate(_ candidate: [FavoriteLocation]) async -> Bool {
        guard !Task.isCancelled else { return false }
        do {
            try await persistence.saveFavorites(candidate)
            // Once committed, publish even if cancellation arrived during IO;
            // memory must reflect the completed durable operation.
            favorites = candidate
            return true
        } catch {
            presentedError = L10n.format("無法儲存喜愛地點：%@", error.localizedDescription)
            return false
        }
    }

    private func acquirePersistenceMutation() async {
        if persistenceMutationInProgress {
            await withCheckedContinuation { continuation in
                persistenceMutationWaiters.append(continuation)
                #if DEBUG
                testPersistenceMutationQueued?()
                #endif
            }
        } else {
            persistenceMutationInProgress = true
        }
    }

    private func releasePersistenceMutation() {
        if persistenceMutationWaiters.isEmpty {
            persistenceMutationInProgress = false
        } else {
            persistenceMutationWaiters.removeFirst().resume()
        }
    }

    /// Lifecycle callers may invoke this on foreground/unlock. The repository
    /// retries only failed libraries; no healthy collection is reloaded.
    func retryFailedPersistenceLoads() async {
        await acquirePersistenceMutation()
        defer { releasePersistenceMutation() }
        await waitForInitialPersistenceLoad()
        guard !Task.isCancelled else { return }
        let recovered = await persistence.retryFailedLibraries()
        #if DEBUG
        await testBeforeRecoveredLibrariesPublish?()
        #endif
        if let values = recovered.favorites {
            favorites = values
            let ids = Set(values.map(\.id))
            manualFavoriteOrder = manualFavoriteOrder.filter { ids.contains($0) }
            manualFavoriteOrder.append(contentsOf: values.map(\.id).filter { !manualFavoriteOrder.contains($0) })
            persistManualFavoriteOrder()
        }
        if let values = recovered.routes { savedRoutes = values }
        if let values = recovered.recents { recentLocations = values }
    }

    func recordRecent(
        coordinate: RouteCoordinate,
        title: String? = nil,
        kind: String = "simulate",
        retargetGeneration: Int? = nil
    ) async {
        await acquirePersistenceMutation()
        defer { releasePersistenceMutation() }
        await waitForInitialPersistenceLoad()
        guard !Task.isCancelled else { return }
        if let retargetGeneration, retargetGeneration != singlePointRetargetGeneration { return }
        guard coordinate.isValid else { return }
        var candidate = recentLocations.filter { existing in
            !(abs(existing.coordinate.latitude - coordinate.latitude) < 0.000001 &&
              abs(existing.coordinate.longitude - coordinate.longitude) < 0.000001)
        }
        candidate.insert(RecentLocation(coordinate: coordinate, title: title, kind: kind), at: 0)
        await persistRecentCandidate(Array(candidate.prefix(30)))
    }

    func clearRecentLocations() async {
        await acquirePersistenceMutation()
        defer { releasePersistenceMutation() }
        await waitForInitialPersistenceLoad()
        guard !Task.isCancelled else { return }
        await persistRecentCandidate([])
    }

    func deleteRecentLocation(_ item: RecentLocation) async {
        await acquirePersistenceMutation()
        defer { releasePersistenceMutation() }
        await waitForInitialPersistenceLoad()
        guard !Task.isCancelled else { return }
        await persistRecentCandidate(recentLocations.filter { $0.id != item.id })
    }

    private func persistRecentCandidate(_ candidate: [RecentLocation]) async {
        do {
            try await persistence.saveRecentLocations(candidate)
            recentLocations = candidate
        } catch {
            // Retain the current UI when storage is temporarily unavailable.
            // Initial read failures remain protected until lifecycle recovery.
        }
    }

    private func waitForInitialPersistenceLoad() async {
        guard let task = persistenceLoadTask else { return }
        await task.value
        persistenceLoadTask = nil
    }

    var sortedFavorites: [FavoriteLocation] {
        FavoriteSortPolicy.sort(
            favorites,
            option: librarySortOption,
            manualOrder: manualFavoriteOrder,
            deviceCoordinate: BackgroundLocationManager.shared.latestCoordinate
        )
    }

    private func cancelSinglePointHold() {
        singlePointHoldGeneration &+= 1
        teleportTask?.cancel()
        teleportTask = nil
    }

    private func beginSinglePointRetarget() -> Int {
        singlePointRetargetGeneration &+= 1
        return singlePointRetargetGeneration
    }

    func sortedFavorites(from deviceCoordinate: RouteCoordinate?) -> [FavoriteLocation] {
        FavoriteSortPolicy.sort(
            favorites,
            option: librarySortOption,
            manualOrder: manualFavoriteOrder,
            deviceCoordinate: deviceCoordinate
        )
    }

    func setPlaybackSpeed(_ speed: Double) {
        do {
            let clamped = PlaybackSpeedPolicy.clamp(speed)
            try playback.setSpeed(clamped)
            speedKmh = clamped
        } catch { presentedError = error.localizedDescription }
    }

    func adjustPlaybackSpeed(by delta: Double) {
        setPlaybackSpeed(PlaybackSpeedPolicy.adjusted(playback.speedKmh > 0 ? playback.speedKmh : speedKmh, by: delta))
    }

    #if DEBUG
    func setLocationAlreadyWrittenByBootstrapForTesting(_ coord: RouteCoordinate?) {
        self.locationAlreadyWrittenByBootstrap = coord
    }
    #endif

    private func persistManualFavoriteOrder() {
        guard let data = try? JSONEncoder().encode(manualFavoriteOrder) else { return }
        UserDefaults.standard.set(data, forKey: Self.manualFavoriteOrderKey)
    }

    #if DEBUG
    func testSetSimulationModeForTesting(_ mode: SimulationMode) {
        simulationMode = mode
    }
    #endif

    private func notifyTeleportCompletionForTesting() {
        #if DEBUG
        let completion = testTeleportCompletion
        testTeleportCompletion = nil
        completion?()
        #endif
    }
}

private struct RetargetOperationSuperseded: Error {}
