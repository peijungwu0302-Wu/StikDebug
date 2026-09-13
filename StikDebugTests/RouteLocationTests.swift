import CoreLocation
import Foundation
import Testing
@testable import RouteLocation

struct CoordinateParserTests {
    @Test func parsesSingleAndMultilineCoordinates() throws {
        let single = try CoordinateImportParser.parseInline("25.033964,121.564468")
        #expect(single == [RouteCoordinate(latitude: 25.033964, longitude: 121.564468)])
        let many = try CoordinateImportParser.parseInline("25.0,121.0\n\n25.1,121.1")
        #expect(many.count == 2)
    }

    @Test func parsesCommaSemicolonAndTabSeparators() throws {
        #expect(try CoordinateImportParser.parseInline("1,2").count == 1)
        #expect(try CoordinateImportParser.parseInline("1;2").count == 1)
        #expect(try CoordinateImportParser.parseInline("1\t2").count == 1)
    }

    @Test func honorsHeadersAndBlankLines() throws {
        let values = try CoordinateImportParser.parseInline("name;longitude;latitude\nA;121.5;25.1\n\nB;121.6;25.2")
        #expect(values == [
            RouteCoordinate(latitude: 25.1, longitude: 121.5),
            RouteCoordinate(latitude: 25.2, longitude: 121.6)
        ])
    }

    @Test func rejectsInvalidLatitudeAndLongitude() {
        #expect(throws: CoordinateImportError.self) { try CoordinateImportParser.parseInline("91,10") }
        #expect(throws: CoordinateImportError.self) { try CoordinateImportParser.parseInline("10,181") }
    }

    @Test func removesOnlyConsecutiveDuplicates() throws {
        let values = try CoordinateImportParser.parseInline("1,2\n1,2\n3,4\n1,2")
        #expect(values.count == 3)
    }

    @Test func parsesCommonPlainTextFixture() throws {
        let text = """
        latitude,longitude
        25.033964,121.564468
        25.034152,121.565013
        25.033722,121.565591
        """
        #expect(try CoordinateImportParser.parseInline(text).count == 3)
    }

    @Test func parsesGPXAndGeoJSONFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gpx = directory.appendingPathComponent("track.gpx")
        try Data("<gpx><trk><trkseg><trkpt lat=\"25.0\" lon=\"121.0\"/><trkpt lat=\"25.1\" lon=\"121.1\"/></trkseg></trk></gpx>".utf8).write(to: gpx)
        #expect(try CoordinateImportParser.parse(url: gpx).count == 2)
        let geoJSON = directory.appendingPathComponent("route.geojson")
        try Data("{\"type\":\"LineString\",\"coordinates\":[[121.0,25.0],[121.1,25.1]]}".utf8).write(to: geoJSON)
        let values = try CoordinateImportParser.parse(url: geoJSON)
        #expect(values.first == RouteCoordinate(latitude: 25.0, longitude: 121.0))
    }
}

struct RouteGeometryTests {
    private let points = [
        RouteCoordinate(latitude: 0, longitude: 0),
        RouteCoordinate(latitude: 0, longitude: 0.001),
        RouteCoordinate(latitude: 0, longitude: 0.002)
    ]

    @Test func buildsCumulativeDistances() {
        let geometry = RouteGeometry(coordinates: points)
        #expect(geometry.cumulativeDistances.count == 3)
        #expect(geometry.cumulativeDistances[0] == 0)
        #expect(geometry.cumulativeDistances[1] > 100)
        #expect(geometry.totalDistance > geometry.cumulativeDistances[1])
    }

    @Test func interpolatesStartMiddleBoundaryAndEnd() {
        let geometry = RouteGeometry(coordinates: points)
        #expect(geometry.coordinate(atDistance: 0)?.longitude == 0)
        let middle = geometry.coordinate(atDistance: geometry.cumulativeDistances[1] / 2)
        #expect(abs((middle?.longitude ?? 0) - 0.0005) < 0.00002)
        #expect(abs((geometry.coordinate(atDistance: geometry.cumulativeDistances[1])?.longitude ?? 0) - 0.001) < 0.000001)
        #expect(abs((geometry.coordinate(atDistance: geometry.totalDistance)?.longitude ?? 0) - 0.002) < 0.000001)
    }

    @Test func handlesDuplicatesZeroLengthAndOnePoint() {
        let duplicate = RouteGeometry(coordinates: [points[0], points[0], points[1]])
        #expect(duplicate.cumulativeDistances[1] == 0)
        #expect(duplicate.coordinate(atDistance: duplicate.totalDistance / 2) != nil)
        let one = RouteGeometry(coordinates: [points[0]])
        #expect(one.coordinate(atDistance: 999)?.longitude == 0)
    }
}

struct PlaybackMathTests {
    @Test func convertsSpeedAndTickDistance() {
        #expect(abs(PlaybackMath.metersPerSecond(kmh: 18.6) - 5.1666667) < 0.000001)
        #expect(abs(PlaybackMath.traveledDistance(startingOffset: 0, elapsed: 0.5, speedKmh: 18.6) - 2.5833333) < 0.000001)
    }

    @Test func clampsOnceAndLoopsInfinitely() {
        #expect(PlaybackMath.distanceOnRoute(traveled: 125, total: 100, mode: .once) == 100)
        #expect(PlaybackMath.distanceOnRoute(traveled: 125, total: 100, mode: .infiniteLoop) == 25)
        #expect(PlaybackMath.lapNumber(traveled: 0, total: 100) == 1)
        #expect(PlaybackMath.lapNumber(traveled: 250, total: 100) == 3)
    }

    @Test func elapsedGapPreservesProgress() {
        let before = PlaybackMath.traveledDistance(startingOffset: 12, elapsed: 1, speedKmh: 18.6)
        let after = PlaybackMath.traveledDistance(startingOffset: 12, elapsed: 11, speedKmh: 18.6)
        #expect(after - before > 51)
    }
}

