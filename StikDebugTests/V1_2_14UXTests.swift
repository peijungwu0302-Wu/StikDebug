import Foundation
import Testing
@testable import RouteLocation

struct V1_2_14UXTests {
    @Test func uniqueNamesUseIndependentSuffixesAndNormalizeWhitespace() {
        #expect(UniqueNameGenerator.makeUnique(base: " 新地點 ", existing: ["新地點", "新地點1", "新地點2"], fallback: "新地點") == "新地點3")
        #expect(UniqueNameGenerator.makeUnique(base: "公司", existing: ["公司", "公司1"], fallback: "新地點") == "公司2")
        #expect(UniqueNameGenerator.makeUnique(base: "公司", existing: ["公司11"], fallback: "新地點") == "公司")
        #expect(UniqueNameGenerator.makeUnique(base: "", existing: ["新路線"], fallback: "新路線") == "新路線1")
    }

    @Test func parserAcceptsLabeledAndGoogleMapsCoordinates() throws {
        #expect(try CoordinateImportParser.parseInline("latitude=25.033964 longitude=121.564468").first == RouteCoordinate(latitude: 25.033964, longitude: 121.564468))
        #expect(try CoordinateImportParser.parseInline("https://maps.google.com/maps/@25.033964,121.564468,17z").first == RouteCoordinate(latitude: 25.033964, longitude: 121.564468))
        #expect(try CoordinateImportParser.parseInline("25.033964 121.564468").first == RouteCoordinate(latitude: 25.033964, longitude: 121.564468))
    }

    @Test func timezoneComparisonUsesTaiwanBaseline() {
        let taipei = TimeZone(identifier: "Asia/Taipei")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let taipeiText = PlaceTimeFormatter.offsetText(for: taipei)
        #expect(taipeiText == "與台灣時間相同" || taipeiText == "Same as Taiwan time")
        let tokyoText = PlaceTimeFormatter.offsetText(for: tokyo)
        #expect(tokyoText.contains("快") || tokyoText.contains("ahead"))
    }

    @Test func routeAppendPreservesExistingWaypoints() {
        let first = RouteCoordinate(latitude: 25, longitude: 121)
        let second = RouteCoordinate(latitude: 25.01, longitude: 121.01)
        var values = [first]
        values.append(contentsOf: [second, second])
        #expect(values.count == 3)
    }

    @Test func stalePreparedRecoveryIsDistinctFromColdStartEvidence() {
        #expect(AssistedBootstrapReason.coldStart.usesRecentSuccessEvidence)
        #expect(!AssistedBootstrapReason.stalePreparedSessionRecovery.usesRecentSuccessEvidence)
        #expect(!AssistedBootstrapReason.playbackFailureRecovery.usesRecentSuccessEvidence)
        #expect(PreparedSessionRecoveryPolicy.shouldForceAssistedRecovery(
            preparedSession: true, transport: .cellular, wifiAvailable: false, shortcutAssistedEnabled: true
        ))
        #expect(!PreparedSessionRecoveryPolicy.shouldForceAssistedRecovery(
            preparedSession: true, transport: .cellular, wifiAvailable: true, shortcutAssistedEnabled: true
        ))
    }

    @Test @MainActor func confirmedStaleSessionInvalidatesOnlyRecentSuccessEvidence() {
        let health = LocationDataPathHealth.shared
        health.resetForTesting()
        health.recordSuccess()
        #expect(health.hasRecentSuccess)
        health.invalidateAfterConfirmedStaleSessionFailure(LocationSimulationError.deviceTunnelUnavailable)
        #expect(!health.hasRecentSuccess)
        #expect(health.status == .failed)
        health.resetForTesting()
    }

    @Test func timezoneBaselineChangesComparisonWording() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(PlaceTimeFormatter.offsetText(for: tokyo, at: date, baseline: .taiwan).contains("台灣") ||
                PlaceTimeFormatter.offsetText(for: tokyo, at: date, baseline: .taiwan).contains("Taiwan"))
        #expect(PlaceTimeFormatter.offsetText(for: tokyo, at: date, baseline: .device).contains("目前") ||
                PlaceTimeFormatter.offsetText(for: tokyo, at: date, baseline: .device).contains("current"))
    }

    @Test func resolverSharesSameKeyAndSerializesDifferentKeys() async {
        let client = TestPlaceGeocodingClient()
        let resolver = PlaceInfoResolver(
            cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            geocoder: client
        )
        let first = RouteCoordinate(latitude: 25.033964, longitude: 121.564468)
        let second = RouteCoordinate(latitude: 35.689487, longitude: 139.691711)
        async let firstValue = resolver.resolve(first, debounceNanoseconds: 0)
        async let firstDuplicate = resolver.resolve(first, debounceNanoseconds: 0)
        async let secondValue = resolver.resolve(second, debounceNanoseconds: 0)
        _ = await (firstValue, firstDuplicate, secondValue)
        #expect(await client.maximumConcurrentRequests() == 1)
        #expect(await client.requestCount() == 2)
    }

    @Test func selectedResolverRequestCanBeSuperseded() async {
        let client = TestPlaceGeocodingClient(blockRequests: true)
        let resolver = PlaceInfoResolver(
            cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            geocoder: client
        )
        let first = RouteCoordinate(latitude: 25.033964, longitude: 121.564468)
        let second = RouteCoordinate(latitude: 35.689487, longitude: 139.691711)
        let firstTask = Task { await resolver.resolve(first, debounceNanoseconds: 0, scope: .selected) }
        await client.waitUntilStarted()
        let secondTask = Task { await resolver.resolve(second, debounceNanoseconds: 0, scope: .selected) }
        await client.releaseAll()
        _ = await firstTask.value
        _ = await secondTask.value
        #expect(await client.requestCount() == 2)
    }

    @Test func placeInfoFailureIsSilentFallback() async {
        let client = TestPlaceGeocodingClient(shouldFail: true)
        let resolver = PlaceInfoResolver(
            cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            geocoder: client
        )
        #expect(await resolver.resolve(RouteCoordinate(latitude: 25, longitude: 121), debounceNanoseconds: 0) == nil)
    }

    @Test @MainActor func routeFavoriteActionPersistsDraftWithoutDuplicateCopy() async {
        let store = RoutePersistenceStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = RouteLocationModel(persistence: store, simulationService: NoopLocationSink())
        model.addWaypoint(RouteCoordinate(latitude: 25, longitude: 121))
        model.addWaypoint(RouteCoordinate(latitude: 25.01, longitude: 121.01))
        #expect(await model.favoriteCurrentRoute(named: "新路線"))
        #expect(model.favoriteRoutes.count == 1)
        #expect(model.savedRoutes.count == 1)
        #expect(model.favoriteRoutes.first?.isFavorite == true)
    }

    @Test @MainActor func stopInvalidatesInFlightPlaybackRecovery() async throws {
        let sink = FailingSequenceSink()
        await sink.configureFailures([2, 3, 4, 5, 6])
        let gate = AsyncGate()
        let clock = TestUptimeBox()
        let geometry = RouteGeometry(coordinates: [
            RouteCoordinate(latitude: 0, longitude: 0),
            RouteCoordinate(latitude: 0, longitude: 0.01)
        ])
        let monitor = ConnectionMonitor()
        monitor.updateForTesting(transport: .cellular, isWifiAvailable: false, isCellularAvailable: true, deviceSession: .idle)
        let engine = RoutePlaybackEngine(
            sink: sink, connectionMonitor: monitor, updateInterval: 60, uptime: { clock.get() },
            acquireKeepAlive: {}, releaseKeepAlive: {}, reconnectAction: {},
            reconnectDelays: [0], transportDebounce: 0
        )
        let started = AsyncSignal()
        engine.assistedRecoveryAction = { (_: RouteCoordinate?) in
            await started.signal()
            await gate.wait()
            return true
        }
        try await engine.start(routeName: "Cancel", geometry: geometry, speedKmh: 18.6, mode: RoutePlaybackMode.once)
        clock.set(10)
        await engine.verifyConnectionAfterTransportChange()
        await engine.verifyConnectionAfterTransportChange()
        let recoveryTask = Task { await engine.verifyConnectionAfterTransportChange() }
        await started.wait()
        engine.stop()
        await gate.signal()
        await recoveryTask.value
        #expect(engine.state == PlaybackRunState.stopped)
    }
}

