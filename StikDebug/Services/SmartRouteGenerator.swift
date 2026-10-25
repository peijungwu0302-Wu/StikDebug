import Foundation
import MapKit
import Combine

enum SmartRouteKind: String, CaseIterable, Identifiable {
    case loop, outAndBack
    var id: String { rawValue }
    var title: String { L10n.text(self == .loop ? "道路環狀路線" : "已驗證折返路線") }
}

enum SmartRouteOriginRole: String, CaseIterable, Identifiable {
    case start, nearbyCenter
    var id: String { rawValue }
    var title: String { L10n.text(self == .start ? "作為起點" : "搜尋附近起點") }
}

struct SmartRouteOptions {
    var targetDistance: Double = 5_000
    var preferredWaypointCount: Int = 8
    var speedKmh: Double = 18.6
    var playbackMode: RoutePlaybackMode = .infiniteLoop
    var transport: NavigationTransportMode = .walking
    var kind: SmartRouteKind = .loop
    var originRole: SmartRouteOriginRole = .start
    var variation: Int = 0

    var isValid: Bool {
        targetDistance.isFinite && (500...50_000).contains(targetDistance)
            && (3...24).contains(preferredWaypointCount)
    }
}

enum SmartRouteError: LocalizedError {
    case invalidSettings, unavailable, insufficientRoads, disconnected, noMatchingRoute, timedOut, throttled
    var errorDescription: String? {
        switch self {
        case .invalidSettings: return L10n.text("請選擇 0.5–50 公里及 3–24 個建議航點。")
        case .unavailable: return L10n.text("目前無法取得 Apple 地圖導航資料，請稍後重試或手動建立路線。")
        case .insufficientRoads: return L10n.text("附近可用地點不足；山區或步道資料可能不完整，請更換位置或手動建立路線。")
        case .disconnected: return L10n.text("導航路段無法安全連接，未建立任何直線補接。")
        case .noMatchingRoute: return L10n.text("有限次嘗試未找到目標距離 ±20% 內的有效道路路線。可調整條件，或明確改試折返。")
        case .timedOut: return L10n.text("導航服務逾時，請稍後重試。")
        case .throttled: return L10n.text("Apple 地圖暫時限制導航請求，請稍後重試。")
        }
    }
}

struct SmartRoadRequest: Equatable {
    let from: RouteCoordinate
    let to: RouteCoordinate
}

enum SmartRouteRequestPacing {
    static func next(after last: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        guard let last else { return now }
        return max(now, last.advanced(by: .milliseconds(350)))
    }
}

@MainActor
protocol SmartRoadProviding: AnyObject {
    func nearbyLocations(center: RouteCoordinate, radius: Double) async throws -> [RouteCoordinate]
    func route(from: RouteCoordinate, to: RouteCoordinate, transport: NavigationTransportMode) async throws -> RouteGeometry
    func cancel()
}

/// Owns only MapKit requests. It never touches device sessions or simulation.
@MainActor
final class MapKitSmartRoadProvider: SmartRoadProviding {
    private let resolver = NavigationRouteResolver()
    private var search: MKLocalSearch?
    private var lastRequest: ContinuousClock.Instant?
    let timeoutSeconds: Double
    init(timeoutSeconds: Double = 12) { self.timeoutSeconds = timeoutSeconds }

    func cancel() { search?.cancel(); resolver.cancel() }

    private func pace() async throws {
        let next = SmartRouteRequestPacing.next(after: lastRequest, now: .now)
        if ContinuousClock.now < next { try await Task.sleep(until: next, clock: .continuous) }
        try Task.checkCancellation()
        lastRequest = .now
    }

