import CoreLocation
import Foundation
import MapKit

struct RouteCoordinate: Codable, Hashable, Identifiable {
    var latitude: Double
    var longitude: Double

    var id: String { "\(latitude),\(longitude)" }
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    var isValid: Bool { CLLocationCoordinate2DIsValid(clCoordinate) }

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }
}

enum RouteMode: String, Codable, CaseIterable, Identifiable {
    case straight
    case navigation
    var id: String { rawValue }
    var title: String { L10n.text(self == .straight ? "直線" : "導航") }
}

enum NavigationTransportMode: String, Codable, CaseIterable, Identifiable {
    case automobile
    case walking
    var id: String { rawValue }
    var title: String { L10n.text(self == .walking ? "步行" : "開車") }
    var mapKitValue: MKDirectionsTransportType {
        self == .walking ? .walking : .automobile
    }
}

enum RoutePlaybackMode: String, Codable, CaseIterable, Identifiable {
    case once
    case infiniteLoop
    var id: String { rawValue }
    var title: String { L10n.text(self == .once ? "單次" : "無限循環") }
}

enum MapInteractionStyle: String, Codable, CaseIterable, Identifiable {
    case classic
    case quickRoute

    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return L10n.text("經典模式")
        case .quickRoute: return L10n.text("快速路線 Beta")
        }
    }
    var detail: String {
        switch self {
        case .classic: return L10n.text("使用目前既有的地圖與路線操作方式")
        case .quickRoute: return L10n.text("可直接在地圖新增航點、建立並開始路線")
        }
    }
}

enum ModeSwitchConfirmation: String, Codable, CaseIterable, Identifiable {
    case askFirst
    case directSwitch

    var id: String { rawValue }
    var title: String {
        switch self {
        case .askFirst: return L10n.text("先詢問")
        case .directSwitch: return L10n.text("直接切換")
        }
    }
    var detail: String {
        switch self {
        case .askFirst: return L10n.text("切換定位模式時會先顯示確認對話框")
        case .directSwitch: return L10n.text("切換定位模式時直接停止既有模式並套用新模式")
        }
    }
}

enum QuickRouteInteractionMode: String, CaseIterable, Identifiable {
    case singlePoint
    case route

    var id: String { rawValue }
    var title: String {
        switch self {
        case .singlePoint: return L10n.text("單點")
        case .route: return L10n.text("路線")
        }
    }
}

enum StepCalculationMode: String, Codable, CaseIterable, Identifiable {
    case fixedCadence
    case distance

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fixedCadence: return L10n.text("固定步頻")
        case .distance: return L10n.text("依移動距離")
        }
    }
}

enum SimulationMode: Equatable {
    case idle
    case singlePoint(RouteCoordinate)
    case routePlaying
    case routePaused

    var isSimulating: Bool {
        switch self {
        case .idle: return false
        case .singlePoint, .routePlaying, .routePaused: return true
        }
    }

    var label: String {
        switch self {
        case .idle: return L10n.text("未模擬")
        case .singlePoint: return L10n.text("單點模擬中")
        case .routePlaying: return L10n.text("路線播放中")
        case .routePaused: return L10n.text("路線已暫停")
        }
    }
}

struct RouteGeometry: Codable, Equatable {
    let coordinates: [RouteCoordinate]
    let cumulativeDistances: [CLLocationDistance]
    let totalDistance: CLLocationDistance