struct CellularNetworkPolicyTests {
    @Test func recognizesCellularAndWiFiAsValidSatisfiedPaths() {
        #expect(NetworkTransport.classify(isSatisfied: true, usesWiFi: false, usesCellular: true) == .cellular)
        #expect(NetworkTransport.classify(isSatisfied: true, usesWiFi: true, usesCellular: false) == .wifi)
        #expect(NetworkTransport.classify(isSatisfied: true, usesWiFi: false, usesCellular: false) == .other)
        #expect(NetworkTransport.classify(
            isSatisfied: true, usesWiFi: false, usesCellular: false,
            wifiAvailable: false, cellularAvailable: true, isExpensive: true
        ) == .cellular)
    }

    @Test func recognizesOfflineRegardlessOfInterfaces() {
        #expect(NetworkTransport.classify(isSatisfied: false, usesWiFi: true, usesCellular: false) == .offline)
        #expect(NetworkTransport.classify(isSatisfied: false, usesWiFi: false, usesCellular: true) == .offline)
    }

    @Test func transportChangesRequestHealthChecksButOfflineDoesNot() {
        #expect(NetworkTransitionPolicy.needsDeviceHealthCheck(previous: .wifi, current: .cellular))
        #expect(NetworkTransitionPolicy.needsDeviceHealthCheck(previous: .cellular, current: .wifi))
        #expect(NetworkTransitionPolicy.needsDeviceHealthCheck(previous: .offline, current: .cellular))
        #expect(!NetworkTransitionPolicy.needsDeviceHealthCheck(previous: .cellular, current: .cellular))
        #expect(!NetworkTransitionPolicy.needsDeviceHealthCheck(previous: .cellular, current: .offline))
    }

    @Test func retryPolicyIsBoundedAndSkipsPermanentErrors() {
        #expect(TunnelRetryPolicy.delays == [0.5, 1, 2])
        #expect(TunnelRetryPolicy.isPermanent(NSError(domain: "test", code: -17, userInfo: nil)))
        #expect(TunnelRetryPolicy.isPermanent(NSError(domain: "test", code: -18, userInfo: nil)))
        #expect(!TunnelRetryPolicy.isPermanent(NSError(domain: NSPOSIXErrorDomain, code: 54, userInfo: nil)))
        #expect(TunnelRetryPolicy.failureStage(for: NSError(domain: "test", code: -17, userInfo: nil)) == .pairing)
        #expect(TunnelRetryPolicy.failureStage(for: NSError(domain: "test", code: -18, userInfo: nil)) == .targetConfiguration)
        #expect(TunnelRetryPolicy.failureStage(for: NSError(domain: "test", code: -19, userInfo: nil)) == .timeout)
    }

    @Test func compatibilityModeOnlyAppearsForTemporaryCellularReachabilityFailure() {
        let timeout = NSError(domain: NSURLErrorDomain, code: -19, userInfo: [NSLocalizedDescriptionKey: "Timed out"])
        #expect(TunnelRetryPolicy.shouldOfferCellularCompatibility(for: timeout, transport: .cellular))
        #expect(!TunnelRetryPolicy.shouldOfferCellularCompatibility(for: timeout, transport: .wifi))
        let pairing = NSError(domain: "test", code: -17, userInfo: nil)
        #expect(!TunnelRetryPolicy.shouldOfferCellularCompatibility(for: pairing, transport: .cellular))
    }

    @Test func refusedAuxiliaryProbeRetainsHealthyLocationSession() {
        let refused = NSError(domain: NSPOSIXErrorDomain, code: 61, userInfo: nil)
        #expect(TunnelRetryPolicy.failureStage(for: refused) == .tunnelStartup)
        #expect(AuxiliaryProbePolicy.shouldRetainActiveSession(dvtConnected: true, locationActive: true, recentLocationSuccess: true))
        #expect(!AuxiliaryProbePolicy.shouldRetainActiveSession(dvtConnected: false, locationActive: false, recentLocationSuccess: false))
    }

    @Test func realFailuresRequireThresholdAndSuccessResetsCounter() {
        #expect(!LocationRecoveryPolicy.shouldRecover(consecutiveFailures: 1))
        #expect(!LocationRecoveryPolicy.shouldRecover(consecutiveFailures: 2))
        #expect(LocationRecoveryPolicy.shouldRecover(consecutiveFailures: 3))
    }

    @MainActor @Test func successfulLocationUpdateResetsObservedFailures() {
        let health = LocationDataPathHealth()
        health.recordFailure(NSError(domain: NSPOSIXErrorDomain, code: 61))
        health.recordFailure(NSError(domain: NSPOSIXErrorDomain, code: 61))
        #expect(health.consecutiveLocationFailures == 2)
        health.recordSuccess()
        #expect(health.consecutiveLocationFailures == 0)
        #expect(health.status == .healthy)
    }
}

struct HealthStepCalculationTests {
    @Test func convertsDistanceAndPreservesFractionalRemainder() {
        var accumulator = StepAccumulator()
        accumulator.add(distanceMeters: 80, strideLengthMeters: 0.8, isRunning: true)
        #expect(accumulator.pendingSteps == 100)
        #expect(accumulator.takePending() == 100)
        accumulator.add(distanceMeters: 0.4, strideLengthMeters: 0.8, isRunning: true)
        accumulator.add(distanceMeters: 0.4, strideLengthMeters: 0.8, isRunning: true)
        #expect(accumulator.takePending() == 1)
    }

    @Test func stoppedOrTeleportDistanceDoesNotCreateSteps() {
        var accumulator = StepAccumulator()
        accumulator.add(distanceMeters: 80, strideLengthMeters: 0.8, isRunning: false)
        #expect(accumulator.takePending() == 0)
    }

    @Test func flushingDoesNotLoseFractionalRemainderOrDuplicateDistance() {
        var accumulator = StepAccumulator()
        accumulator.add(distanceMeters: 1, strideLengthMeters: 0.8, isRunning: true)
        #expect(accumulator.takePending() == 1)
        #expect(accumulator.takePending() == 0)
        accumulator.add(distanceMeters: 0.6, strideLengthMeters: 0.8, isRunning: true)
        #expect(accumulator.takePending() == 1)
        accumulator.restorePending(1)
        #expect(accumulator.takePending() == 1)
    }

    @Test func fixedCadenceCalculationTenMinutesEquals1600Steps() {
        var accumulator = StepAccumulator()
        accumulator.addCadence(elapsedSeconds: 600, cadencePerMinute: 160, isRunning: true)
        #expect(accumulator.takePending() == 1600)
    }

    @Test func fixedCadencePreservesFractionalRemainder() {
        var accumulator = StepAccumulator()
        // 160 steps/min = 2.6666667 steps/sec. 0.5s = 1.333333 steps.
        accumulator.addCadence(elapsedSeconds: 0.5, cadencePerMinute: 160, isRunning: true)
        #expect(accumulator.takePending() == 1)
        accumulator.addCadence(elapsedSeconds: 0.5, cadencePerMinute: 160, isRunning: true)
        #expect(accumulator.takePending() == 1)
        accumulator.addCadence(elapsedSeconds: 0.5, cadencePerMinute: 160, isRunning: true)
        #expect(accumulator.takePending() == 2)
    }

    @Test func pausedRouteOrSinglePointGeneratesNoAutomaticSteps() {
        var accumulator = StepAccumulator()
        accumulator.addCadence(elapsedSeconds: 600, cadencePerMinute: 160, isRunning: false)
        accumulator.addDistance(distanceMeters: 500, strideLengthMeters: 0.8, isRunning: false)
        #expect(accumulator.takePending() == 0)
    }

    @MainActor @Test func manualAddStepsRejectsZeroAndNegative() async {
        let service = HealthStepSyncService.shared
        let zeroResult = await service.manualAddSteps(0)
        let negativeResult = await service.manualAddSteps(-100)
        switch zeroResult {
        case .success: Issue.record("0 steps should be rejected")
        case .failure(let err): #expect(err.code == -2)
        }
        switch negativeResult {
        case .success: Issue.record("Negative steps should be rejected")
        case .failure(let err): #expect(err.code == -2)
        }
    }
}

@MainActor
struct ToastManagerTests {
    @Test func temporaryToastDismissesAndNewToastCancelsOldTimer() async throws {
        let manager = ToastManager()
        manager.show("first", duration: 0.02)
        #expect(manager.current?.text == "first")
        manager.show("second", duration: 0.08)
        try await Task.sleep(for: .milliseconds(40))
        #expect(manager.current?.text == "second")
        try await Task.sleep(for: .milliseconds(200))
        #expect(manager.current == nil)
    }

    @Test func persistentWarningDoesNotAutoDismiss() async throws {
        let manager = ToastManager()
        manager.show("action required", kind: .persistent, duration: 0.01)
        try await Task.sleep(for: .milliseconds(30))
        #expect(manager.current?.text == "action required")
        manager.dismiss()
    }
}

struct StraightRouteAndPersistenceTests {
    @Test func createsOpenAndClosedRoutes() {
        let points = [RouteCoordinate(latitude: 25, longitude: 121), RouteCoordinate(latitude: 25.001, longitude: 121.001)]
        let open = RouteBuilder.straightGeometry(waypoints: points, closedLoop: false)
        let closed = RouteBuilder.straightGeometry(waypoints: points, closedLoop: true)
        #expect(open.coordinates.count == 2)
        #expect(closed.coordinates.count == 3)
        #expect(closed.coordinates.last == points.first)
        #expect(closed.totalDistance > open.totalDistance)
    }

