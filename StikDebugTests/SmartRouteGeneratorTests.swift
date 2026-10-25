import Foundation
import CoreLocation
import Testing
@testable import RouteLocation

@MainActor
struct SmartRouteGeneratorTests {
    private let a = RouteCoordinate(latitude: 25, longitude: 121)
    private let b = RouteCoordinate(latitude: 25, longitude: 121.01)
    private let c = RouteCoordinate(latitude: 25.01, longitude: 121.01)
    private let d = RouteCoordinate(latitude: 25.01, longitude: 121)

    @Test func defaultsAndDistanceBandsUseActualGeometry() {
        let options = SmartRouteOptions()
        #expect(options.targetDistance == 5_000)
        #expect(options.preferredWaypointCount == 8)
        #expect(options.speedKmh == 18.6)
        #expect(options.playbackMode == .infiniteLoop)
        #expect(options.transport == .walking)
        #expect(options.kind == .loop)
        #expect(SmartRouteQuality.distanceBand(actual: 4_300, target: 5_000) == .preferred)
        #expect(SmartRouteQuality.distanceBand(actual: 4_050, target: 5_000) == .relaxed)
        #expect(SmartRouteQuality.distanceBand(actual: 3_900, target: 5_000) == nil)
        #expect(SmartRouteQuality.distanceBand(actual: .nan, target: 5_000) == nil)
    }

    @Test func fullRoadGeometrySurvivesControlPointReductionAndCodable() throws {
        let coordinates = [a, RouteCoordinate(latitude: 25, longitude: 121.005), b, c, d, a]
        let candidate = try SmartRouteCandidate.make(geometry: RouteGeometry(coordinates: coordinates), options: SmartRouteOptions(targetDistance: 4_200), kind: .loop)
        #expect(candidate.waypoints.count != 8)
        #expect(candidate.geometry.coordinates == coordinates)
        let saved = candidate.savedRoute(name: "Road", speedKmh: 18.6, playbackMode: .infiniteLoop)
        let decoded = try JSONDecoder().decode(SavedRoute.self, from: JSONEncoder().encode(saved))
        #expect(decoded.routeMode == .navigation)
        #expect(decoded.resolvedGeometry == candidate.geometry)
        #expect(!decoded.navigationGeometryNeedsRecalculation)
        #expect(decoded.isClosedLoop)
        #expect(decoded.resolvedGeometry.coordinates.first == decoded.resolvedGeometry.coordinates.last)
        #expect(decoded.waypoints.count < decoded.resolvedGeometry.coordinates.count)
    }

    @Test func preferredDistanceAlwaysRanksBeforeRelaxedQualityScore() {
        #expect(SmartRouteQuality.isBetter(relaxed: false, score: 1.20, thanRelaxed: true, score: 0.90))
        #expect(!SmartRouteQuality.isBetter(relaxed: true, score: 0.90, thanRelaxed: false, score: 1.20))
        #expect(SmartRouteQuality.isBetter(relaxed: false, score: 0.50, thanRelaxed: false, score: 1.20))
        #expect(!SmartRouteQuality.isBetter(relaxed: true, score: 1.20, thanRelaxed: true, score: 0.90))
    }

