import Foundation
import MapKit
import Testing
@testable import RouteLocation

/// External-service gate, run separately from deterministic unit tests in CI.
/// These public demo coordinates are not pairing/device/user information.
@MainActor
struct SmartRouteLiveMapKitTests {
    @Test(.timeLimit(.minutes(3))) func taipeiFiveKilometerRoadLoopUsesRealMapKitGeometry() async throws {
        let provider = RecordingMapKitRoadProvider()
        let candidate = try await SmartRouteGenerator(provider: provider).generate(
            center: RouteCoordinate(latitude: 25.033964, longitude: 121.564468), options: .init())
        #expect(candidate.kind == .loop)
        #expect(abs(candidate.deviation) <= 0.20 + 1e-9)
        #expect(candidate.geometry.coordinates.first == candidate.geometry.coordinates.last)
        #expect(candidate.geometry.coordinates.count > candidate.waypoints.count)
        #expect(provider.navigationRequests <= 12)
        let retained = Set(candidate.geometry.coordinates)
        var matchingRoad: [RouteCoordinate]?
        for legs in provider.attempts {
            guard legs.count == 4 else { continue }
            let raw = legs.flatMap { $0.coordinates }
            if retained.isSubset(of: Set(raw)) { matchingRoad = raw; break }
        }
        let original = try #require(matchingRoad, "Every retained vertex must come from the actual MapKit response")
        let maximumDeviation = original.map { distanceToRoad($0, candidate.geometry.coordinates) }.max() ?? .infinity
        #expect(maximumDeviation <= 3.1)
        let report: [String: Any] = [
            "service": "Apple MapKit (live)", "targetMeters": 5_000,
            "actualMeters": candidate.geometry.totalDistance, "deviationPercent": candidate.deviation * 100,
            "controlPoints": candidate.waypoints.count, "roadVertices": candidate.geometry.coordinates.count,
            "maximumRoadDeviationMeters": maximumDeviation, "navigationRequests": provider.navigationRequests,
            "closed": true
        ]
        print("SMART_ROUTE_LIVE_REPORT " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: .sortedKeys), as: UTF8.self))
    }

    private func distanceToRoad(_ value: RouteCoordinate, _ road: [RouteCoordinate]) -> Double {
        let point = MKMapPoint(value.clCoordinate)
        return zip(road, road.dropFirst()).map { a, b in
            let start = MKMapPoint(a.clCoordinate), end = MKMapPoint(b.clCoordinate)
            let dx = end.x - start.x, dy = end.y - start.y
            let denominator = dx * dx + dy * dy
            let fraction = denominator > 0 ? min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / denominator)) : 0
            return point.distance(to: MKMapPoint(x: start.x + fraction * dx, y: start.y + fraction * dy))
        }.min() ?? .infinity
    }
}

@MainActor private final class RecordingMapKitRoadProvider: SmartRoadProviding {
    private let live = MapKitSmartRoadProvider()
    var legs: [RouteGeometry] = []
    var attempts: [[RouteGeometry]] = []
    var navigationRequests = 0
    private var initialSource: RouteCoordinate?
    func nearbyLocations(center: RouteCoordinate, radius: Double) async throws -> [RouteCoordinate] {
        try await live.nearbyLocations(center: center, radius: radius)
    }
    func route(from: RouteCoordinate, to: RouteCoordinate, transport: NavigationTransportMode) async throws -> RouteGeometry {
        if initialSource == nil { initialSource = from }
        if attempts.isEmpty || from == initialSource { attempts.append([]) }
        navigationRequests += 1
        let value = try await live.route(from: from, to: to, transport: transport)
        legs.append(value)
        attempts[attempts.count - 1].append(value)
        return value
    }
    func cancel() { live.cancel() }
}
