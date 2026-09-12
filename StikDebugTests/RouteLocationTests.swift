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
        try await Task.sleep(for: .milliseconds(60))
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
        model.simulationMode = .idle
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
