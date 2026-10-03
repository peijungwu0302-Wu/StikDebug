import Foundation
import Testing
@testable import RouteLocation

private func reliabilityRoute() -> SavedRoute {
    let points = [RouteCoordinate(latitude: 25, longitude: 121), RouteCoordinate(latitude: 25.01, longitude: 121.01)]
    return SavedRoute(name: "Preserved route", waypoints: points, resolvedGeometry: RouteGeometry(coordinates: points), routeMode: .straight, isClosedLoop: false, preferredSpeedKmh: 18.6, playbackMode: .once)
}

private struct ReliabilityLibrary {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var root: URL { directory.appendingPathComponent(ProductIdentity.supportDirectoryName) }
    var store: RoutePersistenceStore { RoutePersistenceStore(rootURL: directory) }

    func writeCorruptFile(_ path: String) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("corrupt original must survive".utf8).write(to: file)
        return file
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

struct V1_2_21PersistenceTests {
    @Test func failedLibrariesRetryIndependentlyWithoutReloadingHealthyCollections() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let store = library.store
        _ = try await store.loadFavorites()
        _ = try await store.loadRoutes()
        let recentFile = try library.writeCorruptFile("recent-locations.json")
        await #expect(throws: (any Error).self) { try await store.loadRecentLocations() }
        let failed = await store.retryFailedLibraries()
        #expect(failed.recents == nil)
        await #expect(throws: (any Error).self) { try await store.saveRecentLocations([]) }
        // A healthy collection is not read again, even if its file changes.
        _ = try library.writeCorruptFile("locations.json")
        try Data("[]".utf8).write(to: recentFile)
        let recovered = await store.retryFailedLibraries()
        #expect(recovered.recents == [])
        #expect(recovered.favorites == nil)
        #expect(recovered.routes == nil)
        try await store.saveRecentLocations([])
        let noFailures = await store.retryFailedLibraries()
        #expect(noFailures.recents == nil)
    }

