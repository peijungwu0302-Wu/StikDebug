import CoreLocation
import Foundation
import SwiftUI

@MainActor
final class RouteLocationModel: ObservableObject {
    @Published var selectedCoordinate: RouteCoordinate?
    @Published var waypoints: [RouteCoordinate] = []
    @Published var routeName = "新路線"
    @Published var routeMode: RouteMode = .straight { didSet { routeInputsChanged() } }
    @Published var navigationTransport: NavigationTransportMode = .automobile { didSet { routeInputsChanged() } }
    @Published var isClosedLoop = false { didSet { routeInputsChanged() } }
    @Published var playbackMode: RoutePlaybackMode = .once
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

    let playback: RoutePlaybackEngine
    let connectionMonitor: ConnectionMonitor
    private let persistence: RoutePersistenceStore
    private let navigationResolver = NavigationRouteResolver()
    private let simulationService: any LocationSimulationSink
    private var teleportTask: Task<Void, Never>?
    private var loadedRouteID: UUID?
    private static let speedKey = "RouteLocation.lastSpeedKmh"

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

    func recalculateNavigation() async {
        guard !isResolvingNavigation else { return }
        isResolvingNavigation = true
        defer { isResolvingNavigation = false }
        do {
            let resolved = try await navigationResolver.resolve(waypoints: waypoints, closedLoop: isClosedLoop, transport: navigationTransport)
            geometry = resolved
            navigationGeometryNeedsRecalculation = false
            statusMessage = "導航路線已計算完成，可以儲存。"
        } catch is CancellationError {
            return
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func saveCurrentRoute() async {
        do {
            guard waypoints.count >= 2 else { throw RouteLocationError.insufficientWaypoints }
            if routeMode == .navigation, navigationGeometryNeedsRecalculation { throw RouteLocationError.navigationNeedsRecalculation }
            guard geometry.coordinates.count > 1, geometry.totalDistance > 0 else { throw RouteLocationError.emptyGeometry }
            let now = Date()
            let existing = savedRoutes.first { $0.id == loadedRouteID }
            let route = SavedRoute(
                id: existing?.id ?? UUID(), name: routeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名路線" : routeName,
                waypoints: waypoints, resolvedGeometry: geometry, routeMode: routeMode,
                navigationTransportMode: navigationTransport, isClosedLoop: isClosedLoop,
                preferredSpeedKmh: speedKmh, playbackMode: playbackMode,
                navigationGeometryNeedsRecalculation: false, createdAt: existing?.createdAt ?? now, updatedAt: now
            )
            try await persistence.saveRoute(route)
            loadedRouteID = route.id
            await reloadRoutes()
            statusMessage = "路線已儲存，可離線播放。"
        } catch { presentedError = error.localizedDescription }
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
        statusMessage = "已載入快取路線，沒有重新計算導航。"
    }

    func deleteRoute(_ route: SavedRoute) async {
        do {
            try await persistence.deleteRoute(id: route.id)
            if loadedRouteID == route.id { loadedRouteID = nil }
            await reloadRoutes()
        } catch { presentedError = "無法刪除路線：\(error.localizedDescription)" }
    }

    func addFavorite(name: String, note: String? = nil, coordinate: RouteCoordinate? = nil) async {
        guard let coordinate = coordinate ?? selectedCoordinate, coordinate.isValid else { presentedError = "請先選擇有效座標。"; return }
        let value = FavoriteLocation(name: name.isEmpty ? "喜好地點" : name, coordinate: coordinate, note: note)
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
        guard let target = coordinate ?? selectedCoordinate else { presentedError = "請先選擇座標。"; return }
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
            statusMessage = "已恢復裝置的真實位置。"
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
        } catch { presentedError = "無法載入已儲存資料：\(error.localizedDescription)" }
    }

    private func reloadRoutes() async {
        do { savedRoutes = try await persistence.loadRoutes() }
        catch { presentedError = error.localizedDescription }
    }

    private func saveFavorites() async {
        do {
            try await persistence.saveFavorites(favorites)
            favorites.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch { presentedError = "無法儲存喜好地點：\(error.localizedDescription)" }
    }
}
