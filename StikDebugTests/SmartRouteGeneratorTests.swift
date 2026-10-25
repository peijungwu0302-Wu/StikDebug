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

    @Test func simplificationKeepsSharpRoadTurnsAndRejectsDisconnectedSeams() throws {
        let road = [a, b, c, d, a]
        #expect(SmartRouteQuality.simplify(road, tolerance: 2) == road)
        #expect(throws: SmartRouteError.self) {
            try SmartRouteQuality.join([[a, b], [c, d, a]])
        }
        let joined = try SmartRouteQuality.join([[a, b], [b, c], [c, d], [d, a]])
        #expect(joined == road)
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
}

@MainActor
private final class FakeSmartRoadProvider: SmartRoadProviding {
    let locations: [RouteCoordinate]
    var segments: [[RouteCoordinate]]
    var requests: [SmartRoadRequest] = []
    init(locations: [RouteCoordinate], segments: [[RouteCoordinate]]) { self.locations = locations; self.segments = segments }
    func nearbyLocations(center: RouteCoordinate, radius: Double) async throws -> [RouteCoordinate] { locations }
    func route(from: RouteCoordinate, to: RouteCoordinate, transport: NavigationTransportMode) async throws -> RouteGeometry {
        requests.append(.init(from: from, to: to))
        guard !segments.isEmpty else { throw SmartRouteError.unavailable }
        return RouteGeometry(coordinates: segments.removeFirst())
    }
    func cancel() {}
}