    @Test func temporaryUnavailableFavoriteFileUnlocksOnlyAfterSuccessfulRetry() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let file = library.root.appendingPathComponent("locations.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let store = library.store
        await #expect(throws: (any Error).self) { try await store.loadFavorites() }
        _ = await store.retryFailedLibraries()
        await #expect(throws: (any Error).self) { try await store.saveFavorites([]) }
        try FileManager.default.removeItem(at: file)
        try Data("[]".utf8).write(to: file)
        let recovered = await store.retryFailedLibraries()
        #expect(recovered.favorites == [])
        try await store.saveFavorites([])
    }
    @Test func failedFavoriteLoadPreventsOverwritingOriginal() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let file = try library.writeCorruptFile("locations.json")
        let original = try Data(contentsOf: file)
        let store = library.store
        await #expect(throws: (any Error).self) { try await store.loadFavorites() }
        await #expect(throws: (any Error).self) { try await store.saveFavorites([]) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func firstFavoriteWriteChecksExistingUnreadableLibrary() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let file = try library.writeCorruptFile("locations.json")
        let original = try Data(contentsOf: file)
        let store = library.store
        await #expect(throws: (any Error).self) { try await store.saveFavorites([]) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func invalidFavoriteCoordinatesPreserveOriginalLibrary() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let file = try library.writeCorruptFile("locations.json")
        let invalid = FavoriteLocation(name: "Invalid", coordinate: RouteCoordinate(latitude: 91, longitude: 121))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let original = try encoder.encode([invalid])
        try original.write(to: file)
        let store = library.store
        await #expect(throws: (any Error).self) { try await store.loadFavorites() }
        await #expect(throws: (any Error).self) { try await store.saveFavorites([]) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func failedRecentLoadPreventsClearingOriginal() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let file = try library.writeCorruptFile("recent-locations.json")
        let original = try Data(contentsOf: file)
        let store = library.store
        await #expect(throws: (any Error).self) { try await store.loadRecentLocations() }
        await #expect(throws: (any Error).self) { try await store.saveRecentLocations([]) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func firstRecentWriteChecksExistingUnreadableLibrary() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let file = try library.writeCorruptFile("recent-locations.json")
        let original = try Data(contentsOf: file)
        let store = library.store
        await #expect(throws: (any Error).self) { try await store.saveRecentLocations([]) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func failedRouteLoadBlocksBothSaveAndDelete() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let route = reliabilityRoute()
        let file = try library.writeCorruptFile("routes/\(route.id.uuidString).json")
        let original = try Data(contentsOf: file)
        let store = library.store
        await #expect(throws: (any Error).self) { try await store.loadRoutes() }
        await #expect(throws: (any Error).self) { try await store.saveRoute(route) }
        await #expect(throws: (any Error).self) { try await store.deleteRoute(id: route.id) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func firstRouteDeleteChecksExistingUnreadableLibrary() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let route = reliabilityRoute()
        let file = try library.writeCorruptFile("routes/\(route.id.uuidString).json")
        let original = try Data(contentsOf: file)
        let store = library.store
        await #expect(throws: (any Error).self) { try await store.deleteRoute(id: route.id) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func firstRouteWriteChecksExistingUnreadableLibrary() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let route = reliabilityRoute()
        let file = try library.writeCorruptFile("routes/\(route.id.uuidString).json")
        let original = try Data(contentsOf: file)
        let store = library.store
        await #expect(throws: (any Error).self) { try await store.saveRoute(route) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func successfulReloadUnlocksRepairedLibrary() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let file = try library.writeCorruptFile("locations.json")
        let store = library.store
        await #expect(throws: (any Error).self) { try await store.loadFavorites() }
        try Data("[]".utf8).write(to: file)
        _ = try await store.loadFavorites()
        let favorite = FavoriteLocation(name: "Recovered", coordinate: RouteCoordinate(latitude: 25, longitude: 121))
        try await store.saveFavorites([favorite])
        let loaded = try await store.loadFavorites()
        #expect(loaded.map(\.id) == [favorite.id])
    }
}

@Suite(.serialized)
@MainActor
struct V1_2_21LibraryModelTests {
    init() { TestBootstrapEnvironment.reset() }