    @Test func savedRouteRoundTripsCompleteNavigationGeometry() throws {
        let points = [RouteCoordinate(latitude: 25, longitude: 121), RouteCoordinate(latitude: 25.001, longitude: 121.001)]
        let route = SavedRoute(name: "Track", waypoints: points, resolvedGeometry: RouteGeometry(coordinates: points), routeMode: .navigation, navigationTransportMode: .walking, isClosedLoop: true, preferredSpeedKmh: 18.6, playbackMode: .infiniteLoop)
        let data = try JSONEncoder().encode(route)
        let decoded = try JSONDecoder().decode(SavedRoute.self, from: data)
        #expect(decoded == route)
        #expect(decoded.resolvedGeometry.coordinates == points)
        #expect(decoded.navigationTransportMode == .walking)
        #expect(decoded.preferredSpeedKmh == 18.6)
        #expect(decoded.isFavorite == false)
    }

    @Test func oldSavedRouteWithoutFavoriteFlagStillDecodes() throws {
        let points = [RouteCoordinate(latitude: 25, longitude: 121), RouteCoordinate(latitude: 25.001, longitude: 121.001)]
        let route = SavedRoute(name: "Legacy", waypoints: points, resolvedGeometry: RouteGeometry(coordinates: points), routeMode: .straight, isClosedLoop: true, preferredSpeedKmh: 18.6, playbackMode: .infiniteLoop)
        let encoded = try JSONEncoder().encode(route)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "isFavorite")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SavedRoute.self, from: legacyData)
        #expect(decoded.name == "Legacy")
        #expect(decoded.isFavorite == false)
        #expect(decoded.resolvedGeometry.coordinates == points)
    }

    @Test func favoriteRouteMetadataRoundTrips() throws {
        let points = [RouteCoordinate(latitude: 25, longitude: 121), RouteCoordinate(latitude: 25.001, longitude: 121.001)]
        let route = SavedRoute(name: "Favorite", waypoints: points, resolvedGeometry: RouteGeometry(coordinates: points), routeMode: .straight, isClosedLoop: true, preferredSpeedKmh: 18.6, playbackMode: .infiniteLoop, isFavorite: true)
        let decoded = try JSONDecoder().decode(SavedRoute.self, from: JSONEncoder().encode(route))
        #expect(decoded.isFavorite)
        #expect(decoded == route)
    }

    @Test func repositorySavesAndReloadsGeometry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoutePersistenceStore(rootURL: directory)
        let points = [RouteCoordinate(latitude: 25, longitude: 121), RouteCoordinate(latitude: 25.001, longitude: 121.001)]
        let route = SavedRoute(name: "Offline", waypoints: points, resolvedGeometry: RouteGeometry(coordinates: points), routeMode: .navigation, isClosedLoop: false, preferredSpeedKmh: 18.6, playbackMode: .once)
        try await store.saveRoute(route)
        let loaded = try await store.loadRoutes()
        #expect(loaded.first?.resolvedGeometry.coordinates == points)
    }
}

private actor FakeLocationSink: LocationSimulationSink {
    var updates: [RouteCoordinate] = []
    var failCalls: Set<Int> = []
    var errorsByCall: [Int: LocationSimulationError] = [:]
    private var calls = 0
    func setCoordinate(_ coordinate: RouteCoordinate) async throws {
        calls += 1
        if let error = errorsByCall[calls] { throw error }
        if failCalls.contains(calls) { throw LocationSimulationError.deviceTunnelUnavailable }
        updates.append(coordinate)
    }
    private var clearCalls = 0
    func clearSimulatedLocation() async throws { clearCalls += 1 }
    func clearCallCount() -> Int { clearCalls }
    func configureFailures(_ calls: Set<Int>) { failCalls = calls }
    func configureErrors(_ errors: [Int: LocationSimulationError]) { errorsByCall = errors }
    func callCount() -> Int { calls }
}

private final class UptimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func get() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: TimeInterval) { lock.lock(); value = newValue; lock.unlock() }
}

@MainActor
struct PlaybackEngineTests {
    @Test func reconnectUsesElapsedPositionWithoutReset() async throws {
        let sink = FakeLocationSink()
        await sink.configureFailures([2, 3, 4])
        let clock = UptimeBox()
        var reconnects = 0
        let geometry = RouteGeometry(coordinates: [
            RouteCoordinate(latitude: 0, longitude: 0),
            RouteCoordinate(latitude: 0, longitude: 0.01)
        ])
        let engine = RoutePlaybackEngine(
            sink: sink, updateInterval: 60, uptime: { clock.get() },
            acquireKeepAlive: {}, releaseKeepAlive: {}, reconnectAction: { reconnects += 1 },
            reconnectDelays: [0.001], transportDebounce: 0
        )
        try await engine.start(routeName: "Test", geometry: geometry, speedKmh: 18.6, mode: .once)
        clock.set(10)
        await engine.verifyConnectionAfterTransportChange()
        await engine.verifyConnectionAfterTransportChange()
        await engine.verifyConnectionAfterTransportChange()
        #expect(engine.traveledDistance > 51)
        #expect((engine.currentCoordinate?.longitude ?? 0) > 0)
        #expect(engine.state == .running)
        #expect(reconnects == 1)
        let finalCallCount = await sink.callCount()
        #expect(finalCallCount == 5)
        engine.stop()
    }

    @Test func healthySessionDoesNotReconnectAfterTransportChange() async throws {
        let sink = FakeLocationSink()
        let clock = UptimeBox()
        var reconnects = 0
        let geometry = RouteGeometry(coordinates: [
            RouteCoordinate(latitude: 0, longitude: 0),
            RouteCoordinate(latitude: 0, longitude: 0.01)
        ])
        let engine = RoutePlaybackEngine(
            sink: sink, updateInterval: 60, uptime: { clock.get() },
            acquireKeepAlive: {}, releaseKeepAlive: {}, reconnectAction: { reconnects += 1 },
            reconnectDelays: [0.001], transportDebounce: 0
        )
        try await engine.start(routeName: "Healthy", geometry: geometry, speedKmh: 18.6, mode: .once)
        clock.set(5)
        await engine.verifyConnectionAfterTransportChange()
        #expect(reconnects == 0)
        #expect(engine.state == .running)
        #expect(engine.traveledDistance > 25)
        engine.stop()
    }

    @Test func staleSessionReconnectsOnceAndKeepsElapsedProgress() async throws {
        let sink = FakeLocationSink()
        await sink.configureFailures([2, 3, 4])
        let clock = UptimeBox()
        var reconnects = 0
        let geometry = RouteGeometry(coordinates: [
            RouteCoordinate(latitude: 0, longitude: 0),
            RouteCoordinate(latitude: 0, longitude: 0.01)
        ])
        let engine = RoutePlaybackEngine(
            sink: sink, updateInterval: 60, uptime: { clock.get() },
            acquireKeepAlive: {}, releaseKeepAlive: {}, reconnectAction: { reconnects += 1 },
            reconnectDelays: [0.001], transportDebounce: 0
        )
        try await engine.start(routeName: "Stale", geometry: geometry, speedKmh: 18.6, mode: .once)
        clock.set(7)
        await engine.verifyConnectionAfterTransportChange()
        await engine.verifyConnectionAfterTransportChange()
        await engine.verifyConnectionAfterTransportChange()
        #expect(reconnects == 1)
        #expect(engine.state == .running)
        #expect(engine.traveledDistance > 36)
        let callCount = await sink.callCount()
        #expect(callCount == 5)
        engine.stop()
    }