    @Test func simplificationKeepsSharpRoadTurnsAndRejectsDisconnectedSeams() throws {
        let road = [a, b, c, d, a]
        #expect(SmartRouteQuality.simplify(road, tolerance: 2) == road)
        #expect(throws: SmartRouteError.self) {
            try SmartRouteQuality.join([[a, b], [c, d, a]])
        }
        let joined = try SmartRouteQuality.join([[a, b], [b, c], [c, d], [d, a]])
        #expect(joined == road)
    }

    @Test func retracingIsNotMislabelledAsAnOrdinaryLoop() {
        #expect(SmartRouteQuality.repeatedRoadFraction(RouteGeometry(coordinates: [a, b, a])) > 0.8)
        #expect(SmartRouteQuality.repeatedRoadFraction(RouteGeometry(coordinates: [a, b, c, d, a])) < 0.1)
    }

    @Test func explicitOutAndBackRequestsTheReturnDirection() async throws {
        let provider = FakeSmartRoadProvider(locations: [b], segments: [[a, b], [b, c, a]])
        let generator = SmartRouteGenerator(provider: provider)
        let target = RouteGeometry(coordinates: [a, b, c, a]).totalDistance
        let result = try await generator.generate(center: a, options: SmartRouteOptions(targetDistance: target, kind: .outAndBack))
        #expect(result.kind == .outAndBack)
        #expect(provider.requests == [SmartRoadRequest(from: a, to: b), SmartRoadRequest(from: b, to: a)])
        #expect(result.geometry.coordinates.contains(c))
        #expect(result.geometry.coordinates.first == result.geometry.coordinates.last)
    }

    @Test func failuresAndCancellationNeverBecomeStraightRoutes() async {
        let provider = FakeSmartRoadProvider(locations: [b, c, d], segments: [])
        do {
            _ = try await SmartRouteGenerator(provider: provider).generate(center: a, options: .init())
            Issue.record("Unavailable roads must not produce a straight candidate")
        } catch { #expect(provider.requests.count <= 12) }
        let cancelled = Task { @MainActor in
            try Task.checkCancellation()
            return try await SmartRouteGenerator(provider: provider).generate(center: a, options: .init())
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Cancelled generation returned a candidate") }
        catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
    }

    @Test func noAvailableNearbyNodesFailsWithoutDirections() async {
        let provider = FakeSmartRoadProvider(locations: [], segments: [])
        do { _ = try await SmartRouteGenerator(provider: provider).generate(center: a, options: .init()); Issue.record("Expected unavailable roads") }
        catch { #expect(provider.requests.isEmpty) }
    }

    @Test func pacingUsesMonotonicDeadlineWithoutSleepingInTests() {
        let now = ContinuousClock.now
        #expect(SmartRouteRequestPacing.next(after: nil, now: now) == now)
        #expect(SmartRouteRequestPacing.next(after: now, now: now) == now.advanced(by: .milliseconds(350)))
        let later = now.advanced(by: .seconds(2))
        #expect(SmartRouteRequestPacing.next(after: now, now: later) == later)
    }

    @Test(arguments: [SmartRouteError.timedOut, .throttled])
    func serviceLimitsAbortWithoutTryingMoreCandidates(_ failure: SmartRouteError) async {
        let provider = FakeSmartRoadProvider(locations: [b, c, d], segments: [], failure: failure)
        do { _ = try await SmartRouteGenerator(provider: provider).generate(center: a, options: .init()); Issue.record("Expected service limit") }
        catch let error as SmartRouteError { #expect(String(describing: error) == String(describing: failure)) }
        catch { Issue.record("Unexpected error \(error)") }
        #expect(provider.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func lateCancelledGenerationCannotReplaceNewPreview() async throws {
        let old = SuspendedSmartRoadProvider()
        defer { old.release() }
        let fresh = FakeSmartRoadProvider(locations: [b], segments: [[a, b], [b, c, a]])
        var count = 0
        let session = SmartRouteGenerationSession {
            count += 1
            if count == 1 { return SmartRouteGenerator(provider: old) }
            return SmartRouteGenerator(provider: fresh)
        }
        let target = RouteGeometry(coordinates: [a, b, c, a]).totalDistance
        let options = SmartRouteOptions(targetDistance: target, kind: .outAndBack)
        let first = session.generate(center: a, options: options)
        #expect(await old.started.wait(timeout: .seconds(3)))
        let second = session.generate(center: a, options: options)
        await second.value
        let id = try #require(session.candidate?.id)
        old.release()
        await first.value
        #expect(session.candidate?.id == id)
        #expect(session.error == nil)
        #expect(!session.isGenerating)
        session.invalidate()
        #expect(session.candidate == nil)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingGenerationPublishesNoCandidate() async {
        let provider = SuspendedSmartRoadProvider()
        defer { provider.release() }
        let session = SmartRouteGenerationSession { SmartRouteGenerator(provider: provider) }
        let task = session.generate(center: a, options: .init())
        #expect(await provider.started.wait(timeout: .seconds(3)))
        session.cancel()
        provider.release()
        await task.value
        #expect(session.candidate == nil)
        #expect(session.error == nil)
        #expect(!session.isGenerating)
    }

    @Test func unsuccessfulSearchStopsAtTwelveNavigationRequests() async {
        let nodes = [b, c, d,
                     RouteCoordinate(latitude: 24.99, longitude: 121),
                     RouteCoordinate(latitude: 24.99, longitude: 121.01),
                     RouteCoordinate(latitude: 25, longitude: 120.99),
                     RouteCoordinate(latitude: 25.01, longitude: 120.99)]
        let provider = FakeSmartRoadProvider(locations: nodes, segments: [])
        provider.useDirectGeometry = true
        do {
            _ = try await SmartRouteGenerator(provider: provider).generate(center: a, options: .init(targetDistance: 50_000))
            Issue.record("Short nearby roads cannot satisfy a 50 km target")
        } catch SmartRouteError.noMatchingRoute {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(provider.requests.count == 12)
    }
}

@MainActor
private final class FakeSmartRoadProvider: SmartRoadProviding {
    let locations: [RouteCoordinate]
    var segments: [[RouteCoordinate]]
    var requests: [SmartRoadRequest] = []
    var useDirectGeometry = false
    let failure: SmartRouteError?
    init(locations: [RouteCoordinate], segments: [[RouteCoordinate]], failure: SmartRouteError? = nil) {
        self.locations = locations; self.segments = segments; self.failure = failure
    }
    func nearbyLocations(center: RouteCoordinate, radius: Double) async throws -> [RouteCoordinate] { locations }
    func route(from: RouteCoordinate, to: RouteCoordinate, transport: NavigationTransportMode) async throws -> RouteGeometry {
        requests.append(.init(from: from, to: to))
        if let failure { throw failure }
        if useDirectGeometry { return RouteGeometry(coordinates: [from, to]) }
        guard !segments.isEmpty else { throw SmartRouteError.unavailable }
        return RouteGeometry(coordinates: segments.removeFirst())
    }
    func cancel() {}
}

@MainActor private final class SuspendedSmartRoadProvider: SmartRoadProviding {
    let started = SmartRouteTestSignal()
    private var continuation: CheckedContinuation<[RouteCoordinate], Error>?
    func nearbyLocations(center: RouteCoordinate, radius: Double) async throws -> [RouteCoordinate] {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            Task { await started.signal() }
        }
    }
    func route(from: RouteCoordinate, to: RouteCoordinate, transport: NavigationTransportMode) async throws -> RouteGeometry { throw SmartRouteError.unavailable }
    func cancel() {} // Deliberately non-cooperative service, resumed by the test.
    func release() { continuation?.resume(returning: []); continuation = nil }
}

private actor SmartRouteTestSignal {
    private var signaled = false
    private var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    func signal() { signaled = true; waiters.values.forEach { $0.yield(()) }; waiters.removeAll() }
    func wait(timeout: Duration) async -> Bool {
        if signaled { return true }
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        waiters[id] = continuation
        let result = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in stream { return true }; return false }
            group.addTask { do { try await Task.sleep(for: timeout) } catch {}; return false }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        continuation.finish(); waiters.removeValue(forKey: id)
        return result
    }
}
