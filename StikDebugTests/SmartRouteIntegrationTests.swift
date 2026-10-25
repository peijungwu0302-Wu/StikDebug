import Foundation
import Testing
@testable import RouteLocation

@MainActor
struct SmartRouteIntegrationTests {
    private func candidate() throws -> SmartRouteCandidate {
        let a = RouteCoordinate(latitude: 25, longitude: 121)
        let b = RouteCoordinate(latitude: 25, longitude: 121.01)
        let c = RouteCoordinate(latitude: 25.01, longitude: 121.01)
        let d = RouteCoordinate(latitude: 25.01, longitude: 121)
        return try .make(geometry: RouteGeometry(coordinates: [a, b, c, d, a]), options: .init(targetDistance: 4_200), kind: .loop)
    }

    @Test func applyingCandidatePreservesRoadsAndEditsInvalidateGeometry() throws {
        let model = RouteLocationModel()
        let value = try candidate()
        model.requestApplySmartRoute(value.savedRoute(name: "Road", speedKmh: 18.6, playbackMode: .infiniteLoop))
        #expect(model.simulationMode == .idle)
        #expect(model.geometry == value.geometry)
        #expect(model.routeMode == .navigation)
        #expect(!model.navigationGeometryNeedsRecalculation)
        #expect(model.quickRouteMode == .route)
        #expect(!model.hasLoadedRoute)
        model.updateWaypoint(at: 1, latitude: 25.001, longitude: 121.01)
        #expect(model.navigationGeometryNeedsRecalculation)
    }

    @Test func applyConflictCancelAndDiscardDoNotStartSimulation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = RouteLocationModel(persistence: RoutePersistenceStore(rootURL: root))
        let original = [RouteCoordinate(latitude: 35, longitude: 139), RouteCoordinate(latitude: 35.01, longitude: 139.01)]
        model.replaceWaypoints(original)
        let value = try candidate()
        let route = value.savedRoute(name: "Candidate", speedKmh: 18.6, playbackMode: .infiniteLoop)
        model.requestApplySmartRoute(route)
        #expect(model.showSavedRouteDraftConflict)
        #expect(model.isApplyingSmartRouteDraft)
        #expect(model.waypoints == original)
        model.cancelSavedRouteDraftConflict()
        #expect(model.waypoints == original)
        model.requestApplySmartRoute(route)
        await model.resolveSavedRouteDraftConflict(saveDraft: false)
        #expect(model.geometry == value.geometry)
        #expect(model.simulationMode == .idle)
        #expect(!model.showSavedRouteDraftConflict)
    }

    @Test func changedTransportBlocksSavingAndStartingStaleRoadGeometry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutePersistenceStore(rootURL: root)
        let sink = SmartRouteIntegrationSink()
        let model = RouteLocationModel(persistence: store, simulationService: sink)
        let value = try candidate()
        model.requestApplySmartRoute(value.savedRoute(name: "Road", speedKmh: 18.6, playbackMode: .infiniteLoop))
        model.navigationTransport = .automobile
        #expect(model.navigationGeometryNeedsRecalculation)
        #expect(!(await model.saveCurrentRoute(named: "Stale")))
        #expect(try await store.loadRoutes().isEmpty)
        await model.startPlayback()
        #expect(model.simulationMode == .idle)
        #expect(model.presentedError != nil)
        #expect(await sink.writes == 0)
    }

    @Test func savingCandidateFavoritePersistsWithoutOverwritingDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutePersistenceStore(rootURL: root)
        let model = RouteLocationModel(persistence: store)
        let original = [RouteCoordinate(latitude: 35, longitude: 139), RouteCoordinate(latitude: 35.01, longitude: 139.01)]
        model.replaceWaypoints(original)
        let value = try candidate()
        let saved = try #require(await model.saveSmartRouteCandidate(value, named: "Favorite", speedKmh: 18.6, playbackMode: .finite(3), favorite: true))
        #expect(saved.isFavorite)
        #expect(saved.playbackMode == .finite(3))
        #expect(model.waypoints == original)
        #expect(model.simulationMode == .idle)
        let reloaded = try await store.loadRoutes()
        #expect(reloaded.first(where: { $0.id == saved.id })?.resolvedGeometry == value.geometry)
        #expect(reloaded.first(where: { $0.id == saved.id })?.isFavorite == true)
    }

    @Test func failedCandidateFavoriteCreatesNoPublishedRoute() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent(ProductIdentity.supportDirectoryName)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: support.appendingPathComponent("routes"))
        let model = RouteLocationModel(persistence: RoutePersistenceStore(rootURL: root))
        let saved = await model.saveSmartRouteCandidate(try candidate(), named: "No", speedKmh: 18.6, playbackMode: .infiniteLoop, favorite: true)
        #expect(saved == nil)
        #expect(model.savedRoutes.isEmpty)
        #expect(model.simulationMode == .idle)
        #expect(model.waypoints.isEmpty)
    }

    @Test func activeRouteRejectsCandidateApplication() throws {
        let model = RouteLocationModel()
        model.replaceWaypoints([RouteCoordinate(latitude: 35, longitude: 139), RouteCoordinate(latitude: 35.01, longitude: 139.01)])
        let original = model.waypoints
        model.testSetSimulationModeForTesting(.routePaused)
        model.requestApplySmartRoute(try candidate().savedRoute(name: "No", speedKmh: 18.6, playbackMode: .infiniteLoop))
        #expect(model.waypoints == original)
        #expect(!model.showSavedRouteDraftConflict)
        #expect(model.simulationMode == .routePaused)
    }

    @Test func saveDraftThenApplyPreservesOldDraftOnDiskWithoutPlaying() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutePersistenceStore(rootURL: root)
        let model = RouteLocationModel(persistence: store)
        let original = [RouteCoordinate(latitude: 35, longitude: 139), RouteCoordinate(latitude: 35.01, longitude: 139.01)]
        model.replaceWaypoints(original)
        let value = try candidate()
        model.requestApplySmartRoute(value.savedRoute(name: "New", speedKmh: 18.6, playbackMode: .infiniteLoop))
        await model.resolveSavedRouteDraftConflict(saveDraft: true)
        let persisted = try await store.loadRoutes()
        #expect(persisted.count == 1)
        #expect(persisted.first?.waypoints == original)
        #expect(model.geometry == value.geometry)
        #expect(model.simulationMode == .idle)
    }

    @Test func failedDraftSaveDoesNotApplyCandidate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent(ProductIdentity.supportDirectoryName)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: support.appendingPathComponent("routes"))
        let model = RouteLocationModel(persistence: RoutePersistenceStore(rootURL: root))
        let original = [RouteCoordinate(latitude: 35, longitude: 139), RouteCoordinate(latitude: 35.01, longitude: 139.01)]
        model.replaceWaypoints(original)
        let geometry = model.geometry
        model.requestApplySmartRoute(try candidate().savedRoute(name: "No", speedKmh: 18.6, playbackMode: .infiniteLoop))
        await model.resolveSavedRouteDraftConflict(saveDraft: true)
        #expect(model.waypoints == original)
        #expect(model.geometry == geometry)
        #expect(model.savedRoutes.isEmpty)
        #expect(model.simulationMode == .idle)
    }
}

private actor SmartRouteIntegrationSink: LocationSimulationSink {
    var writes = 0
    func setCoordinate(_ coordinate: RouteCoordinate) async throws { writes += 1 }
    func clearSimulatedLocation() async throws { Issue.record("A stale route must not restore location") }
}