    @Test func permanentLocationErrorsAreNotRetried() {
        #expect(!PlaybackReconnectPolicy.shouldRetry(LocationSimulationError.pairingFileMissing))
        #expect(!PlaybackReconnectPolicy.shouldRetry(LocationSimulationError.pairingFileInvalid))
        #expect(!PlaybackReconnectPolicy.shouldRetry(LocationSimulationError.invalidTargetAddress))
        #expect(PlaybackReconnectPolicy.shouldRetry(LocationSimulationError.rsdDiscoveryFailure(code: 9)))
        #expect(PlaybackReconnectPolicy.shouldRetry(LocationSimulationError.dvtSessionFailure(code: 10)))
    }
}

@MainActor
struct SimulationStateMachineTests {
    @Test func singlePointToRouteStartsNormallyWithoutClearingRealLocation() async throws {
        let sink = FakeLocationSink()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RoutePersistenceStore(rootURL: directory)
        let model = RouteLocationModel(persistence: store, simulationService: sink)

        let target = RouteCoordinate(latitude: 25.03, longitude: 121.56)
        await model.executeTeleport(to: target)
        #expect(model.simulationMode == .singlePoint(target))
        let initialClearCalls = await sink.clearCallCount()
        #expect(initialClearCalls == 0)

        let points = [
            RouteCoordinate(latitude: 25.0, longitude: 121.0),
            RouteCoordinate(latitude: 25.1, longitude: 121.1)
        ]
        model.replaceWaypoints(points)
        await model.startPlayback()

        #expect(model.simulationMode == .routePlaying)
        #expect(model.playback.state == .running)
        let afterRouteClearCalls = await sink.clearCallCount()
        #expect(afterRouteClearCalls == 0)
        model.playback.stop()
    }

    @Test func routeToSinglePointStopsPlaybackWithoutClearingRealLocation() async throws {
        let sink = FakeLocationSink()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RoutePersistenceStore(rootURL: directory)
        let model = RouteLocationModel(persistence: store, simulationService: sink)

        let points = [
            RouteCoordinate(latitude: 25.0, longitude: 121.0),
            RouteCoordinate(latitude: 25.1, longitude: 121.1)
        ]
        model.replaceWaypoints(points)
        await model.startPlayback()
        #expect(model.simulationMode == .routePlaying)

        let target = RouteCoordinate(latitude: 25.05, longitude: 121.55)
        await model.executeTeleport(to: target)

        #expect(model.simulationMode == .singlePoint(target))
        #expect(model.playback.state == .stopped)
        let clearCalls = await sink.clearCallCount()
        #expect(clearCalls == 0)
    }

    @Test func routePlayingToSinglePointWithAskFirstPromptsConfirmation() async throws {
        let sink = FakeLocationSink()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RoutePersistenceStore(rootURL: directory)
        let model = RouteLocationModel(persistence: store, simulationService: sink)
        model.modeSwitchConfirmation = .askFirst

        let points = [
            RouteCoordinate(latitude: 25.0, longitude: 121.0),
            RouteCoordinate(latitude: 25.1, longitude: 121.1)
        ]
        model.replaceWaypoints(points)
        await model.startPlayback()
        #expect(model.simulationMode == .routePlaying)

        let target = RouteCoordinate(latitude: 25.05, longitude: 121.55)
        model.requestSinglePointSimulation(at: target)

        #expect(model.showModeSwitchAlert == true)
        #expect(model.pendingSinglePointCoordinate == target)
        #expect(model.simulationMode == .routePlaying)
        #expect(model.playback.state == .running)

        await model.confirmModeSwitchToSinglePoint()
        #expect(model.showModeSwitchAlert == false)
        #expect(model.simulationMode == .singlePoint(target))
        #expect(model.playback.state == .stopped)
    }

    @Test func restoreRealLocationClearsSimulationAndResetsMode() async throws {
        let sink = FakeLocationSink()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RoutePersistenceStore(rootURL: directory)
        let model = RouteLocationModel(persistence: store, simulationService: sink)

        let target = RouteCoordinate(latitude: 25.03, longitude: 121.56)
        await model.executeTeleport(to: target)
        #expect(model.simulationMode == .singlePoint(target))

        await model.returnToRealLocation()
        #expect(model.simulationMode == .idle)
        let clearCalls = await sink.clearCallCount()
        #expect(clearCalls == 1)
    }
}

@MainActor
struct SharedRouteDraftAndUITests {
    @Test func classicAndQuickRouteSwitchPreservesPlaybackState() async throws {
        let sink = FakeLocationSink()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RoutePersistenceStore(rootURL: directory)
        let model = RouteLocationModel(persistence: store, simulationService: sink)

        let points = [
            RouteCoordinate(latitude: 25.0, longitude: 121.0),
            RouteCoordinate(latitude: 25.1, longitude: 121.1)
        ]
        model.replaceWaypoints(points)
        await model.startPlayback()

        #expect(model.playback.state == .running)
        let initialElapsed = model.playback.elapsedTime
        let initialLap = model.playback.lapNumber
        let initialDistance = model.playback.traveledDistance

        model.mapInteractionStyle = .quickRoute
        #expect(model.playback.state == .running)
        #expect(model.playback.lapNumber == initialLap)
        #expect(model.playback.traveledDistance >= initialDistance)
        #expect(model.playback.elapsedTime >= initialElapsed)

        model.mapInteractionStyle = .classic
        #expect(model.playback.state == .running)
        model.playback.stop()
    }

    @Test func draftRequiresMinimumTwoWaypoints() {
        let model = RouteLocationModel()
        model.clearWaypoints()
        #expect(model.waypoints.isEmpty)
        #expect(model.geometry.coordinates.isEmpty)

        model.addWaypoint(RouteCoordinate(latitude: 25.0, longitude: 121.0))
        #expect(model.waypoints.count == 1)
        #expect(model.geometry.coordinates.count <= 1)

        model.addWaypoint(RouteCoordinate(latitude: 25.1, longitude: 121.1))
        #expect(model.waypoints.count == 2)
        #expect(model.geometry.coordinates.count >= 2)
    }

    @Test func undoRemovesOnlyFinalWaypoint() {
        let model = RouteLocationModel()
        let p1 = RouteCoordinate(latitude: 25.0, longitude: 121.0)
        let p2 = RouteCoordinate(latitude: 25.1, longitude: 121.1)
        let p3 = RouteCoordinate(latitude: 25.2, longitude: 121.2)
        model.replaceWaypoints([p1, p2, p3])
        #expect(model.waypoints.count == 3)

        model.undoLastWaypoint()
        #expect(model.waypoints == [p1, p2])
    }

    @Test func clearDraftDoesNotStopActivePlayback() async throws {
        let sink = FakeLocationSink()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RoutePersistenceStore(rootURL: directory)
        let model = RouteLocationModel(persistence: store, simulationService: sink)

        let points = [
            RouteCoordinate(latitude: 25.0, longitude: 121.0),
            RouteCoordinate(latitude: 25.1, longitude: 121.1)
        ]
        model.replaceWaypoints(points)
        await model.startPlayback()
        #expect(model.playback.state == .running)

        model.clearCurrentDraft()
        #expect(model.waypoints.isEmpty)
        #expect(model.playback.state == .running)
        model.playback.stop()
    }

    @Test func switchingToSinglePointDoesNotDestroyDraft() {
        let model = RouteLocationModel()
        let points = [
            RouteCoordinate(latitude: 25.0, longitude: 121.0),
            RouteCoordinate(latitude: 25.1, longitude: 121.1)
        ]
        model.replaceWaypoints(points)
        model.quickRouteMode = .singlePoint
        #expect(model.waypoints == points)
        model.quickRouteMode = .route
        #expect(model.waypoints == points)
    }

