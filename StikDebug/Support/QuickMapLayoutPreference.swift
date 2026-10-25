import Foundation

/// Layout only: never changes MapInteractionStyle or any production model state.
enum QuickMapLayoutPreference: String, CaseIterable, Identifiable {
    case full
    case compact
    static let defaultsKey = "RouteLocation.quickMapLayout"
    var id: String { rawValue }
    var title: String { L10n.text(self == .full ? "完整版（v1.2.26）" : "精簡版（v1.2.21 風格）") }
    static func resolve(_ raw: String?) -> Self { raw.flatMap(Self.init(rawValue:)) ?? .full }
    static func effective(_ raw: String?, tutorialActive: Bool) -> Self {
        // Tutorials may need full quick-entry targets, but never write this override.
        tutorialActive ? .full : resolve(raw)
    }
}
