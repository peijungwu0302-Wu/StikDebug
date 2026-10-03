import Foundation

// Presentation only: do not change recovery, playback clocks, or session ownership.
extension PlaybackRunState {
    var showsRouteControls: Bool {
        switch self {
        case .running, .paused, .reconnecting, .error: return true
        case .stopped, .completed: return false
        }
    }

    var allowsSpeedEditing: Bool { self == .running || self == .paused }

    var interruptionMessage: String? {
        if case .error(let message) = self { return message }
        return nil
    }
}

enum RouteRepeatEntryPolicy {
    static func finiteCount(_ text: String) -> Int? {
        guard let count = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...RoutePlaybackMode.maximumFiniteCount).contains(count) else { return nil }
        return count
    }
}