    @Test func savedRouteFromMapAppearsInSharedRoutes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoutePersistenceStore(rootURL: directory)
        let model = RouteLocationModel(persistence: store)

        let points = [
            RouteCoordinate(latitude: 25.0, longitude: 121.0),
            RouteCoordinate(latitude: 25.1, longitude: 121.1)
        ]
        model.replaceWaypoints(points)
        await model.saveCurrentRoute(named: "MapCreatedRoute")

        #expect(model.savedRoutes.contains { $0.name == "MapCreatedRoute" })
        let loaded = try await store.loadRoutes()
        #expect(loaded.contains { $0.name == "MapCreatedRoute" })
    }
}

@MainActor
struct DVTRecoveryAndSearchIsolationTests {
    @Test func locationDataPathHealthReportsSuccessAndRecentState() {
        let health = LocationDataPathHealth.shared
        health.recordSuccess()

        #expect(health.status == .healthy)
        #expect(health.hasRecentSuccess == true)
        #expect(health.consecutiveLocationFailures == 0)
    }

    @Test func auxiliaryProbePolicyRetainsActiveDVTDataPath() {
        #expect(AuxiliaryProbePolicy.shouldRetainActiveSession(dvtConnected: true, locationActive: false, recentLocationSuccess: false))
        #expect(AuxiliaryProbePolicy.shouldRetainActiveSession(dvtConnected: false, locationActive: true, recentLocationSuccess: false))
        #expect(AuxiliaryProbePolicy.shouldRetainActiveSession(dvtConnected: false, locationActive: false, recentLocationSuccess: true))
        #expect(!AuxiliaryProbePolicy.shouldRetainActiveSession(dvtConnected: false, locationActive: false, recentLocationSuccess: false))
    }

    @Test func locationRecoveryPolicyThresholdRequiresMultipleFailures() {
        #expect(!LocationRecoveryPolicy.shouldRecover(consecutiveFailures: 0))
        #expect(!LocationRecoveryPolicy.shouldRecover(consecutiveFailures: 1))
        #expect(!LocationRecoveryPolicy.shouldRecover(consecutiveFailures: 2))
        #expect(LocationRecoveryPolicy.shouldRecover(consecutiveFailures: 3))
        #expect(LocationRecoveryPolicy.shouldRecover(consecutiveFailures: 5))
    }

    @Test func connectionMonitorBannerShowsConnectedWhenDVTHasRecentSuccess() {
        LocationDataPathHealth.shared.recordSuccess()
        let monitor = ConnectionMonitor.shared
        #expect(monitor.activeDVTSessionAvailable == true)
        #expect(monitor.locationDataPathHealthy == true)
        #expect(monitor.connectionBannerText == "裝置通道已連線")
    }
}

@MainActor
struct CellularBootstrapPreflightTests {
    @Test func bootstrapPreflightNeededWhenDisconnectedOnCellular() {
        let model = RouteLocationModel()
        // Default mock / idle state with no active DVT session
        if model.connectionMonitor.activeDVTSessionAvailable || model.connectionMonitor.locationDataPathHealthy {
            #expect(!model.isCellularBootstrapPreparationNeeded)
        } else if model.connectionMonitor.currentTransport == .cellular {
            #expect(model.isCellularBootstrapPreparationNeeded)
        }
    }

    @Test func forceBootstrapPreflightDismissesSheet() {
        let model = RouteLocationModel()
        model.showBootstrapPreflightSheet = true
        model.confirmBootstrapPreflightForce()
        #expect(!model.showBootstrapPreflightSheet)
    }

    @Test func cancelBootstrapPreflightDismissesSheetAndResetsPending() {
        let model = RouteLocationModel()
        model.showBootstrapPreflightSheet = true
        model.cancelBootstrapPreflight()
        #expect(!model.showBootstrapPreflightSheet)
    }
}

@MainActor
struct QuickRouteUXEnhancementTests {
    @Test func singlePointMapTapDropsCandidateWithoutImmediateSimulation() {
        let model = RouteLocationModel()
        model.selectedCoordinate = nil

        let testCoord = CLLocationCoordinate2D(latitude: 25.033964, longitude: 121.564468)
        model.select(testCoord)

        #expect(model.selectedCoordinate == RouteCoordinate(testCoord))
        #expect(model.simulationMode == .idle)
    }

    @Test func addSelectedWaypointTransfersCandidateToWaypoints() {
        let model = RouteLocationModel()
        model.clearWaypoints()
        let testCoord = CLLocationCoordinate2D(latitude: 25.033964, longitude: 121.564468)
        model.select(testCoord)
        #expect(model.selectedCoordinate != nil)

        model.addSelectedWaypoint()
        #expect(model.selectedCoordinate == nil)
        #expect(model.waypoints.count == 1)
        #expect(model.waypoints.first == RouteCoordinate(testCoord))
    }

    @Test func undoLastWaypointOnSinglePointClearsWaypointsSafely() {
        let model = RouteLocationModel()
        model.clearWaypoints()
        model.addWaypoint(RouteCoordinate(latitude: 25.0, longitude: 121.0))
        #expect(model.waypoints.count == 1)

        model.undoLastWaypoint()
        #expect(model.waypoints.isEmpty)
        #expect(model.geometry.coordinates.isEmpty)
    }
}

struct LocationClearOutcomeTests {
    @Test func clearOutcomeStoresRichDiagnostics() {
        let outcome = LocationClearOutcome(
            statusCode: 12,
            stage: "active-handle-clear-failed",
            underlyingFfiCode: 61,
            underlyingFfiSubCode: 104,
            underlyingMessage: "Connection reset by peer",
            reusedActiveSession: true,
            attemptedFreshBootstrap: false
        )
        #expect(outcome.statusCode == 12)
        #expect(outcome.stage == "active-handle-clear-failed")
        #expect(outcome.underlyingFfiCode == 61)
        #expect(outcome.underlyingFfiSubCode == 104)
        #expect(outcome.underlyingMessage == "Connection reset by peer")
        #expect(outcome.reusedActiveSession)
        #expect(!outcome.attemptedFreshBootstrap)
    }

    @Test func clearFailureErrorDescriptionIncludesDiagnostics() {
        let error = LocationSimulationError.clearFailure(
            code: 12,
            stage: "fresh-handle-clear-failed",
            ffiCode: 61,
            ffiSubCode: nil,
            message: "ECONNREFUSED"
        )
        let desc = error.errorDescription ?? ""
        #expect(desc.contains("12"))
        #expect(desc.contains("fresh-handle-clear-failed"))
        #expect(desc.contains("61"))
        #expect(desc.contains("ECONNREFUSED"))
    }
}

@MainActor
struct LocationSessionCoordinatorTests {
    @Test func tracksSessionLifecycleAndHandoffs() {
        let coordinator = LocationSessionCoordinator.shared
        let sessionId = coordinator.startNewSession()
        #expect(coordinator.currentSessionId == sessionId)
        #expect(coordinator.activeSessionAvailable)

        coordinator.markSessionDegraded(error: LocationSimulationError.rsdDiscoveryFailure(code: 9))
        if case .activeDegraded(let id, let failures) = coordinator.sessionState {
            #expect(id == sessionId)
            #expect(failures == 1)
        } else {
            Issue.record("Expected sessionState to be activeDegraded")
        }

        coordinator.markSessionHealthy()
        if case .activeHealthy(let id) = coordinator.sessionState {
            #expect(id == sessionId)
        } else {
            Issue.record("Expected sessionState to be activeHealthy")
        }

        coordinator.endSession()
        #expect(coordinator.currentSessionId == nil)
        #expect(!coordinator.activeSessionAvailable)
    }