    @Test(arguments: ["add", "addIfNeeded", "update", "delete", "move", "manual", "used"])
    func failedFavoriteWriteNeverPublishesCandidate(operation: String) async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let store = library.store
        let first = FavoriteLocation(name: "First", coordinate: RouteCoordinate(latitude: 25, longitude: 121))
        let second = FavoriteLocation(name: "Second", coordinate: RouteCoordinate(latitude: 26, longitude: 122))
        try await store.saveFavorites([first, second])
        let model = RouteLocationModel(persistence: store, simulationService: ReliabilityNoopSink())
        await model.recordRecent(coordinate: first.coordinate)
        let snapshot = model.favorites
        let order = model.manualFavoriteOrder
        let file = library.root.appendingPathComponent("locations.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        switch operation {
        case "add": await model.addFavorite(name: "Third", coordinate: first.coordinate)
        case "addIfNeeded": await model.addFavoriteIfNeeded(name: "Third", coordinate: first.coordinate)
        case "update": await model.updateFavorite(first, name: "Changed", note: nil)
        case "delete": await model.deleteFavorites(at: IndexSet(integer: 0))
        case "move": await model.moveFavorites(from: IndexSet(integer: 0), to: 2)
        case "manual": await model.setManualFavoriteOrder([second.id, first.id])
        case "used": await model.markFavoriteUsed(first)
        default: Issue.record("Unexpected mutation")
        }
        #expect(model.favorites == snapshot)
        #expect(model.manualFavoriteOrder == order)
        #expect(model.presentedError != nil)
    }

    @Test func concurrentFavoriteCandidatesPreserveEveryCommittedAddition() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let store = library.store
        let model = RouteLocationModel(persistence: store, simulationService: ReliabilityNoopSink())
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask { await model.addFavorite(name: "Item \(index)", coordinate: RouteCoordinate(latitude: 25, longitude: 121)) }
            }
        }
        #expect(model.favorites.count == 12)
        #expect(Set(model.favorites.map(\.name)).count == 12)
        let persisted = try await store.loadFavorites()
        #expect(Set(persisted.map(\.id)) == Set(model.favorites.map(\.id)))
    }

    @Test func cancelledFavoriteRequestDoesNotBlockLaterMutations() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let model = RouteLocationModel(persistence: library.store, simulationService: ReliabilityNoopSink())
        let cancelled = Task { await model.addFavorite(name: "Cancelled", coordinate: RouteCoordinate(latitude: 25, longitude: 121)) }
        cancelled.cancel()
        await cancelled.value
        await model.addFavorite(name: "Kept", coordinate: RouteCoordinate(latitude: 25, longitude: 121))
        #expect(model.favorites.map(\.name) == ["Kept"])
    }

    @Test func lifecycleRecoveryPublishesOnlyRecoveredLibrary() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let file = try library.writeCorruptFile("locations.json")
        let model = RouteLocationModel(persistence: library.store, simulationService: ReliabilityNoopSink())
        let point = RouteCoordinate(latitude: 25, longitude: 121)
        await model.recordRecent(coordinate: point)
        let recentIDs = model.recentLocations.map(\.id)
        try Data("[]".utf8).write(to: file)
        await model.retryFailedPersistenceLoads()
        await model.addFavorite(name: "Recovered", coordinate: point)
        #expect(model.favorites.map(\.name) == ["Recovered"])
        #expect(model.recentLocations.map(\.id) == recentIDs)
    }

    @Test(arguments: ["record", "delete", "clear"])
    func recentMutationWaitsForRecoveredSnapshotPublication(operation: String) async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let store = library.store
        let old = RecentLocation(coordinate: RouteCoordinate(latitude: 25, longitude: 121), title: "Old", kind: "simulate")
        let preserved = RecentLocation(coordinate: RouteCoordinate(latitude: 26, longitude: 122), title: "Preserved", kind: "simulate")
        try await store.saveRecentLocations([old, preserved])
        let file = library.root.appendingPathComponent("recent-locations.json")
        let original = try Data(contentsOf: file)
        _ = try library.writeCorruptFile("recent-locations.json")
        let model = RouteLocationModel(persistence: store, simulationService: ReliabilityNoopSink())
        await model.retryFailedPersistenceLoads()
        #expect(model.recentLocations.isEmpty)
        try original.write(to: file)

        let barrier = ReliabilitySuspendingSink()
        try await barrier.setCoordinate(old.coordinate)
        model.testBeforeRecoveredLibrariesPublish = { try? await barrier.setCoordinate(old.coordinate) }
        let (queuedEvents, queuedSignal) = AsyncStream<Void>.makeStream()
        model.testPersistenceMutationQueued = { queuedSignal.yield(()); queuedSignal.finish() }
        let recovery = Task { await model.retryFailedPersistenceLoads() }
        try await barrier.waitForSuspendedCommand()
        let mutation = Task {
            switch operation {
            case "record": await model.recordRecent(coordinate: RouteCoordinate(latitude: 27, longitude: 123), title: "New")
            case "delete": await model.deleteRecentLocation(old)
            default: await model.clearRecentLocations()
            }
        }
        do { try await waitForReliabilityEvent(queuedEvents) }
        catch {
            await barrier.finishCommand(failing: false)
            await recovery.value
            await mutation.value
            throw error
        }
        #expect(model.recentLocations.isEmpty)
        await barrier.finishCommand(failing: false)
        await recovery.value
        await mutation.value
        let disk = try await store.loadRecentLocations()
        #expect(disk.map(\.id) == model.recentLocations.map(\.id))
        switch operation {
        case "record":
            #expect(disk.count == 3)
            #expect(disk.contains { $0.id == old.id })
            #expect(disk.contains { $0.id == preserved.id })
        case "delete": #expect(disk.map(\.id) == [preserved.id])
        default: #expect(disk.isEmpty)
        }
    }

    @Test func routeMutationWaitsForRecoveredRoutePublication() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let store = library.store
        let route = reliabilityRoute()
        try await store.saveRoute(route)
        let file = library.root.appendingPathComponent("routes/\(route.id.uuidString).json")
        let original = try Data(contentsOf: file)
        _ = try library.writeCorruptFile("routes/\(route.id.uuidString).json")
        let model = RouteLocationModel(persistence: store, simulationService: ReliabilityNoopSink())
        await model.retryFailedPersistenceLoads()
        #expect(model.savedRoutes.isEmpty)
        try original.write(to: file)
        let barrier = ReliabilitySuspendingSink()
        try await barrier.setCoordinate(route.waypoints[0])
        model.testBeforeRecoveredLibrariesPublish = { try? await barrier.setCoordinate(route.waypoints[0]) }
        let (queuedEvents, queuedSignal) = AsyncStream<Void>.makeStream()
        model.testPersistenceMutationQueued = { queuedSignal.yield(()); queuedSignal.finish() }
        let recovery = Task { await model.retryFailedPersistenceLoads() }
        try await barrier.waitForSuspendedCommand()
        let mutation = Task { await model.renameRoute(route, to: "Recovered rename") }
        do { try await waitForReliabilityEvent(queuedEvents) }
        catch {
            await barrier.finishCommand(failing: false)
            await recovery.value
            await mutation.value
            throw error
        }
        await barrier.finishCommand(failing: false)
        await recovery.value
        await mutation.value
        #expect(model.savedRoutes.first?.name == "Recovered rename")
        #expect(try await store.loadRoutes().first?.name == "Recovered rename")
    }

    @Test func corruptFavoritesRejectAdditionWithoutPhantomOrSuccessToast() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let file = try library.writeCorruptFile("locations.json")
        let original = try Data(contentsOf: file)
        let model = RouteLocationModel(persistence: library.store, simulationService: ReliabilityNoopSink())
        let name = UUID().uuidString
        await model.addFavorite(name: name, coordinate: RouteCoordinate(latitude: 25, longitude: 121))
        #expect(model.favorites.isEmpty)
        #expect(model.presentedError != nil)
        #expect(ToastManager.shared.current?.text != L10n.format("已收藏「%@」", name))
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func favoriteDeletionIgnoresStaleOutOfBoundsOffsets() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let store = library.store
        let first = FavoriteLocation(name: "First", coordinate: RouteCoordinate(latitude: 25, longitude: 121))
        let second = FavoriteLocation(name: "Second", coordinate: RouteCoordinate(latitude: 26, longitude: 122))
        try await store.saveFavorites([first, second])
        let model = RouteLocationModel(persistence: store, simulationService: ReliabilityNoopSink())
        await model.recordRecent(coordinate: first.coordinate)
        await model.deleteFavorites(at: IndexSet([0, 20]))
        #expect(model.favorites.map(\.id) == [second.id])
        let saved = try await store.loadFavorites()
        #expect(saved.map(\.id) == [second.id])
    }

    @Test func favoriteMoveIgnoresInvalidOffsetsAndRejectsInvalidDestination() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let store = library.store
        let first = FavoriteLocation(name: "First", coordinate: RouteCoordinate(latitude: 25, longitude: 121))
        let second = FavoriteLocation(name: "Second", coordinate: RouteCoordinate(latitude: 26, longitude: 122))
        try await store.saveFavorites([first, second])
        let model = RouteLocationModel(persistence: store, simulationService: ReliabilityNoopSink())
        await model.recordRecent(coordinate: first.coordinate)
        await model.moveFavorites(from: IndexSet([0, 20]), to: 2)
        #expect(model.favorites.map(\.id) == [second.id, first.id])
        await model.moveFavorites(from: IndexSet(integer: 0), to: 20)
        #expect(model.favorites.map(\.id) == [second.id, first.id])
    }

    @Test(arguments: ["add", "addIfNeeded", "move", "update", "used", "delete"])
    func blockedFavoriteLibraryRejectsMutationsBeforeMemoryChanges(operation: String) async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let store = library.store
        let first = FavoriteLocation(name: "First", coordinate: RouteCoordinate(latitude: 25, longitude: 121))
        let second = FavoriteLocation(name: "Second", coordinate: RouteCoordinate(latitude: 26, longitude: 122))
        try await store.saveFavorites([first, second])
        let model = RouteLocationModel(persistence: store, simulationService: ReliabilityNoopSink())
        await model.recordRecent(coordinate: first.coordinate)
        let snapshot = model.favorites
        let file = try library.writeCorruptFile("locations.json")
        let original = try Data(contentsOf: file)
        await #expect(throws: (any Error).self) { try await store.loadFavorites() }
        switch operation {
        case "add": await model.addFavorite(name: "Third", coordinate: RouteCoordinate(latitude: 27, longitude: 123))
        case "addIfNeeded": await model.addFavoriteIfNeeded(name: "First", coordinate: first.coordinate)
        case "move": await model.moveFavorites(from: IndexSet(integer: 0), to: 2)
        case "update": await model.updateFavorite(first, name: "Changed", note: "Changed")
        case "used": await model.markFavoriteUsed(first)
        case "delete": await model.deleteFavorites(at: IndexSet(integer: 0))
        default: Issue.record("Unexpected mutation")
        }
        #expect(model.favorites == snapshot)
        #expect(model.presentedError != nil)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func corruptRouteDoesNotEraseHealthyRecentHistory() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let store = library.store
        let old = RecentLocation(coordinate: RouteCoordinate(latitude: 25, longitude: 121), title: "Existing", kind: "simulate")
        try await store.saveRecentLocations([old])
        _ = try library.writeCorruptFile("routes/broken.json")
        let model = RouteLocationModel(persistence: store, simulationService: ReliabilityNoopSink())
        await model.recordRecent(coordinate: RouteCoordinate(latitude: 26, longitude: 122))
        let loaded = try await store.loadRecentLocations()
        #expect(loaded.contains { $0.id == old.id })
        #expect(loaded.count == 2)
    }

    @Test func corruptFavoritesDoNotHideHealthyRoutes() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let store = library.store
        let route = reliabilityRoute()
        try await store.saveRoute(route)
        _ = try library.writeCorruptFile("locations.json")
        let model = RouteLocationModel(persistence: store, simulationService: ReliabilityNoopSink())
        await model.recordRecent(coordinate: RouteCoordinate(latitude: 25, longitude: 121))
        #expect(model.savedRoutes.map(\.id) == [route.id])
    }

    @Test func deletedPreviewIsClearedOnlyAfterSuccessfulDeletion() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let store = library.store
        let route = reliabilityRoute()
        try await store.saveRoute(route)
        let model = RouteLocationModel(persistence: store, simulationService: ReliabilityNoopSink())
        model.previewRoute(route)
        await model.deleteRoute(route)
        #expect(model.previewingRoute == nil)
        #expect(try await store.loadRoutes().isEmpty)
    }

    @Test func failedDeleteRetainsPreviewAndFile() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let route = reliabilityRoute()
        let file = try library.writeCorruptFile("routes/\(route.id.uuidString).json")
        let store = library.store
        let model = RouteLocationModel(persistence: store, simulationService: ReliabilityNoopSink())
        model.previewRoute(route)
        await model.deleteRoute(route)
        #expect(model.previewingRoute?.id == route.id)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func invalidRouteStartDoesNotMarkRouteUsed() async throws {
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        var route = reliabilityRoute()
        route.routeMode = .navigation
        route.navigationGeometryNeedsRecalculation = true
        let store = library.store
        try await store.saveRoute(route)
        let model = RouteLocationModel(persistence: store, simulationService: ReliabilityNoopSink())
        // recordRecent waits for the initial library load before this assertion.
        await model.recordRecent(coordinate: RouteCoordinate(latitude: 25, longitude: 121))
        await model.startRoute(route)
        let loaded = try await store.loadRoutes()
        #expect(loaded.first?.lastUsedAt == nil)
        model.playback.stop()
    }

    @Test func persistedSpeedIsClampedBeforeFirstUse() async {
        let key = "RouteLocation.lastSpeedKmh"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(900, forKey: key)
        let library = ReliabilityLibrary()
        defer { library.cleanUp() }
        let model = RouteLocationModel(persistence: library.store, simulationService: ReliabilityNoopSink())
        #expect(model.speedKmh == 300)
        await model.recordRecent(coordinate: RouteCoordinate(latitude: 25, longitude: 121))
    }
}

