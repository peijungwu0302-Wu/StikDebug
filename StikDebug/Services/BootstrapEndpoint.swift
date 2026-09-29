import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum BootstrapEndpointMode: String, CaseIterable, Codable, Identifiable {
    case automatic
    case localDevVPN
    case loopbackIPv4
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return L10n.text("自動")
        case .localDevVPN: return L10n.text("LocalDevVPN — 10.7.0.1")
        case .loopbackIPv4: return L10n.text("IPv4 迴路 — 127.0.0.1")
        case .custom: return L10n.text("自訂 IPv4")
        }
    }
}

enum BootstrapEndpointStrategy {
    static let port = 49152
    static let localDevVPNAddress = "10.7.0.1"
    static let loopbackAddress = "127.0.0.1"
    static let modeKey = "RouteLocation.bootstrapEndpointMode"
    static let customAddressKey = "RouteLocation.bootstrapEndpointCustomIPv4"

    static func isValidIPv4(_ address: String) -> Bool {
        var value = in_addr()
        return address.withCString { inet_pton(AF_INET, $0, &value) == 1 }
    }

    static func storedMode() -> BootstrapEndpointMode {
        guard let raw = UserDefaults.standard.string(forKey: modeKey), let mode = BootstrapEndpointMode(rawValue: raw) else { return .automatic }
        return mode
    }

    static func storedCustomAddress() -> String { UserDefaults.standard.string(forKey: customAddressKey) ?? "" }

    static func resolvedAddress(mode: BootstrapEndpointMode = storedMode(), transport: NetworkTransport) -> String? {
        switch mode {
        case .localDevVPN: return localDevVPNAddress
        case .loopbackIPv4: return loopbackAddress
        case .custom: return isValidIPv4(storedCustomAddress()) ? storedCustomAddress() : nil
        case .automatic:
            return transport == .cellular ? loopbackAddress : localDevVPNAddress
        }
    }
}
