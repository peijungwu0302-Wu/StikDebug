import Foundation

enum PersistenceError: LocalizedError {
    case corruptedRoute(String)
    case invalidFavorite

    var errorDescription: String? {
        switch self {
        case .corruptedRoute(let name): return L10n.format("已儲存的路線 %@ 已損毀，無法載入。", name)
        case .invalidFavorite: return L10n.text("喜愛地點包含無效座標。")
        }
    }
}

actor RoutePersistenceStore {
    private let fileManager: FileManager
    private let rootURL: URL
    private let routesURL: URL
    private let favoritesURL: URL
    private let recentsURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        let base = rootURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.rootURL = base.appendingPathComponent(ProductIdentity.supportDirectoryName, isDirectory: true)
        routesURL = self.rootURL.appendingPathComponent("routes", isDirectory: true)
        favoritesURL = self.rootURL.appendingPathComponent("locations.json")
        recentsURL = self.rootURL.appendingPathComponent("recent-locations.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadFavorites() throws -> [FavoriteLocation] {
        try ensureDirectories()
        guard fileManager.fileExists(atPath: favoritesURL.path) else { return migrateLegacyFavorites() }
        let data = try Data(contentsOf: favoritesURL)
        var favorites = try decoder.decode([FavoriteLocation].self, from: data)
        guard favorites.allSatisfy({ $0.coordinate.isValid }) else { throw PersistenceError.invalidFavorite }
        if requiresTimestampMigration(inArrayData: data) {
            try saveFavorites(favorites)
            // Return the same encoded precision that subsequent launches will
            // decode, keeping legacy migration timestamps stable immediately.
            favorites = try decoder.decode([FavoriteLocation].self, from: Data(contentsOf: favoritesURL))
        }
        return favorites.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func saveFavorites(_ favorites: [FavoriteLocation]) throws {
        try ensureDirectories()
        guard favorites.allSatisfy({ $0.coordinate.isValid }) else { throw PersistenceError.invalidFavorite }
        try encoder.encode(favorites).write(to: favoritesURL, options: [.atomic, .completeFileProtection])
    }

    func loadRecentLocations() throws -> [RecentLocation] {
        try ensureDirectories()
        guard fileManager.fileExists(atPath: recentsURL.path) else { return [] }
        return try decoder.decode([RecentLocation].self, from: Data(contentsOf: recentsURL))
    }

    func saveRecentLocations(_ recents: [RecentLocation]) throws {
        try ensureDirectories()
        try encoder.encode(Array(recents.prefix(30))).write(to: recentsURL, options: [.atomic, .completeFileProtection])
    }

    func loadRoutes() throws -> [SavedRoute] {
        try ensureDirectories()
        let files = try fileManager.contentsOfDirectory(at: routesURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
        var routes: [SavedRoute] = []
        for file in files {
            do {
                let data = try Data(contentsOf: file)
                var route = try decoder.decode(SavedRoute.self, from: data)
                guard route.waypoints.allSatisfy(\.isValid), !route.resolvedGeometry.coordinates.isEmpty else {
                    throw PersistenceError.corruptedRoute(file.lastPathComponent)
                }
                if requiresTimestampMigration(inObjectData: data) {
                    try encoder.encode(route).write(to: file, options: [.atomic, .completeFileProtection])
                    route = try decoder.decode(SavedRoute.self, from: Data(contentsOf: file))
                }
                routes.append(route)
            } catch {
                throw PersistenceError.corruptedRoute(file.lastPathComponent)
            }
        }
        return routes.sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveRoute(_ route: SavedRoute) throws {
        try ensureDirectories()
        let destination = routesURL.appendingPathComponent(route.id.uuidString).appendingPathExtension("json")
        try encoder.encode(route).write(to: destination, options: [.atomic, .completeFileProtection])
    }

    func deleteRoute(id: UUID) throws {
        let destination = routesURL.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: routesURL, withIntermediateDirectories: true)
    }

    private struct LegacyBookmark: Codable {
        let id: UUID
        let name: String
        let latitude: Double
        let longitude: Double
    }

    private func migrateLegacyFavorites() -> [FavoriteLocation] {
        guard let data = UserDefaults.standard.data(forKey: "locationBookmarks"),
              let bookmarks = try? JSONDecoder().decode([LegacyBookmark].self, from: data) else { return [] }
        let now = Date()
        let favorites = bookmarks.compactMap { bookmark -> FavoriteLocation? in
            let coordinate = RouteCoordinate(latitude: bookmark.latitude, longitude: bookmark.longitude)
            guard coordinate.isValid else { return nil }
            return FavoriteLocation(id: bookmark.id, name: bookmark.name, coordinate: coordinate, createdAt: now, updatedAt: now)
        }
        try? saveFavoritesSynchronouslyForMigration(favorites)
        return favorites
    }

    private func saveFavoritesSynchronouslyForMigration(_ favorites: [FavoriteLocation]) throws {
        try encoder.encode(favorites).write(to: favoritesURL, options: [.atomic, .completeFileProtection])
    }

    private func requiresTimestampMigration(inArrayData data: Data) -> Bool {
        guard let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        return values.contains { $0["createdAt"] == nil || $0["updatedAt"] == nil }
    }

    private func requiresTimestampMigration(inObjectData data: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return value["createdAt"] == nil || value["updatedAt"] == nil
    }
}
