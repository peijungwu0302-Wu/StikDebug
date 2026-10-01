import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case traditionalChinese = "zh-Hant"
    case english = "en"

    static let defaultsKey = "RouteLocation.appLanguage"
    var id: String { rawValue }
    var displayName: String { self == .traditionalChinese ? "繁體中文" : "English" }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let defaultsKey = "RouteLocation.appearance"

    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    var title: String {
        switch self {
        case .system: return L10n.text("隨系統")
        case .light: return L10n.text("淺色")
        case .dark: return L10n.text("深色")
        }
    }

    static func resolve(_ rawValue: String?) -> Self {
        guard let rawValue, let value = Self(rawValue: rawValue) else { return .system }
        return value
    }
}

enum CoordinateTextSizePreference: String, CaseIterable, Identifiable {
    case smaller
    case standard
    case larger
    case followSystem

    static let defaultsKey = "RouteLocation.coordinateTextSize"

    var id: String { rawValue }
    var fixedPointSize: CGFloat? {
        switch self {
        case .smaller: return 11
        case .standard: return 13
        case .larger: return 15
        case .followSystem: return nil
        }
    }
    var usesDynamicType: Bool { self == .followSystem }
    var font: Font {
        if let fixedPointSize {
            return .system(size: fixedPointSize, weight: .regular, design: .monospaced)
        }
        return .footnote.monospaced()
    }
    var title: String {
        switch self {
        case .smaller: return L10n.text("較小")
        case .standard: return L10n.text("標準")
        case .larger: return L10n.text("較大")
        case .followSystem: return L10n.text("跟隨系統")
        }
    }

    static func resolve(_ rawValue: String?) -> Self {
        guard let rawValue, let value = Self(rawValue: rawValue) else { return .standard }
        return value
    }
}

enum L10n {
    static func text(_ key: String) -> String {
        let identifier = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey) ?? AppLanguage.traditionalChinese.rawValue
        let bundle: Bundle
        if let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
           let localizedBundle = Bundle(path: path) {
            bundle = localizedBundle
        } else {
            bundle = .main
        }
        return NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }
}
