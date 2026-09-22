import Combine
import CoreLocation
import Foundation
import SwiftUI

@MainActor
final class RouteLocationModel: ObservableObject {
    @Published var selectedCoordinate: RouteCoordinate?
    @Published var waypoints: [RouteCoordinate] = []
    @Published var routeName = L10n.text("新路線")
    @Published var routeMode: RouteMode = .straight { didSet { routeInputsChanged() } }
    @Published var navigationTransport: NavigationTransportMode = .automobile { didSet { routeInputsChanged() } }
    @Published var isClosedLoop = true { didSet { routeInputsChanged() } }
    @Published var playbackMode: RoutePlaybackMode = .infiniteLoop
    @Published var speedKmh: Double {
        didSet { if speedKmh.isFinite, speedKmh > 0 { UserDefaults.standard.set(speedKmh, forKey: Self.speedKey) } }
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
    @Published var previewingRoute: SavedRoute?
    @Published var showActiveRouteSwitchAlert = false
    @Published var pendingSwitchRoute: SavedRoute?
    @Published var showEndRouteOptions = false
    private var pendingBootstrapAction: (@MainActor () -> Void)?
    @Published private(set) var geometry = RouteGeometry(coordinates: [])
    @Published private(set) var navigationGeometryNeedsRecalculation = false
    @Published private(set) var favorites: [FavoriteLocation] = []
    @Published private(set) var savedRoutes: [SavedRoute] = []
    @Published private(set) var isResolvingNavigation = false
    @Published var presentedError: String?
    @Published var statusMessage: String?
    @Published private(set) var mapFocusRevision = UUID()

    let playback: RoutePlaybackEngine
    let connectionMonitor: ConnectionMonitor
    private let persistence: RoutePersistenceStore
    private let navigationResolver = NavigationRouteResolver()
    private let simulationService: any LocationSimulationSink
    private var teleportTask: Task<Void, Never>?
    private var loadedRouteID: UUID?
    private var cancellables: Set<AnyCancellable> = []
    private static let speedKey = "RouteLocation.lastSpeedKmh"
    private static let mapStyleKey = "RouteLocation.mapInteractionStyle"
    private static let modeSwitchKey = "RouteLocation.modeSwitchConfirmation"

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
        speedKmh = savedSpeed > 0 ? savedSpeed : 18.6

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

        playback = RoutePlaybackEngine(sink: simulationService, connectionMonitor: connectionMonitor)
        HealthStepSyncService.shared.attach(to: playback)

        playback.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if case .completed = state {
                    if case .routePlaying = self.simulationMode {
                        self.simulationMode = .idle
                    }
                } else if case .stopped = state {
                    if case .routePlaying = self.simulationMode {
                        self.simulationMode = .idle
                    }
                } else if case .paused = state {
                    if case .routePlaying = self.simulationMode {
                        self.simulationMode = .routePaused
                    }
                } else if case .running = state {
                    if case .routePaused = self.simulationMode {
                        self.simulationMode = .routePlaying
                    }
                }
            }
            .store(in: &cancellables)