private actor ReliabilityNoopSink: LocationSimulationSink {
    func setCoordinate(_ coordinate: RouteCoordinate) async throws {}
    func clearSimulatedLocation() async throws {}
}

/// Holds the second command exactly across pause, avoiding a timing-dependent race setup.
private actor ReliabilitySuspendingSink: LocationSimulationSink {
    private enum WaitError: Error { case timedOut }
    private var calls = 0
    private var command: CheckedContinuation<Void, Error>?
    private var waiting: CheckedContinuation<Void, Error>?
    private var waiterTimeout: Task<Void, Never>?
    private var aborted = false

    func setCoordinate(_ coordinate: RouteCoordinate) async throws {
        calls += 1
        guard calls == 2 else { return }
        guard !aborted else { throw CancellationError() }
        try await withCheckedThrowingContinuation { continuation in
            command = continuation
            waiterTimeout?.cancel()
            waiterTimeout = nil
            waiting?.resume()
            waiting = nil
        }
    }

    func waitForSuspendedCommand() async throws {
        if command != nil { return }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiting = continuation
                waiterTimeout = Task {
                    do { try await Task.sleep(for: .seconds(5)) }
                    catch { return }
                    failWaiter(WaitError.timedOut)
                }
            }
        } onCancel: {
            Task { await self.failWaiter(CancellationError()) }
        }
    }

    private func failWaiter(_ error: Error) {
        aborted = true
        waiterTimeout?.cancel()
        waiterTimeout = nil
        waiting?.resume(throwing: error)
        waiting = nil
        command?.resume(throwing: error)
        command = nil
    }

    func finishCommand(failing: Bool) {
        let pending = command
        command = nil
        if failing { pending?.resume(throwing: LocationSimulationError.deviceTunnelUnavailable) }
        else { pending?.resume() }
    }

    func clearSimulatedLocation() async throws {}
}

