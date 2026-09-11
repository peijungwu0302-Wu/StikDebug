import Foundation
import MapKit

enum NavigationRouteError: LocalizedError {
    case insufficientWaypoints
    case failedSegment(index: Int, start: RouteCoordinate, end: RouteCoordinate, underlying: Error)
    case emptySegment(index: Int)

    var errorDescription: String? {
        switch self {
        case .insufficientWaypoints: return "計算導航路線前，請至少加入兩個航點。"
        case .failedSegment(let index, let start, let end, let underlying):
            return String(format: "第 %d 段導航失敗（%.6f, %.6f → %.6f, %.6f）：%@", index + 1, start.latitude, start.longitude, end.latitude, end.longitude, underlying.localizedDescription)
        case .emptySegment(let index): return "Apple 地圖沒有回傳第 \(index + 1) 段導航的路線資料。"
        }
    }
}

@MainActor
final class NavigationRouteResolver {
    private var activeDirections: MKDirections?

    func cancel() {
        activeDirections?.cancel()
        activeDirections = nil
    }

    func resolve(waypoints: [RouteCoordinate], closedLoop: Bool, transport: NavigationTransportMode) async throws -> RouteGeometry {
        guard waypoints.count >= 2 else { throw NavigationRouteError.insufficientWaypoints }
        cancel()
        var pairs = Array(zip(waypoints, waypoints.dropFirst()))
        if closedLoop, let first = waypoints.first, let last = waypoints.last, first != last { pairs.append((last, first)) }
        var allCoordinates: [RouteCoordinate] = []

        for (index, pair) in pairs.enumerated() {
            try Task.checkCancellation()
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: pair.0.clCoordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: pair.1.clCoordinate))
            request.transportType = transport.mapKitValue
            request.requestsAlternateRoutes = false
            let directions = MKDirections(request: request)
            activeDirections = directions
            do {
                let response = try await directions.calculate()
                guard let route = response.routes.first else { throw NavigationRouteError.emptySegment(index: index) }
                var segment = route.polyline.routeCoordinates.map(RouteCoordinate.init)
                guard !segment.isEmpty else { throw NavigationRouteError.emptySegment(index: index) }
                if allCoordinates.last == segment.first { segment.removeFirst() }
                allCoordinates.append(contentsOf: segment)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as NavigationRouteError {
                throw error
            } catch {
                throw NavigationRouteError.failedSegment(index: index, start: pair.0, end: pair.1, underlying: error)
            }
        }
        activeDirections = nil
        let geometry = RouteGeometry(coordinates: allCoordinates)
        guard geometry.coordinates.count > 1, geometry.totalDistance > 0 else { throw NavigationRouteError.emptySegment(index: 0) }
        return geometry
    }
}

private extension MKPolyline {
    var routeCoordinates: [CLLocationCoordinate2D] {
        var values = [CLLocationCoordinate2D](repeating: .init(), count: pointCount)
        getCoordinates(&values, range: NSRange(location: 0, length: pointCount))
        return values
    }
}
