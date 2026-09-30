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
    static func offsetText(for timeZone: TimeZone, at date: Date = .now, baseline: TimeZone = TimeZone(identifier: "Asia/Taipei")!) -> String {
        let delta = timeZone.secondsFromGMT(for: date) - baseline.secondsFromGMT(for: date)
        if delta == 0 { return L10n.text("與台灣時間相同") }
        let hours = delta / 3600
        let minutes = abs(delta % 3600) / 60
        let amount = minutes == 0 ? "\(abs(hours)) 小時" : "\(abs(hours)) 小時 \(minutes) 分鐘"
        return delta > 0 ? L10n.format("比台灣快 %@", amount) : L10n.format("比台灣慢 %@", amount)
    }
}

actor PlaceInfoResolver {
    static let shared = PlaceInfoResolver()
    private var memory: [String: PlaceInfo] = [:]
    private var inFlight: [String: Task<PlaceInfo?, Never>] = [:]
    private let cacheURL: URL
    private let quantization = 10_000.0

    init(cacheURL: URL? = nil) {
        let base = cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("RouteLocation", isDirectory: true)
        self.cacheURL = base.appendingPathComponent("place-info.json")
        if let data = try? Data(contentsOf: self.cacheURL), let values = try? JSONDecoder().decode([String: PlaceInfo].self, from: data) { memory = values }
    }

    func resolve(_ coordinate: RouteCoordinate, debounceNanoseconds: UInt64 = 350_000_000) async -> PlaceInfo? {
        guard coordinate.isValid else { return nil }
        let key = cacheKey(coordinate)
        if let cached = memory[key], Date().timeIntervalSince(cached.resolvedAt) < 30 * 24 * 3600 { return cached }
        if let existing = inFlight[key] { return await existing.value }
        let task = Task<PlaceInfo?, Never> { [weak self] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return nil }
            do {
                let placemarks = try await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
                guard let placemark = placemarks.first else { return nil }
                let info = PlaceInfo(
                    coordinate: coordinate,
                    displayName: placemark.name,
                    country: placemark.country,
                    countryCode: placemark.isoCountryCode,
                    administrativeArea: placemark.administrativeArea,
                    locality: placemark.locality,
                    subLocality: placemark.subLocality,
                    timeZoneIdentifier: placemark.timeZone?.identifier,
                    resolvedAt: .now
                )
                await self?.store(info, key: key)
                return info
            } catch { return nil }
        }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        return value
    }

    func cached(_ coordinate: RouteCoordinate) -> PlaceInfo? { memory[cacheKey(coordinate)] }

    private func cacheKey(_ coordinate: RouteCoordinate) -> String {
        "\(Int((coordinate.latitude * quantization).rounded())):\(Int((coordinate.longitude * quantization).rounded()))"
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
