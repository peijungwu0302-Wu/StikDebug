import Combine
import Foundation

enum LocationUpdateHealth: Equatable {
    case unknown, healthy, degraded, failed

    var label: String {
        switch self {
        case .unknown: return L10n.text("尚未測試")
        case .healthy: return L10n.text("健康")
        case .degraded: return L10n.text("暫時異常")
        case .failed: return L10n.text("需要恢復")
        }
    }
}

enum LocationRecoveryPolicy {
    static let failureThreshold = 3
    static func shouldRecover(consecutiveFailures: Int) -> Bool {
        consecutiveFailures >= failureThreshold
    }
}

@MainActor
final class LocationDataPathHealth: ObservableObject {
    static let shared = LocationDataPathHealth()

    @Published private(set) var lastSuccessfulLocationUpdate: Date?
    @Published private(set) var lastLocationUpdateFailure: Date?
    @Published private(set) var consecutiveLocationFailures = 0
    @Published private(set) var lastTunnelHealthProbeResult: String?
    @Published private(set) var reconnectReason: String?

    var status: LocationUpdateHealth {
        if consecutiveLocationFailures == 0 { return lastSuccessfulLocationUpdate == nil ? .unknown : .healthy }
        return LocationRecoveryPolicy.shouldRecover(consecutiveFailures: consecutiveLocationFailures) ? .failed : .degraded
    }

    var hasRecentSuccess: Bool {
        guard let date = lastSuccessfulLocationUpdate else { return false }
        return Date().timeIntervalSince(date) < 15
    }

    func recordSuccess() {
        lastSuccessfulLocationUpdate = .now
        consecutiveLocationFailures = 0
        reconnectReason = nil
    }

    func recordFailure(_ error: Error) {
        lastLocationUpdateFailure = .now
        consecutiveLocationFailures += 1
        reconnectReason = error.localizedDescription
    }

    func recordProbe(success: Bool, error: NSError? = nil) {
        lastTunnelHealthProbeResult = success ? L10n.text("可用") : sanitized(error)
    }

    private func sanitized(_ error: NSError?) -> String {
        guard let error else { return L10n.text("不可用") }
        return "\(error.domain) (\(error.code)): \(error.localizedDescription)"
    }
}