@MainActor
struct V1_2_21PauseRaceTests {
    @Test(arguments: [false, true])
    func pauseSurvivesPendingTransportCommand(failing: Bool) async throws {
        let sink = ReliabilitySuspendingSink()
        let engine = RoutePlaybackEngine(sink: sink, updateInterval: 60, acquireKeepAlive: {}, releaseKeepAlive: {}, reconnectAction: {})
        let route = reliabilityRoute()
        try await engine.start(routeName: route.name, geometry: route.resolvedGeometry, speedKmh: 18.6, mode: .once)
        defer { engine.stop() }
        let pending = Task { await engine.verifyConnectionAfterTransportChange() }
        try await sink.waitForSuspendedCommand()
        engine.pause()
        let pausedDistance = engine.traveledDistance
        await sink.finishCommand(failing: failing)
        await pending.value
        #expect(engine.state == .paused)
        #expect(engine.traveledDistance == pausedDistance)
    }

    @Test(arguments: [false, true])
    func pauseSurvivesPendingRunLoopCompletion(failing: Bool) async throws {
        let sink = ReliabilitySuspendingSink()
        let engine = RoutePlaybackEngine(sink: sink, updateInterval: 0.001, acquireKeepAlive: {}, releaseKeepAlive: {}, reconnectAction: {})
        let route = reliabilityRoute()
        try await engine.start(routeName: route.name, geometry: route.resolvedGeometry, speedKmh: 18.6, mode: .once)
        defer { engine.stop() }
        let pending = try #require(engine.testPlaybackTaskForTesting)
        try await sink.waitForSuspendedCommand()
        engine.pause()
        let pausedDistance = engine.traveledDistance
        let pausedCoordinate = engine.currentCoordinate
        await sink.finishCommand(failing: failing)
        await pending.value
        #expect(engine.state == .paused)
        #expect(engine.traveledDistance == pausedDistance)
        #expect(engine.currentCoordinate == pausedCoordinate)
    }

