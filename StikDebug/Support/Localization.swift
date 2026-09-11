import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case traditionalChinese = "zh-Hant"
    case english = "en"

    static let defaultsKey = "RouteLocation.appLanguage"
    var id: String { rawValue }
    var displayName: String { self == .traditionalChinese ? "繁體中文" : "English" }
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