    private func timed<T: Sendable>(_ operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask { @MainActor [self] in
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    cancel()
                    throw SmartRouteError.timedOut
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw CancellationError() }
                try Task.checkCancellation()
                return value
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func nearbyLocations(center: RouteCoordinate, radius: Double) async throws -> [RouteCoordinate] {
        try await pace()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "park"
        request.resultTypes = .pointOfInterest
        request.region = MKCoordinateRegion(center: center.clCoordinate, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        let operation = MKLocalSearch(request: request)
        search = operation
        defer { search = nil }
        do {
            return try await timed {
                let response = try await operation.start()
                return response.mapItems.map { RouteCoordinate($0.placemark.coordinate) }
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as SmartRouteError { throw error }
        catch { throw mapError(error) }
    }

    func route(from: RouteCoordinate, to: RouteCoordinate, transport: NavigationTransportMode) async throws -> RouteGeometry {
        try await pace()
        do {
            return try await timed { [self] in
                try await resolver.resolve(waypoints: [from, to], closedLoop: false, transport: transport)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as SmartRouteError { throw error }
        catch let NavigationRouteError.failedSegment(_, _, _, underlying) { throw mapError(underlying) }
        catch { throw mapError(error) }
    }

    private func mapError(_ error: Error) -> SmartRouteError {
        let value = error as NSError
        if value.domain == MKErrorDomain {
            if value.code == MKError.Code.loadingThrottled.rawValue { return .throttled }
            if value.code == MKError.Code.directionsNotFound.rawValue { return .disconnected }
        }
        return .unavailable
    }
}

struct SmartRouteCandidate: Identifiable {
    let id = UUID()
    let geometry: RouteGeometry
    let waypoints: [RouteCoordinate]
    let options: SmartRouteOptions
    let kind: SmartRouteKind
    var deviation: Double { (geometry.totalDistance - options.targetDistance) / options.targetDistance }
    var usesRelaxedDistance: Bool { abs(deviation) > 0.15 }

    static func make(geometry: RouteGeometry, options: SmartRouteOptions, kind: SmartRouteKind) throws -> Self {
        guard options.isValid,
              geometry.coordinates.count >= 3, geometry.coordinates.count <= 20_000,
              geometry.coordinates.allSatisfy(\.isValid),
              geometry.coordinates.allSatisfy({ let point = MKMapPoint($0.clCoordinate); return point.x.isFinite && point.y.isFinite }),
              zip(geometry.coordinates, geometry.coordinates.dropFirst()).allSatisfy({ abs($0.0.longitude - $0.1.longitude) <= 180 }),
              geometry.coordinates.first == geometry.coordinates.last,
              SmartRouteQuality.distanceBand(actual: geometry.totalDistance, target: options.targetDistance) != nil else {
            throw SmartRouteError.noMatchingRoute
        }
        let controls = SmartRouteQuality.controlPoints(geometry.coordinates, preferredCount: options.preferredWaypointCount)
        guard controls.count >= 2 else { throw SmartRouteError.disconnected }
        return Self(geometry: geometry, waypoints: controls, options: options, kind: kind)
    }

    func savedRoute(name: String, speedKmh: Double, playbackMode: RoutePlaybackMode) -> SavedRoute {
        SavedRoute(name: name, waypoints: waypoints, resolvedGeometry: geometry, routeMode: .navigation,
                   navigationTransportMode: options.transport, isClosedLoop: true,
                   preferredSpeedKmh: PlaybackSpeedPolicy.clamp(speedKmh), playbackMode: playbackMode,
                   navigationGeometryNeedsRecalculation: false)
    }
}

enum SmartRouteQuality {
    enum DistanceBand { case preferred, relaxed }
    static func distanceBand(actual: Double, target: Double) -> DistanceBand? {
        guard actual.isFinite, target.isFinite, actual > 0, target > 0 else { return nil }
        let error = abs(actual / target - 1)
        if error <= 0.15 + 1e-9 { return .preferred }
        return error <= 0.20 + 1e-9 ? .relaxed : nil
    }

    static func meters(_ a: RouteCoordinate, _ b: RouteCoordinate) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// MapKit endpoints may differ by a tiny centerline snap; reject larger
    /// gaps rather than inventing a bridge, including at the lap boundary.
    static func join(_ legs: [[RouteCoordinate]]) throws -> [RouteCoordinate] {
        var result: [RouteCoordinate] = []
        for leg in legs {
            guard leg.count > 1, leg.allSatisfy(\.isValid) else { throw SmartRouteError.disconnected }
            if let last = result.last, let first = leg.first {
                guard meters(last, first) <= 3 else { throw SmartRouteError.disconnected }
            }
            if result.last == leg.first { result.append(contentsOf: leg.dropFirst()) }
            else { result.append(contentsOf: leg) }
            guard result.count <= 20_000 else { throw SmartRouteError.disconnected }
        }
        guard let first = result.first, let last = result.last, meters(first, last) <= 3 else { throw SmartRouteError.disconnected }
        result[result.count - 1] = first
        return result
    }

    /// Iterative Douglas–Peucker. Full geometry is kept unless all removed
    /// road vertices stay within 2 m and measured distance changes by <0.5%.
    static func simplify(_ values: [RouteCoordinate], tolerance: Double) -> [RouteCoordinate] {
        guard values.count > 2 else { return values }
        let points = values.map { MKMapPoint($0.clCoordinate) }
        var keep: Set<Int> = [0, values.count - 1]
        var work = [(0, values.count - 1)]
        while let (start, end) = work.popLast() {
            if Task.isCancelled { return values }
            guard end > start + 1 else { continue }
            let a = points[start], b = points[end]
            let dx = b.x - a.x, dy = b.y - a.y, denominator = dx * dx + dy * dy
            var maximum = tolerance
            var farthest: Int?
            for index in (start + 1)..<end {
                let p = points[index]
                let t = denominator > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / denominator)) : 0
                let distance = p.distance(to: MKMapPoint(x: a.x + t * dx, y: a.y + t * dy))
                if distance > maximum { maximum = distance; farthest = index }
            }
            if let index = farthest { keep.insert(index); work.append((start, index)); work.append((index, end)) }
        }
        return keep.sorted().map { values[$0] }
    }

    static func controlPoints(_ coordinates: [RouteCoordinate], preferredCount: Int) -> [RouteCoordinate] {
        var tolerance = 5.0
        var result = coordinates
        for _ in 0..<7 {
            result = simplify(coordinates, tolerance: tolerance)
            if result.count <= preferredCount + 3 { break }
            tolerance *= 1.8
        }
        if result.first == result.last { result.removeLast() }
        return result
    }

    static func repeatedRoadFraction(_ geometry: RouteGeometry) -> Double {
        struct Cell: Hashable { let x: Int; let y: Int }
        struct Sample { let point: MKMapPoint; let dx: Double; let dy: Double; let index: Int }
        var buckets: [Cell: [Sample]] = [:]
        var repeated = Set<Int>()
        var previous: MKMapPoint?
        var count = 0
        let scale = MKMetersPerMapPointAtLatitude(geometry.coordinates.first?.latitude ?? 0)
        guard scale.isFinite, scale > 0 else { return 1 }
        for distance in stride(from: 0.0, through: geometry.totalDistance, by: 25) {
            guard let coordinate = geometry.coordinate(atDistance: distance) else { continue }
            let point = MKMapPoint(coordinate)
            defer { previous = point }
            guard let previous else { continue }
            let dx = point.x - previous.x, dy = point.y - previous.y
            let length = hypot(dx, dy)
            guard length > 0 else { continue }
            let midpoint = MKMapPoint(x: (point.x + previous.x) / 2, y: (point.y + previous.y) / 2)
            let key = Cell(x: Int(floor(midpoint.x * scale / 20)), y: Int(floor(midpoint.y * scale / 20)))
            let current = Sample(point: midpoint, dx: dx / length, dy: dy / length, index: count)
            for x in -1...1 {
                for y in -1...1 {
                    for old in buckets[Cell(x: key.x + x, y: key.y + y)] ?? [] where count - old.index > 3 {
                        if abs(current.dx * old.dx + current.dy * old.dy) > 0.85,
                           midpoint.distance(to: old.point) < 15 {
                            repeated.insert(old.index); repeated.insert(count)
                        }
                    }
                }
            }
            buckets[key, default: []].append(current)
            count += 1
        }
        return count == 0 ? 1 : Double(repeated.count) / Double(count)
    }
}

@MainActor
final class SmartRouteGenerator {
    static let maximumDirectionsRequests = 12
    private let provider: any SmartRoadProviding
    init(provider: any SmartRoadProviding) { self.provider = provider }
    convenience init() { self.init(provider: MapKitSmartRoadProvider()) }
    func cancel() { provider.cancel() }

    func generate(center: RouteCoordinate, options: SmartRouteOptions) async throws -> SmartRouteCandidate {
        guard center.isValid, options.isValid else { throw SmartRouteError.invalidSettings }
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        let found = try await provider.nearbyLocations(center: center, radius: options.targetDistance / 3)
        try Task.checkCancellation()
        let locations = Array(Set(found.filter { $0.isValid && SmartRouteQuality.meters(center, $0) > 100
            && SmartRouteQuality.meters(center, $0) < options.targetDistance / 2 })).sorted { $0.id < $1.id }.prefix(18)
        let start = options.originRole == .start ? center : locations.min(by: { SmartRouteQuality.meters(center, $0) < SmartRouteQuality.meters(center, $1) }) ?? center
        let nodes = Array(locations.filter { SmartRouteQuality.meters(start, $0) > 100 })
        let plans = plans(start: start, nodes: nodes, options: options)
        guard !plans.isEmpty else { throw SmartRouteError.insufficientRoads }
        var requests = 0
        var best: SmartRouteCandidate?
        var bestScore = Double.infinity
        for anchors in plans {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw SmartRouteError.timedOut }
            var legs: [[RouteCoordinate]] = []
            var cursor = start
            var initialRoadPoint: RouteCoordinate?
            do {
                for target in anchors + [start] {
                    try Task.checkCancellation()
                    guard requests < Self.maximumDirectionsRequests, ContinuousClock.now < deadline else { throw SmartRouteError.timedOut }
                    requests += 1
                    let destination = target == start ? (initialRoadPoint ?? start) : target
                    let geometry = try await provider.route(from: cursor, to: destination, transport: options.transport)
                    try Task.checkCancellation()
                    if initialRoadPoint == nil { initialRoadPoint = geometry.coordinates.first }
                    guard let end = geometry.coordinates.last else { throw SmartRouteError.disconnected }
                    legs.append(geometry.coordinates)
                    cursor = end
                }
                guard let initialRoadPoint, SmartRouteQuality.meters(start, initialRoadPoint) <= 100 else { throw SmartRouteError.disconnected }
                let coordinates = try SmartRouteQuality.join(legs)
                let calculation = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let original = RouteGeometry(coordinates: coordinates)
                    let simplified = RouteGeometry(coordinates: SmartRouteQuality.simplify(original.coordinates, tolerance: 2))
                    let road = simplified.totalDistance >= original.totalDistance * 0.995 ? simplified : original
                    let candidate = try SmartRouteCandidate.make(geometry: road, options: options, kind: options.kind)
                    let repeated = SmartRouteQuality.repeatedRoadFraction(road)
                    try Task.checkCancellation()
                    return (candidate, repeated)
                }
                let (candidate, repeated) = try await withTaskCancellationHandler {
                    try await calculation.value
                } onCancel: { calculation.cancel() }
                try Task.checkCancellation()
                if options.kind == .loop, repeated > 0.6 { continue }
                let score = abs(candidate.deviation) * 5 + (options.kind == .loop ? repeated : 0)
                if score < bestScore { best = candidate; bestScore = score }
                if !candidate.usesRelaxedDistance && (options.kind == .outAndBack || repeated < 0.2) { return candidate }
            } catch is CancellationError { throw CancellationError() }
            catch let error as SmartRouteError {
                switch error {
                case .throttled, .timedOut, .unavailable: throw error
                default: continue
                }
            } catch { throw SmartRouteError.unavailable }
        }
        try Task.checkCancellation()
        guard let best else { throw SmartRouteError.noMatchingRoute }
        return best
    }

    private func plans(start: RouteCoordinate, nodes: [RouteCoordinate], options: SmartRouteOptions) -> [[RouteCoordinate]] {
        if options.kind == .outAndBack {
            return nodes.sorted {
                abs(SmartRouteQuality.meters(start, $0) * 2 - options.targetDistance / 1.3)
                    < abs(SmartRouteQuality.meters(start, $1) * 2 - options.targetDistance / 1.3)
            }.prefix(3).map { [$0] }
        }
        guard nodes.count >= 3 else { return [] }
        var values: [(Double, [RouteCoordinate])] = []
        for i in 0..<(nodes.count - 2) {
            for j in (i + 1)..<(nodes.count - 1) {
                for k in (j + 1)..<nodes.count {
                    let ring = [nodes[i], nodes[j], nodes[k]].sorted {
                        atan2($0.latitude - start.latitude, $0.longitude - start.longitude)
                            < atan2($1.latitude - start.latitude, $1.longitude - start.longitude)
                    }
                    let direct = RouteBuilder.straightGeometry(waypoints: [start] + ring, closedLoop: true).totalDistance
                    // Direct distance ranks *requests only*, never a candidate.
                    values.append((abs(direct - options.targetDistance / 1.25), ring))
                }
            }
        }
        values.sort { $0.0 < $1.0 }
        let shortlist = Array(values.prefix(9))
        guard !shortlist.isEmpty else { return [] }
        let offset = Int(options.variation.magnitude % UInt(shortlist.count))
        return (0..<min(3, shortlist.count)).map { shortlist[($0 * max(1, shortlist.count / 3) + offset) % shortlist.count].1 }
    }
}

/// Each generation gets its own MapKit provider, so a late cancelled request
/// cannot cancel a newer request or publish into its preview.
@MainActor
final class SmartRouteGenerationSession: ObservableObject {
    @Published private(set) var candidate: SmartRouteCandidate?
    @Published private(set) var error: String?
    @Published private(set) var isGenerating = false
    private var generation: UInt = 0
    private var task: Task<Void, Never>?
    private var generator: SmartRouteGenerator?
    private let makeGenerator: @MainActor () -> SmartRouteGenerator
    init(makeGenerator: @escaping @MainActor () -> SmartRouteGenerator = { SmartRouteGenerator() }) { self.makeGenerator = makeGenerator }
    func cancel() {
        generation &+= 1
        task?.cancel(); generator?.cancel()
        task = nil; generator = nil; isGenerating = false
    }
    func invalidate() { cancel(); candidate = nil; error = nil }
    @discardableResult
    func generate(center: RouteCoordinate, options: SmartRouteOptions) -> Task<Void, Never> {
        cancel()
        let token = generation
        let generator = makeGenerator()
        self.generator = generator
        candidate = nil; error = nil; isGenerating = true
        task = Task { [weak self] in
            do {
                let value = try await generator.generate(center: center, options: options)
                guard let self, !Task.isCancelled, generation == token else { return }
                candidate = value; isGenerating = false
            } catch {
                guard let self, !Task.isCancelled, generation == token else { return }
                self.error = error.localizedDescription; isGenerating = false
            }
        }
        return task!
    }
}