private final class TestUptimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func get() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set(_ value: TimeInterval) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private actor TestPlaceGeocodingClient: PlaceGeocodingClient {
    private let shouldFail: Bool
    private let blockRequests: Bool
    private var requests = 0
    private var active = 0
    private var maximumActive = 0
    private var startedCount = 0
    private var released = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(shouldFail: Bool = false, blockRequests: Bool = false) {
        self.shouldFail = shouldFail
        self.blockRequests = blockRequests
    }

    func reverseGeocode(_ coordinate: RouteCoordinate) async throws -> PlaceGeocodingResult? {
        requests += 1
        active += 1
        maximumActive = max(maximumActive, active)
        startedCount += 1
        startedContinuation?.resume()
        startedContinuation = nil
        if blockRequests && !released {
            await withCheckedContinuation { continuation in releaseContinuation = continuation }
        }
        active -= 1
        if shouldFail { throw NSError(domain: "test", code: 1) }
        return PlaceGeocodingResult(
            displayName: "Test",
            country: "Taiwan",
            countryCode: "TW",
            administrativeArea: "Taipei",
            locality: "Taipei",
            subLocality: "Xinyi",
            timeZoneIdentifier: "Asia/Taipei"
        )
    }

    func requestCount() -> Int { requests }
    func maximumConcurrentRequests() -> Int { maximumActive }
    func waitUntilStarted() async {
        if startedCount > 0 { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }
    func releaseAll() { released = true; releaseContinuation?.resume(); releaseContinuation = nil }
}

private actor AsyncSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false
    func signal() { signaled = true; continuation?.resume(); continuation = nil }
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false
    func signal() {
        signaled = true
        continuation?.resume()
        continuation = nil
    }
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private actor NoopLocationSink: LocationSimulationSink {
    func setCoordinate(_ coordinate: RouteCoordinate) async throws {}
    func clearSimulatedLocation() async throws {}
}

private actor FailingSequenceSink: LocationSimulationSink {
    private var call = 0
    private var failures: Set<Int> = []

    func configureFailures(_ values: [Int]) { failures = Set(values) }

    func setCoordinate(_ coordinate: RouteCoordinate) async throws {
        call += 1
        if failures.contains(call) { throw LocationSimulationError.updateFailure(code: Int32(call)) }
    }

    func clearSimulatedLocation() async throws {}
}