    @Test(arguments: [false, true])
    func pauseResumeRejectsOldTransportCompletion(failing: Bool) async throws {
        let sink = ReliabilitySuspendingSink()
        let engine = RoutePlaybackEngine(sink: sink, updateInterval: 60, uptime: { 100 }, acquireKeepAlive: {}, releaseKeepAlive: {}, reconnectAction: {})
        let route = reliabilityRoute()
        try await engine.start(routeName: route.name, geometry: route.resolvedGeometry, speedKmh: 18.6, mode: .infiniteLoop, startingOffset: 100)
        defer { engine.stop() }
        let old = Task { await engine.verifyConnectionAfterTransportChange() }
        try await sink.waitForSuspendedCommand()
        engine.pause()
        let distance = engine.traveledDistance
        let coordinate = engine.currentCoordinate
        let lap = engine.lapNumber
        await engine.resume()
        try engine.setSpeed(42.5)
        await sink.finishCommand(failing: failing)
        await old.value
        #expect(engine.state == .running)
        #expect(engine.traveledDistance == distance)
        #expect(engine.currentCoordinate == coordinate)
        #expect(engine.lapNumber == lap)
        #expect(engine.speedKmh == 42.5)
    }

    @Test(arguments: [false, true])
    func resumedRunLoopIsNotReplacedByOldRunLoopCompletion(failing: Bool) async throws {
        let sink = ReliabilitySuspendingSink()
        let engine = RoutePlaybackEngine(sink: sink, updateInterval: 0.001, uptime: { 100 }, acquireKeepAlive: {}, releaseKeepAlive: {}, reconnectAction: {})
        let route = reliabilityRoute()
        try await engine.start(routeName: route.name, geometry: route.resolvedGeometry, speedKmh: 18.6, mode: .infiniteLoop, startingOffset: 100)
        defer { engine.stop() }
        let old = try #require(engine.testPlaybackTaskForTesting)
        try await sink.waitForSuspendedCommand()
        engine.pause()
        let distance = engine.traveledDistance
        let coordinate = engine.currentCoordinate
        await engine.resume()
        await sink.finishCommand(failing: failing)
        await old.value
        #expect(engine.state == .running)
        #expect(engine.traveledDistance == distance)
        #expect(engine.currentCoordinate == coordinate)
        #expect(engine.testPlaybackTaskForTesting != nil)
    }
}

private func waitForReliabilityEvent(_ events: AsyncStream<Void>) async throws {
    enum WaitError: Error { case timedOut }
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for await _ in events { return }
            try Task.checkCancellation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw WaitError.timedOut
        }
        defer { group.cancelAll() }
        try await group.next()
    }
}