    init(coordinates: [RouteCoordinate]) {
        let valid = coordinates.filter(\.isValid)
        self.coordinates = valid
        guard !valid.isEmpty else {
            cumulativeDistances = []
            totalDistance = 0
            return
        }

        var cumulative: [CLLocationDistance] = [0]
        cumulative.reserveCapacity(valid.count)
        var total: CLLocationDistance = 0
        for pair in zip(valid, valid.dropFirst()) {
            let start = CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let end = CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude)
            let distance = start.distance(from: end)
            if distance.isFinite, distance > 0 { total += distance }
            cumulative.append(total)
        }
        cumulativeDistances = cumulative
        totalDistance = total
    }

    init(clCoordinates: [CLLocationCoordinate2D]) {
        self.init(coordinates: clCoordinates.map(RouteCoordinate.init))
    }

    private enum CodingKeys: String, CodingKey { case coordinates }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(coordinates: try container.decode([RouteCoordinate].self, forKey: .coordinates))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(coordinates, forKey: .coordinates)
    }

    static func == (lhs: RouteGeometry, rhs: RouteGeometry) -> Bool {
        lhs.coordinates == rhs.coordinates
    }

    func coordinate(atDistance requestedDistance: CLLocationDistance) -> CLLocationCoordinate2D? {
        guard let first = coordinates.first else { return nil }
        guard coordinates.count > 1, totalDistance > 0 else { return first.clCoordinate }
        let distance = min(max(requestedDistance.isFinite ? requestedDistance : 0, 0), totalDistance)
        if distance <= 0 { return first.clCoordinate }
        if distance >= totalDistance { return coordinates.last?.clCoordinate }

        var low = 1
        var high = cumulativeDistances.count - 1
        while low < high {
            let middle = (low + high) / 2
            if cumulativeDistances[middle] < distance { low = middle + 1 } else { high = middle }
        }

        let upper = low
        let lower = upper - 1
        let segmentDistance = cumulativeDistances[upper] - cumulativeDistances[lower]
        guard segmentDistance > 0 else { return coordinates[upper].clCoordinate }
        let fraction = (distance - cumulativeDistances[lower]) / segmentDistance
        let start = MKMapPoint(coordinates[lower].clCoordinate)
        let end = MKMapPoint(coordinates[upper].clCoordinate)
        return MKMapPoint(
            x: start.x + (end.x - start.x) * fraction,
            y: start.y + (end.y - start.y) * fraction
        ).coordinate
    }
}

struct FavoriteLocation: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var note: String?
    var createdAt: Date
    var updatedAt: Date

    var coordinate: RouteCoordinate { RouteCoordinate(latitude: latitude, longitude: longitude) }

    init(id: UUID = UUID(), name: String, coordinate: RouteCoordinate, note: String? = nil, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct SavedRoute: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var waypoints: [RouteCoordinate]
    var resolvedGeometry: RouteGeometry
    var routeMode: RouteMode
    var navigationTransportMode: NavigationTransportMode
    var isClosedLoop: Bool
    var preferredSpeedKmh: Double
    var playbackMode: RoutePlaybackMode
    var navigationGeometryNeedsRecalculation: Bool
    var isFavorite: Bool
    var createdAt: Date
    var updatedAt: Date

    var totalDistance: CLLocationDistance { resolvedGeometry.totalDistance }

    init(
        id: UUID = UUID(), name: String, waypoints: [RouteCoordinate], resolvedGeometry: RouteGeometry,
        routeMode: RouteMode, navigationTransportMode: NavigationTransportMode = .automobile,
        isClosedLoop: Bool, preferredSpeedKmh: Double, playbackMode: RoutePlaybackMode,
        navigationGeometryNeedsRecalculation: Bool = false, isFavorite: Bool = false,
        createdAt: Date = .now, updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.waypoints = waypoints
        self.resolvedGeometry = resolvedGeometry
        self.routeMode = routeMode
        self.navigationTransportMode = navigationTransportMode
        self.isClosedLoop = isClosedLoop
        self.preferredSpeedKmh = preferredSpeedKmh
        self.playbackMode = playbackMode
        self.navigationGeometryNeedsRecalculation = navigationGeometryNeedsRecalculation
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, waypoints, resolvedGeometry, routeMode, navigationTransportMode
        case isClosedLoop, preferredSpeedKmh, playbackMode, navigationGeometryNeedsRecalculation
        case isFavorite, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        waypoints = try container.decode([RouteCoordinate].self, forKey: .waypoints)
        resolvedGeometry = try container.decode(RouteGeometry.self, forKey: .resolvedGeometry)
        routeMode = try container.decode(RouteMode.self, forKey: .routeMode)
        navigationTransportMode = try container.decodeIfPresent(NavigationTransportMode.self, forKey: .navigationTransportMode) ?? .automobile
        isClosedLoop = try container.decode(Bool.self, forKey: .isClosedLoop)
        preferredSpeedKmh = try container.decode(Double.self, forKey: .preferredSpeedKmh)
        playbackMode = try container.decode(RoutePlaybackMode.self, forKey: .playbackMode)
        navigationGeometryNeedsRecalculation = try container.decodeIfPresent(Bool.self, forKey: .navigationGeometryNeedsRecalculation) ?? false
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

enum RouteBuilder {
    static func straightGeometry(waypoints: [RouteCoordinate], closedLoop: Bool) -> RouteGeometry {
        var coordinates = waypoints.filter(\.isValid)
        if closedLoop, coordinates.count > 1, coordinates.first != coordinates.last,
           let first = coordinates.first {
            coordinates.append(first)
        }
        return RouteGeometry(coordinates: coordinates)
    }
}
