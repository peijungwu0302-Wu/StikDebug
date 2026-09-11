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
    private static let speedKey = "RouteLocation.lastSpeedKmh"

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
        playback = RoutePlaybackEngine(sink: simulationService, connectionMonitor: connectionMonitor)
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

    func clearCurrentRoute() {
        navigationResolver.cancel()
        playback.stop(clearMarker: true)
        loadedRouteID = nil
        routeName = L10n.text("新路線")
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

    func teleport(to coordinate: RouteCoordinate? = nil) async {
        guard let target = coordinate ?? selectedCoordinate else { presentedError = L10n.text("請先選擇座標。"); return }
        playback.stop()
        teleportTask?.cancel()
        do {
            try await simulationService.setCoordinate(target)
            selectedCoordinate = target
            connectionMonitor.reportSession(.connected)
            BackgroundKeepAliveService.shared.acquire()
            teleportTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    guard let self else { return }
                    do { try await self.simulationService.setCoordinate(target) }
                    catch { self.presentedError = error.localizedDescription; self.connectionMonitor.reportSession(.error(error.localizedDescription)) }
                }
            }
        } catch { presentedError = error.localizedDescription }
    }

    func startPlayback() async {
        teleportTask?.cancel()
        teleportTask = nil
        do {
            if playbackMode == .infiniteLoop, !isClosedLoop { throw RouteLocationError.loopRequiresClosedRoute }
            if routeMode == .navigation, navigationGeometryNeedsRecalculation { throw RouteLocationError.navigationNeedsRecalculation }
            try await playback.start(routeName: routeName, geometry: geometry, speedKmh: speedKmh, mode: playbackMode)
        } catch { presentedError = error.localizedDescription }
    }

    func returnToRealLocation() async {
        teleportTask?.cancel()
        teleportTask = nil
        playback.stop()
        do {
            try await simulationService.clearSimulatedLocation()
            BackgroundKeepAliveService.shared.release()
            connectionMonitor.reportSession(.idle)
            statusMessage = L10n.text("已恢復裝置的真實位置。")
        } catch { presentedError = error.localizedDescription }
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