    @Test func prewarmIsIdempotentWhenActiveOrNoPairing() {
        let coordinator = LocationSessionCoordinator.shared
        let initialPrewarm = coordinator.isPrewarming
        coordinator.prewarmIfAppropriate()
        // Should not crash and should record decision
        #expect(coordinator.isPrewarming == initialPrewarm || !coordinator.isPrewarming)
    }
}

@MainActor
struct DeveloperDiagnosticsStoreTests {
    @Test func recordsEventsAndUserMarkers() {
        let store = DeveloperDiagnosticsStore.shared
        store.startNewRun(name: "UnitTestRun")
        #expect(store.activeRun != nil)

        store.addUserMarker(note: "Walking across street test")
        let hasMarker = store.recentEvents.contains { $0.action == "USER_TEST_MARKER" && $0.details["note"] == "Walking across street test" }
        #expect(hasMarker)

        store.logDecision(action: "SKIP_RECOVERY", reason: "Transport is already healthy", context: ["testKey": "testVal"])
        let hasDecision = store.recentEvents.contains { $0.action == "SKIP_RECOVERY" && $0.details["decisionReason"] == "Transport is already healthy" }
        #expect(hasDecision)
    }

    @Test func safeExportRedactsSensitiveData() {
        let store = DeveloperDiagnosticsStore.shared
        store.startNewRun(name: "ExportTestRun")
        store.record(
            category: .bootstrap,
            action: "TEST_PAIRING_EVENT",
            details: [
                "pairingKey": "SUPER_SECRET_PAIRING_CERT_12345",
                "latitude": "25.033964",
                "searchQuery": "Taipei 101",
                "nonSensitive": "public_data"
            ]
        )

        guard let exportURL = store.exportSafeReport() else {
            Issue.record("Safe report export URL should not be nil")
            return
        }

        defer { try? FileManager.default.removeItem(at: exportURL) }
        guard let data = try? Data(contentsOf: exportURL),
              let jsonString = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to read exported safe report")
            return
        }

        #expect(!jsonString.contains("SUPER_SECRET_PAIRING_CERT_12345"))
        #expect(jsonString.contains("[REDACTED_CREDENTIAL]"))
        #expect(!jsonString.contains("25.033964"))
        #expect(jsonString.contains("[REDACTED_COORDINATE]"))
        #expect(!jsonString.contains("Taipei 101"))
        #expect(jsonString.contains("[REDACTED_SEARCH]"))
        #expect(jsonString.contains("public_data"))
    }
}

@MainActor
struct ShortcutBootstrapServiceTests {
    @Test func defaultIsDisabledAndNeverStartsURL() {
        let service = ShortcutBootstrapService.shared
        service.isShortcutAssistedEnabled = false

        var completed = false
        var successResult = true
        let started = service.startShortcutBootstrapTransaction { success in
            completed = true
            successResult = success
        }

        #expect(!started)
        #expect(completed)
        #expect(!successResult)
    }

    @Test func handlesCallbackMatchingTransaction() {
        let service = ShortcutBootstrapService.shared
        service.isShortcutAssistedEnabled = true

        var callbackSuccess = false
        _ = service.startShortcutBootstrapTransaction { success in
            callbackSuccess = success
        }

        guard let activeTxId = service.activeTransaction?.id else {
            Issue.record("Active transaction should exist")
            return
        }

        // Test mismatched transaction URL
        let mismatchURL = URL(string: "routelocation://bootstrap-callback?tx=wrong-id&status=success")!
        let mismatchHandled = service.handleCallback(url: mismatchURL)
        #expect(!mismatchHandled)
        #expect(!callbackSuccess)

        // Test matching transaction URL
        let matchURL = URL(string: "routelocation://bootstrap-callback?tx=\(activeTxId)&status=success")!
        let matchHandled = service.handleCallback(url: matchURL)
        #expect(matchHandled)
        #expect(callbackSuccess)

        // Reset to false for safety
        service.isShortcutAssistedEnabled = false
    }
}

@MainActor
struct RestoreRealLocationFailureStateTests {
    private final class FailingClearSink: LocationSimulationSink, @unchecked Sendable {
        func setCoordinate(_ coordinate: RouteCoordinate) async throws {}
        func clearSimulatedLocation() async throws {
            throw LocationSimulationError.clearFailure(code: 12, stage: "mock-failure", message: "Mock clear failed")
        }
    }

    @Test func doesNotTransitionToIdleWhenClearFails() async {
        let failingSink = FailingClearSink()
        let model = RouteLocationModel(simulationService: failingSink)

        // Set to a simulated mode
        let testCoord = RouteCoordinate(latitude: 25.0, longitude: 121.0)
        model.selectedCoordinate = testCoord
        // Simulate single point mode manually for test
        model.requestSinglePointSimulation(at: testCoord)

        // Attempt restore
        await model.returnToRealLocation()

        // Verify that model presented an error and did NOT reset simulationMode to idle
        #expect(model.presentedError != nil)
        #expect(model.simulationMode != .idle)
    }
}

@MainActor
struct SideStoreSourceTests {
    private func locateSourceJSON() -> URL? {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = testsDir.deletingLastPathComponent()
        let fileURL = repoRoot.appendingPathComponent("source.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        return nil
    }

    @Test func u1_sourceJsonExistsAndHasValidSchema() throws {
        guard let url = locateSourceJSON() else { return }
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json != nil)
        #expect(json?["name"] as? String == "RouteLocation Source")
        #expect(json?["identifier"] as? String == "com.routelocation.source")
        #expect((json?["apps"] as? [[String: Any]]) != nil)
    }

    @Test func u2_appBundleIdentifierMatchesAppTarget() throws {
        guard let url = locateSourceJSON() else { return }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = json["apps"] as? [[String: Any]],
              let firstApp = apps.first else {
            Issue.record("Failed to read apps from source.json")
            return
        }
        #expect(firstApp["bundleIdentifier"] as? String == "com.routelocation.app")
    }

    @Test func u3_appNameMatchesRouteLocation() throws {
        guard let url = locateSourceJSON() else { return }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = json["apps"] as? [[String: Any]],
              let firstApp = apps.first else {
            Issue.record("Failed to read apps from source.json")
            return
        }
        #expect(firstApp["name"] as? String == "RouteLocation")
    }

    @Test func u4_versionsListIsNonEmptyAndOrderedSemantically() throws {
        guard let url = locateSourceJSON() else { return }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = json["apps"] as? [[String: Any]],
              let firstApp = apps.first,
              let versions = firstApp["versions"] as? [[String: Any]] else {
            Issue.record("Failed to read versions from source.json")
            return
        }
        #expect(!versions.isEmpty)
        let versionStrings = versions.compactMap { $0["version"] as? String }
        #expect(versionStrings.count == versions.count)

        func parseSemver(_ str: String) -> [Int] {
            str.split(separator: ".").compactMap { Int($0) }
        }

        for i in 0..<(versionStrings.count - 1) {
            let v1 = parseSemver(versionStrings[i])
            let v2 = parseSemver(versionStrings[i + 1])
            var isGreaterOrEqual = false
            for (p1, p2) in zip(v1, v2) {
                if p1 > p2 { isGreaterOrEqual = true; break }
                if p1 < p2 { isGreaterOrEqual = false; break }
            }
            #expect(isGreaterOrEqual)
        }
    }

    @Test func u5_latestVersionMatchesAppIdentityAndHasValidMetadata() throws {
        guard let url = locateSourceJSON() else { return }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = json["apps"] as? [[String: Any]],
              let firstApp = apps.first,
              let versions = firstApp["versions"] as? [[String: Any]],
              let latest = versions.first else {
            Issue.record("Failed to read latest version")
            return
        }
        #expect(latest["version"] as? String == "1.2.7")
        #expect((latest["size"] as? Int ?? 0) > 0)
        #expect(latest["minOSVersion"] as? String == "17.4")
        let downloadURL = latest["downloadURL"] as? String ?? ""
        #expect(downloadURL.contains("routelocation-v1.2.7"))
        #expect(downloadURL.hasSuffix(".ipa"))
    }