        Task { await loadPersistedData() }
    }

    var estimatedLapDuration: TimeInterval? {
        let metersPerSecond = PlaybackMath.metersPerSecond(kmh: speedKmh)
        guard geometry.totalDistance > 0, metersPerSecond > 0 else { return nil }
        return geometry.totalDistance / metersPerSecond
    }

    func select(_ coordinate: CLLocationCoordinate2D) {
        let value = RouteCoordinate(coordinate)
        guard value.isValid else { return }
        selectedCoordinate = value
    }

    func focusOnMap(_ coordinate: RouteCoordinate) {
        guard coordinate.isValid else { return }
        selectedCoordinate = coordinate
        mapFocusRevision = UUID()
    }

    func addSelectedWaypoint() {
        guard let selectedCoordinate else { return }
        addWaypoint(selectedCoordinate)
        self.selectedCoordinate = nil
    }

    func addWaypoint(_ coordinate: RouteCoordinate) {
        guard coordinate.isValid else { presentedError = RouteLocationError.insufficientWaypoints.localizedDescription; return }
        if waypoints.last != coordinate { waypoints.append(coordinate); routeInputsChanged() }
    }

    func replaceWaypoints(_ coordinates: [RouteCoordinate]) {
        waypoints = coordinates.filter(\.isValid)
        routeInputsChanged()
    }

    func removeWaypoints(at offsets: IndexSet) {
        waypoints.remove(atOffsets: offsets)
        routeInputsChanged()
    }

    func moveWaypoints(from offsets: IndexSet, to destination: Int) {
        waypoints.move(fromOffsets: offsets, toOffset: destination)
        routeInputsChanged()
    }

    func updateWaypoint(at index: Int, latitude: Double, longitude: Double) {
        guard waypoints.indices.contains(index) else { return }
        let updated = RouteCoordinate(latitude: latitude, longitude: longitude)
        guard updated.isValid else { presentedError = CoordinateImportError.invalidCoordinate(line: index + 1).localizedDescription; return }
        waypoints[index] = updated
        routeInputsChanged()
    }

    func clearWaypoints() {
        waypoints = []
        loadedRouteID = nil
        routeInputsChanged()
    }

    func undoLastWaypoint() {
        guard !waypoints.isEmpty else { return }
        waypoints.removeLast()
        routeInputsChanged()
    }

    func clearCurrentDraft() {
        waypoints = []
        loadedRouteID = nil
        routeName = L10n.text("新路線")
        geometry = RouteGeometry(coordinates: [])
        navigationGeometryNeedsRecalculation = false
        statusMessage = L10n.text("路線草稿已清除。")
    }

    func clearCurrentRoute() {
        navigationResolver.cancel()
        playback.stop(clearMarker: true)
        if case .routePlaying = simulationMode {
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
        guard !isResolvingNavigation else { return }
        isResolvingNavigation = true
        defer { isResolvingNavigation = false }
        do {
            let resolved = try await navigationResolver.resolve(waypoints: waypoints, closedLoop: isClosedLoop, transport: navigationTransport)
            geometry = resolved
            navigationGeometryNeedsRecalculation = false
            statusMessage = L10n.text("導航路線已計算完成，可以儲存。")
        } catch is CancellationError {
            return
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func saveCurrentRoute(named requestedName: String? = nil, asCopy: Bool = false) async {
        do {
            guard waypoints.count >= 2 else { throw RouteLocationError.insufficientWaypoints }
            if routeMode == .navigation, navigationGeometryNeedsRecalculation { throw RouteLocationError.navigationNeedsRecalculation }
            guard geometry.coordinates.count > 1, geometry.totalDistance > 0 else { throw RouteLocationError.emptyGeometry }
            let now = Date()
            let existing = asCopy ? nil : savedRoutes.first { $0.id == loadedRouteID }
            let trimmedName = (requestedName ?? routeName).trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = trimmedName.isEmpty ? L10n.text("未命名路線") : trimmedName
            let route = SavedRoute(
                id: existing?.id ?? UUID(), name: finalName,
                waypoints: waypoints, resolvedGeometry: geometry, routeMode: routeMode,
                navigationTransportMode: navigationTransport, isClosedLoop: isClosedLoop,
                preferredSpeedKmh: speedKmh, playbackMode: playbackMode,
                navigationGeometryNeedsRecalculation: false, isFavorite: existing?.isFavorite ?? false,
                createdAt: existing?.createdAt ?? now, updatedAt: now
            )
            try await persistence.saveRoute(route)
            loadedRouteID = route.id
            routeName = finalName
            await reloadRoutes()
            statusMessage = L10n.text("路線已儲存，可離線播放。")
        } catch { presentedError = error.localizedDescription }
    }

    func renameRoute(_ route: SavedRoute, to requestedName: String) async {
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

    func canEditRoute(_ route: SavedRoute? = nil) -> Bool {
        guard isAnyRouteActive else { return true }
        if let route, let loadedRouteID, route.id == loadedRouteID {
            return true
        }
        return false
    }

    func requestEditRoute(_ route: SavedRoute) -> Bool {
        if !canEditRoute(route) {
            presentedError = L10n.text("目前正在執行路線，請先結束目前路線後再編輯其他路線。")
            return false
        }
        loadRoute(route)
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
        navigationResolver.cancel()
        loadedRouteID = route.id
        routeName = route.name
        waypoints = route.waypoints
        routeMode = route.routeMode
        navigationTransport = route.navigationTransportMode
        isClosedLoop = route.isClosedLoop
        speedKmh = route.preferredSpeedKmh
        playbackMode = route.playbackMode
        geometry = route.resolvedGeometry
        navigationGeometryNeedsRecalculation = route.navigationGeometryNeedsRecalculation
        statusMessage = L10n.text("已載入快取路線，沒有重新計算導航。")
    }

    func previewRoute(_ route: SavedRoute) {
        previewingRoute = route
        mapFocusRevision = UUID()
    }

    func cancelRoutePreview() {
        previewingRoute = nil
        mapFocusRevision = UUID()
    }

    func requestStartRoute(_ route: SavedRoute) {
        if playback.state == .running || playback.state == .paused || playback.state == .reconnecting {
            if playback.routeName == route.name && loadedRouteID == route.id {
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
        previewingRoute = nil
        loadRoute(route)
        await markRouteUsed(id: route.id)
        await startPlayback()
    }

    func confirmSwitchToRoute(_ route: SavedRoute) async {
        showActiveRouteSwitchAlert = false
        pendingSwitchRoute = nil
        playback.stop(clearMarker: false)
        previewingRoute = nil
        loadRoute(route)
        await markRouteUsed(id: route.id)
        await startPlayback()
        statusMessage = L10n.format("已切換至路線「%@」。", route.name)
    }

    func markRouteUsed(id: UUID) async {
        guard let index = savedRoutes.firstIndex(where: { $0.id == id }) else { return }
        var updated = savedRoutes[index]
        updated.lastUsedAt = Date()
        savedRoutes[index] = updated
        try? await persistence.saveRoute(updated)
    }

    func deleteRoute(_ route: SavedRoute) async {
        do {
            try await persistence.deleteRoute(id: route.id)
            if loadedRouteID == route.id { loadedRouteID = nil }
            await reloadRoutes()
        } catch { presentedError = L10n.format("無法刪除路線：%@", error.localizedDescription) }
    }

    func addFavorite(name: String, note: String? = nil, coordinate: RouteCoordinate? = nil) async {
        guard let coordinate = coordinate ?? selectedCoordinate, coordinate.isValid else { presentedError = L10n.text("請先選擇有效座標。"); return }
        let value = FavoriteLocation(name: name.isEmpty ? L10n.text("喜愛地點") : name, coordinate: coordinate, note: note)
        favorites.append(value)
        await saveFavorites()
    }

    func updateFavorite(_ favorite: FavoriteLocation, name: String, note: String?) async {
        guard let index = favorites.firstIndex(where: { $0.id == favorite.id }) else { return }
        favorites[index].name = name
        favorites[index].note = note
        favorites[index].updatedAt = .now
        await saveFavorites()
    }

    func deleteFavorites(at offsets: IndexSet) async {
        favorites.remove(atOffsets: offsets)
        await saveFavorites()
    }

    var isCellularBootstrapPreparationNeeded: Bool {
        let policy = ShortcutBootstrapService.shared.cellularBootstrapPolicy
        if policy == .directOnly { return false }
        let hasActiveDVT = connectionMonitor.activeDVTSessionAvailable || LocationDataPathHealth.shared.hasRecentSuccess
        guard !hasActiveDVT else { return false }
        guard connectionMonitor.currentTransport != .wifi else { return false }
        if policy == .assistedFirst {
            return connectionMonitor.currentTransport == .cellular
        }
        return connectionMonitor.currentTransport == .cellular && !TunnelManager.shared.bootstrapAvailable
    }

    func requestBootstrapIfCellular(action: @escaping @MainActor () -> Void) {
        if isCellularBootstrapPreparationNeeded {
            pendingBootstrapAction = action
            TunnelManager.shared.cellularBootstrapRequested = true
            showBootstrapPreflightSheet = true
        } else {
            action()
        }
    }

    func confirmBootstrapPreflightRecheck() {
        showBootstrapPreflightSheet = false
        TunnelManager.shared.cellularBootstrapRequested = true
        if let action = pendingBootstrapAction {
            pendingBootstrapAction = nil
            action()
        }
    }

    func confirmBootstrapPreflightForce() {
        showBootstrapPreflightSheet = false
        TunnelManager.shared.cellularBootstrapRequested = true
        if let action = pendingBootstrapAction {
            pendingBootstrapAction = nil
            action()
        }
    }

    func cancelBootstrapPreflight() {
        showBootstrapPreflightSheet = false
        pendingBootstrapAction = nil
        TunnelManager.shared.cellularBootstrapRequested = false
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
        requestBootstrapIfCellular { [weak self] in
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
                do {
                    try await self.simulationService.setCoordinate(target)
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
        playback.stop(clearMarker: false)
        do {
            try await setCoordinateWithBoundedRecovery(target)
            startSinglePointHold(at: target)
            statusMessage = L10n.text("已成功模擬所選位置。")
        } catch {
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
        if isCellularBootstrapPreparationNeeded {
            requestBootstrapIfCellular { [weak self] in
                guard let self else { return }
                Task { await self.startPlayback() }
            }
            return
        }
        teleportTask?.cancel()
        teleportTask = nil
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
            playback.stop(clearMarker: false)
            simulationMode = .idle
            return
        }
        playback.stop(clearMarker: false)
        startSinglePointHold(at: lastCoord)
        showEndRouteOptions = true
        statusMessage = L10n.text("路線已結束，目前位置仍為模擬位置。")
    }

    func returnToRealLocation() async {
        teleportTask?.cancel()
        teleportTask = nil
        playback.stop(clearMarker: true)
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
            connectionMonitor.reportSession(.idle)
            LocationSessionCoordinator.shared.endSession()
            simulationMode = .idle
            statusMessage = L10n.text("已恢復裝置的真實位置。")
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
        guard !waypoints.isEmpty else { geometry = RouteGeometry(coordinates: []); navigationGeometryNeedsRecalculation = routeMode == .navigation; return }
        if routeMode == .straight {
            geometry = RouteBuilder.straightGeometry(waypoints: waypoints, closedLoop: isClosedLoop)
            navigationGeometryNeedsRecalculation = false
        } else {
            navigationGeometryNeedsRecalculation = true
        }
    }

    private func setCoordinateWithBoundedRecovery(_ coordinate: RouteCoordinate) async throws {
        let delays: [TimeInterval] = [0, 0.5, 1, 2]
        var lastError: Error?
        for (index, delay) in delays.enumerated() {
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) } catch { throw error }
            }
            do {
                try await simulationService.setCoordinate(coordinate)
                return
            } catch {
                lastError = error
                TunnelManager.shared.reportLocationFailure(error, transport: connectionMonitor.currentTransport)
                guard PlaybackReconnectPolicy.shouldRetry(error) else { throw error }
                connectionMonitor.reportSession(.reconnecting(attempt: index + 1))
                markTunnelDisconnected()
                startTunnelInBackground(showErrorUI: false)
            }
        }
        throw lastError ?? LocationSimulationError.deviceTunnelUnavailable
    }

    private func loadPersistedData() async {
        do {
            async let loadedFavorites = persistence.loadFavorites()
            async let loadedRoutes = persistence.loadRoutes()
            favorites = try await loadedFavorites
            savedRoutes = try await loadedRoutes
            let legacyRoutes = savedRoutes.filter { $0.name == "New Route" }
            for route in legacyRoutes {
                var updated = route
                updated.name = L10n.text("新路線")
                try await persistence.saveRoute(updated)
            }
            if !legacyRoutes.isEmpty { savedRoutes = try await persistence.loadRoutes() }
        } catch { presentedError = L10n.format("無法載入已儲存資料：%@", error.localizedDescription) }
    }

    private func reloadRoutes() async {
        do { savedRoutes = try await persistence.loadRoutes() }
        catch { presentedError = error.localizedDescription }
    }

    private func saveFavorites() async {
        do {
            try await persistence.saveFavorites(favorites)
            favorites.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch { presentedError = L10n.format("無法儲存喜愛地點：%@", error.localizedDescription) }
    }
}
