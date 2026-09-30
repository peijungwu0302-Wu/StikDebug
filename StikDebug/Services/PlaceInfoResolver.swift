import CoreLocation
import Foundation
import MapKit

struct PlaceInfo: Codable, Equatable, Sendable {
    let coordinate: RouteCoordinate
    let displayName: String?
    let country: String?
    let countryCode: String?
    let administrativeArea: String?
    let locality: String?
    let subLocality: String?
    let timeZoneIdentifier: String?
    let resolvedAt: Date

    var bestDisplayName: String? {
        if let subLocality, let locality { return "\(locality)\(subLocality)" }
        return displayName ?? locality ?? administrativeArea
    }
}

enum TimeZoneComparisonBaseline: String, Codable, CaseIterable, Identifiable {
    case taiwan
    case device
    var id: String { rawValue }
    var title: String { L10n.text(self == .taiwan ? "台灣時間" : "裝置目前時區") }
    var timeZone: TimeZone { self == .taiwan ? TimeZone(identifier: "Asia/Taipei")! : .current }
}

enum PlaceTimeFormatter {
    /// Formats a timezone's actual offset at a specific instant without
    /// discarding half-hour or quarter-hour offsets.
    static func gmtOffsetText(for timeZone: TimeZone, at date: Date = .now) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let absolute = abs(seconds)
        let hours = absolute / 3600
        let minutes = (absolute % 3600) / 60
        if minutes == 0 {
            return "GMT\(sign)\(hours)"
        }
        return String(format: "GMT%@%d:%02d", sign, hours, minutes)
    }

    static func offsetText(
        for timeZone: TimeZone,
        at date: Date = .now,
        baseline: TimeZoneComparisonBaseline = .taiwan
    ) -> String {
        let baselineZone = baseline.timeZone
        let delta = timeZone.secondsFromGMT(for: date) - baselineZone.secondsFromGMT(for: date)
        if delta == 0 {
            return L10n.text(baseline == .taiwan ? "與台灣時間相同" : "與目前時間相同")
        }
        let hours = delta / 3600
        let minutes = abs(delta % 3600) / 60
        let amount = minutes == 0
            ? L10n.format("%d 小時", abs(hours))
            : L10n.format("%d 小時 %d 分鐘", abs(hours), minutes)
        let key: String
        if baseline == .taiwan {
            key = delta > 0 ? "比台灣快 %@" : "比台灣慢 %@"
        } else {
            key = delta > 0 ? "比目前快 %@" : "比目前慢 %@"
        }
        return L10n.format(key, amount)
    }
}

struct PlaceGeocodingResult: Sendable, Equatable {
    let displayName: String?
    let country: String?
    let countryCode: String?
    let administrativeArea: String?
    let locality: String?
    let subLocality: String?
    let timeZoneIdentifier: String?
}

protocol PlaceGeocodingClient: Sendable {
    func reverseGeocode(_ coordinate: RouteCoordinate) async throws -> PlaceGeocodingResult?
}

struct MapKitPlaceGeocodingClient: PlaceGeocodingClient {
    func reverseGeocode(_ coordinate: RouteCoordinate) async throws -> PlaceGeocodingResult? {
        let placemarks = try await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        )
        guard let placemark = placemarks.first else { return nil }
        return PlaceGeocodingResult(
            displayName: placemark.name,
            country: placemark.country,
            countryCode: placemark.isoCountryCode,
            administrativeArea: placemark.administrativeArea,
            locality: placemark.locality,
            subLocality: placemark.subLocality,
            timeZoneIdentifier: placemark.timeZone?.identifier
        )
    }
}

enum PlaceInfoRequestScope: Sendable {
    case general
    case selected
}

actor PlaceInfoResolver {
    static let shared = PlaceInfoResolver()
    private var memory: [String: PlaceInfo] = [:]
    private var inFlight: [String: Task<PlaceInfo?, Never>] = [:]
    private var inFlightTokens: [String: UUID] = [:]
    private var selectedTask: Task<PlaceInfo?, Never>?
    private var selectedKey: String?
    private var selectedToken: UUID?
    private var geocodeTail: Task<Void, Never>?
    private let geocoder: any PlaceGeocodingClient
    private let cacheURL: URL
    private let quantization = 10_000.0

    init(cacheURL: URL? = nil, geocoder: any PlaceGeocodingClient = MapKitPlaceGeocodingClient()) {
        self.geocoder = geocoder
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let base = cacheURL ?? support.appendingPathComponent("RouteLocation", isDirectory: true)
        self.cacheURL = base.appendingPathComponent("place-info.json")
        if let data = try? Data(contentsOf: self.cacheURL), let values = try? JSONDecoder().decode([String: PlaceInfo].self, from: data) { memory = values }
    }

    func resolve(
        _ coordinate: RouteCoordinate,
        debounceNanoseconds: UInt64 = 350_000_000,
        scope: PlaceInfoRequestScope = .general
    ) async -> PlaceInfo? {
        guard coordinate.isValid else { return nil }
        let key = cacheKey(coordinate)
        if let cached = memory[key], Date().timeIntervalSince(cached.resolvedAt) < 30 * 24 * 3600 { return cached }

        if scope == .selected, selectedKey != key {
            selectedTask?.cancel()
            selectedTask = nil
            selectedKey = key
            selectedToken = nil
        }
        if let existing = inFlight[key] { return await existing.value }

        let token = UUID()
        let previous = geocodeTail
        let geocoder = self.geocoder
        let task = Task<PlaceInfo?, Never> { [weak self] in
            do { try await Task.sleep(nanoseconds: debounceNanoseconds) } catch { return nil }
            if let previous { _ = await previous.value }
            guard !Task.isCancelled else { return nil }
            do {
                guard let result = try await geocoder.reverseGeocode(coordinate), !Task.isCancelled else { return nil }
                let info = PlaceInfo(
                    coordinate: coordinate,
                    displayName: result.displayName,
                    country: result.country,
                    countryCode: result.countryCode,
                    administrativeArea: result.administrativeArea,
                    locality: result.locality,
                    subLocality: result.subLocality,
                    timeZoneIdentifier: result.timeZoneIdentifier,
                    resolvedAt: .now
                )
                await self?.store(info, key: key)
                return info
            } catch { return nil }
        }
        inFlight[key] = task
        inFlightTokens[key] = token
        if scope == .selected {
            selectedTask = task
            selectedKey = key
            selectedToken = token
        }
        geocodeTail = Task { _ = await task.value }
        let value = await task.value
        finish(key: key, token: token)
        return value
    }

    func cached(_ coordinate: RouteCoordinate) -> PlaceInfo? { memory[cacheKey(coordinate)] }

    private func cacheKey(_ coordinate: RouteCoordinate) -> String {
        "\(Int((coordinate.latitude * quantization).rounded())):\(Int((coordinate.longitude * quantization).rounded()))"
    }

    private func finish(key: String, token: UUID) {
        guard inFlightTokens[key] == token else { return }
        inFlight[key] = nil
        inFlightTokens[key] = nil
        if selectedToken == token {
            selectedTask = nil
            selectedKey = nil
            selectedToken = nil
        }
    }

    private func store(_ info: PlaceInfo, key: String) {
        memory[key] = info
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(memory)
            try data.write(to: cacheURL, options: [.atomic])
        } catch { /* cache is best-effort */ }
    }
}