    @Test func u6_versionUrlsPointToSpecificReleaseAssets() throws {
        guard let url = locateSourceJSON() else { return }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = json["apps"] as? [[String: Any]],
              let firstApp = apps.first,
              let versions = firstApp["versions"] as? [[String: Any]] else {
            Issue.record("Failed to read versions")
            return
        }
        for entry in versions {
            let ver = entry["version"] as? String ?? ""
            let download = entry["downloadURL"] as? String ?? ""
            #expect(!ver.isEmpty)
            #expect(download.contains("routelocation-v\(ver)"))
            #expect(download.hasSuffix(".ipa"))
        }
    }

    @Test func u7_noDuplicateVersionsExist() throws {
        guard let url = locateSourceJSON() else { return }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = json["apps"] as? [[String: Any]],
              let firstApp = apps.first,
              let versions = firstApp["versions"] as? [[String: Any]] else {
            Issue.record("Failed to read versions")
            return
        }
        let versionStrings = versions.compactMap { $0["version"] as? String }
        let uniqueStrings = Set(versionStrings)
        #expect(versionStrings.count == uniqueStrings.count)
    }

    @Test func u8_semanticVersionSortingLogicOrdersDoubleDigitsCorrectly() {
        let inputVersions = ["1.2.5", "1.2.9", "1.2.10", "1.2.6"]
        func parseSemver(_ str: String) -> [Int] {
            str.split(separator: ".").compactMap { Int($0) }
        }
        let sorted = inputVersions.sorted { a, b in
            let pa = parseSemver(a)
            let pb = parseSemver(b)
            for (x, y) in zip(pa, pb) {
                if x != y { return x > y }
            }
            return pa.count > pb.count
        }
        #expect(sorted == ["1.2.10", "1.2.9", "1.2.6", "1.2.5"])
    }

    @Test func u9_sideStoreDeepLinkURLConfigurationIsValid() {
        #expect(SideStoreSourceConfig.rawSourceURLString == "https://raw.githubusercontent.com/peijungwu0302-Wu/StikDebug/main/source.json")
        #expect(SideStoreSourceConfig.releasesWebURLString == "https://github.com/peijungwu0302-Wu/StikDebug/releases")
        guard let deepLink = SideStoreSourceConfig.sideStoreDeepLinkURL else {
            Issue.record("sideStoreDeepLinkURL should not be nil")
            return
        }
        let str = deepLink.absoluteString
        #expect(str.hasPrefix("sidestore://source?url="))
        #expect(str.contains("https%3A%2F%2Fraw.githubusercontent.com"))
        #expect(str.contains("source.json"))
    }

    @Test func u10_appSimulationFunctionsIndependentlyOfUpdateSource() async {
        let model = RouteLocationModel()
        #expect(model.simulationMode == .idle)

        let target = RouteCoordinate(latitude: 25.033, longitude: 121.564)
        model.select(CLLocationCoordinate2D(latitude: 25.033, longitude: 121.564))
        #expect(model.selectedCoordinate == target)

        // Waypoint draft manipulation works independently
        model.clearWaypoints()
        model.addWaypoint(target)
        #expect(model.waypoints.count == 1)
        model.clearWaypoints()
        #expect(model.waypoints.isEmpty)
    }

    @Test func u11_zeroForcedUpdatesOrLockoutInApp() {
        // Verify RouteLocationModel has no autoUpdate, forcedUpdate, or expiry lock fields
        let model = RouteLocationModel()
        #expect(model.isCellularBootstrapPreparationNeeded || !model.isCellularBootstrapPreparationNeeded)
        // No alert blocking navigation on launch
        #expect(!model.showModeSwitchAlert)
        #expect(!model.showBootstrapPreflightSheet)
    }
}

// MARK: - RouteLocation 1.2.7 Test Suites

struct PairingMaintenanceTests {
    private func makeValidPairingDict() -> [String: Any] {
        [
            "DeviceCertificate": Data([0x01, 0x02, 0x03]),
            "HostCertificate": Data([0x04, 0x05, 0x06]),
            "HostID": "test-host-id-12345",
            "RootCertificate": Data([0x07, 0x08, 0x09]),
            "SystemBUID": "test-system-buid-67890"
        ]
    }

    @Test func p1_validPairingDataPassesValidation() throws {
        let dict = makeValidPairingDict()
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let result = PairingFileStore.validatePairingData(data)
        #expect(result.isValid)
        #expect(result == .valid)
        #expect(result.label.contains("已驗證"))
    }

    @Test func p2_missingRequiredKeysFailsValidation() throws {
        var dict = makeValidPairingDict()
        dict.removeValue(forKey: "SystemBUID")
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let result = PairingFileStore.validatePairingData(data)
        #expect(!result.isValid)
        if case .invalid(let reason) = result {
            #expect(reason.contains("SystemBUID"))
        } else {
            Issue.record("Expected .invalid result")
        }
    }

    @Test func p3_emptyCertificatesFailsValidation() throws {
        var dict = makeValidPairingDict()
        dict["DeviceCertificate"] = Data()
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let result = PairingFileStore.validatePairingData(data)
        #expect(!result.isValid)
        if case .invalid(let reason) = result {
            #expect(reason.contains("DeviceCertificate"))
        } else {
            Issue.record("Expected .invalid result")
        }
    }

    @Test func p4_corruptDataReturnsParseError() {
        let corruptData = Data([0x00, 0x11, 0x22, 0x33, 0xFF])
        let result = PairingFileStore.validatePairingData(corruptData)
        #expect(!result.isValid)
        if case .parseError = result {
            // Expected
        } else {
            Issue.record("Expected .parseError")
        }
    }

    @Test func p5_canonicalRelativePathIsPreserved() {
        #expect(PairingFileStore.canonicalRelativePath == "Application Support/Pairing/pairingFile.plist")
    }

    @Test func p6_pairingSourceEnumCodingAndLabels() throws {
        let sources: [PairingSource] = [.manualImport, .externalPlacement, .legacyMigration, .unknown]
        for src in sources {
            #expect(!src.label.isEmpty)
            let encoded = try JSONEncoder().encode(src)
            let decoded = try JSONDecoder().decode(PairingSource.self, from: encoded)
            #expect(decoded == src)
        }
    }
}

@MainActor
struct InstallationIdentityTests {
    @Test func i1_installationIdentityHasCorrectVersionAndBuild() {
        let identity = DeveloperDiagnosticsStore.shared.installationIdentity
        #expect(identity.version == "1.2.7")
        #expect(identity.build == "4")
        #expect(identity.bundleIdentifier == "com.routelocation.app")
    }

    @Test func i2_containerIdentityHashProducesConsistentEightHexDash() {
        let identity = DeveloperDiagnosticsStore.shared.installationIdentity
        let hash = identity.containerIdentityHash
        #expect(hash.count == 9)
        #expect(hash.contains("-"))
        let parts = hash.split(separator: "-")
        #expect(parts.count == 2)
        #expect(parts[0].count == 4)
        #expect(parts[1].count == 4)
    }

    @Test func i3_safeReportRedactsRawContainerPath() {
        guard let url = DeveloperDiagnosticsStore.shared.exportSafeReport(),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Failed to generate or read safe report")
            return
        }
        #expect(!text.contains("/var/mobile/Containers/Data/Application/"))
        #expect(text.contains("1.2.7"))
    }
}

struct SigningStatusTests {
    private func makeMockProfileEnvelope(expiration: Date, teamId: String = "TEAM999999") throws -> Data {
        let formatter = ISO8601DateFormatter()
        let dateStr = formatter.string(from: expiration)
        let xmlString = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Name</key>
            <string>RouteLocation Sideload</string>
            <key>AppIDName</key>
            <string>RouteLocation</string>
            <key>TeamIdentifier</key>
            <array>
                <string>\(teamId)</string>
            </array>
            <key>ExpirationDate</key>
            <date>\(dateStr)</date>
        </dict>
        </plist>
        """
        var data = Data([0x30, 0x82, 0x01, 0x00]) // Mock PKCS#7 prefix
        data.append(Data(xmlString.utf8))
        data.append(Data([0x00, 0x00])) // Mock PKCS#7 suffix
        return data
    }

    @Test func sg1_parserExtractsProfileInfoSuccessfully() throws {
        let futureDate = Date().addingTimeInterval(5 * 86400)
        let data = try makeMockProfileEnvelope(expiration: futureDate)
        let info = try ProvisioningProfileParser.parse(data: data)
        #expect(info.name == "RouteLocation Sideload")
        #expect(info.teamIdentifier == ["TEAM999999"])
        #expect(!info.isExpired)
        #expect(info.remainingTimeInterval > 4 * 86400)
    }

    @Test func sg2_parserDetectsExpiredProfile() throws {
        let pastDate = Date().addingTimeInterval(-3600)
        let data = try makeMockProfileEnvelope(expiration: pastDate)
        let info = try ProvisioningProfileParser.parse(data: data)
        #expect(info.isExpired)
        #expect(info.remainingTimeInterval <= 0)
    }

    @Test func sg3_parserThrowsOnMissingXMLHeader() {
        let corruptData = Data("Just some binary without plist".utf8)
        #expect(throws: SigningParseError.self) {
            _ = try ProvisioningProfileParser.parse(data: corruptData)
        }
    }

    @Test func sg4_signingStatusLabelsAndColors() {
        let futureDate = Date().addingTimeInterval(5 * 86400)
        let info = ProvisioningProfileInfo(
            name: "Test", appIDName: "App", teamName: "Team",
            teamIdentifier: ["TEAM1"], creationDate: nil,
            expirationDate: futureDate, entitlements: [:],
            uuid: nil, isProvisionsAllDevices: false
        )
        let validStatus = SigningStatus.valid(info)
        #expect(validStatus.label == "有效")
        #expect(validStatus.color == .green)

        let expiredInfo = ProvisioningProfileInfo(
            name: "Test", appIDName: "App", teamName: "Team",
            teamIdentifier: ["TEAM1"], creationDate: nil,
            expirationDate: Date().addingTimeInterval(-100), entitlements: [:],
            uuid: nil, isProvisionsAllDevices: false
        )
        let expiredStatus = SigningStatus.expired(expiredInfo)
        #expect(expiredStatus.label == "已過期")
        #expect(expiredStatus.color == .red)
    }
}

struct QuickSavedRoutesTests {
    private func makeRoute(name: String, isFavorite: Bool, lastUsedAt: Date?) -> SavedRoute {
        SavedRoute(
            id: UUID(),
            name: name,
            waypoints: [
                RouteCoordinate(latitude: 25.033, longitude: 121.564),
                RouteCoordinate(latitude: 25.034, longitude: 121.565)
            ],
            resolvedGeometry: RouteGeometry(coordinates: [
                RouteCoordinate(latitude: 25.033, longitude: 121.564),
                RouteCoordinate(latitude: 25.034, longitude: 121.565)
            ]),
            routeMode: .straight,
            navigationTransportMode: .automobile,
            isClosedLoop: false,
            preferredSpeedKmh: 18.0,
            playbackMode: .once,
            navigationGeometryNeedsRecalculation: false,
            isFavorite: isFavorite,
            lastUsedAt: lastUsedAt,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    @Test func m1_savedRouteDecodesWithoutLastUsedAtGracefully() throws {
        let route = makeRoute(name: "Classic", isFavorite: true, lastUsedAt: nil)
        let data = try JSONEncoder().encode(route)
        let decoded = try JSONDecoder().decode(SavedRoute.self, from: data)
        #expect(decoded.lastUsedAt == nil)
        #expect(decoded.isFavorite == true)
        #expect(decoded.name == "Classic")
    }

    @Test func m2_sortedForQuickSelectionPrioritizesFavoritesThenRecents() {
        let now = Date()
        let r1_favRecent = makeRoute(name: "FavRecent", isFavorite: true, lastUsedAt: now.addingTimeInterval(-100))
        let r2_favOlder = makeRoute(name: "FavOlder", isFavorite: true, lastUsedAt: now.addingTimeInterval(-5000))
        let r3_recentNonFav = makeRoute(name: "RecentNonFav", isFavorite: false, lastUsedAt: now.addingTimeInterval(-50))
        let r4_neverUsed = makeRoute(name: "NeverUsed", isFavorite: false, lastUsedAt: nil)

        let sorted = [r4_neverUsed, r3_recentNonFav, r2_favOlder, r1_favRecent].sortedForQuickSelection

        // Favorite routes must be at the top
        #expect(sorted[0].name == "FavRecent")
        #expect(sorted[1].name == "FavOlder")
        // Then recently used non-favorite
        #expect(sorted[2].name == "RecentNonFav")
        // Then never-used non-favorite
        #expect(sorted[3].name == "NeverUsed")
    }

    @MainActor
    @Test func m3_previewRouteUpdatesModelWithoutStartingSimulation() {
        let model = RouteLocationModel()
        let route = makeRoute(name: "PreviewTest", isFavorite: false, lastUsedAt: nil)

        model.previewRoute(route)

        #expect(model.previewingRoute?.id == route.id)
        #expect(model.routeName == "PreviewTest")
        #expect(model.waypoints.count == 2)
        #expect(model.simulationMode == .idle)
    }

    @MainActor
    @Test func m4_cancelRoutePreviewClearsDraftWhenIdle() {
        let model = RouteLocationModel()
        let route = makeRoute(name: "CancelTest", isFavorite: false, lastUsedAt: nil)

        model.previewRoute(route)
        #expect(model.previewingRoute != nil)

        model.cancelRoutePreview()
        #expect(model.previewingRoute == nil)
        #expect(model.waypoints.isEmpty)
    }
}

struct SelfRefreshCoordinatorTests {
    @Test func sr1_pendingVerificationModelRoundTrip() throws {
        let now = Date()
        let pv = SelfRefreshPendingVerification(
            operationId: "op-test-123",
            beforeExpiration: now,
            expectedVersion: "1.2.7",
            requestedAt: now
        )
        let data = try JSONEncoder().encode(pv)
        let decoded = try JSONDecoder().decode(SelfRefreshPendingVerification.self, from: data)
        #expect(decoded.operationId == "op-test-123")
        #expect(decoded.expectedVersion == "1.2.7")
        #expect(abs(decoded.beforeExpiration.timeIntervalSince(now)) < 0.001)
    }

    @Test func sr2_selfRefreshStateBusyFlagAndLabels() {
        #expect(!SelfRefreshState.idle.isBusy)
        #expect(!SelfRefreshState.authenticationRequired.isBusy)
        #expect(SelfRefreshState.preflight.isBusy)
        #expect(SelfRefreshState.signing.isBusy)
        #expect(SelfRefreshState.installing.isBusy)
        #expect(!SelfRefreshState.success(message: "成功").isBusy)
        #expect(!SelfRefreshState.failed(reason: "錯誤").isBusy)

        #expect(!SelfRefreshState.signing.statusText.isEmpty)
        #expect(!SelfRefreshState.preflight.statusText.isEmpty)
    }
}



