import Foundation
import Testing

@testable import RouteLocation

struct LocalizationAuditTests {
    @Test("Every literal view localization key has an English translation")
    func everyViewKeyHasEnglishEntry() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewsURL = projectRoot.appendingPathComponent("StikDebug/Views", isDirectory: true)
        let stringsURL = projectRoot.appendingPathComponent("StikDebug/en.lproj/Localizable.strings")

        let keyRegex = try NSRegularExpression(pattern: #"L10n\.(?:text|format)\(\"((?:\\.|[^\"\\])*)\""#)
        let stringsRegex = try NSRegularExpression(pattern: #"(?m)^\s*\"((?:\\.|[^\"\\])*)\"\s*=\s*"#)

        var viewKeys = Set<String>()
        let enumerator = FileManager.default.enumerator(at: viewsURL, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in keyRegex.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                viewKeys.insert(String(source[keyRange]))
            }
        }

        let strings = try String(contentsOf: stringsURL, encoding: .utf8)
        let stringsRange = NSRange(strings.startIndex..<strings.endIndex, in: strings)
        var englishKeys = Set<String>()
        for match in stringsRegex.matches(in: strings, range: stringsRange) {
            guard let keyRange = Range(match.range(at: 1), in: strings) else { continue }
            englishKeys.insert(String(strings[keyRange]))
        }

        let missing = viewKeys.subtracting(englishKeys).sorted()
        #expect(!viewKeys.isEmpty)
        #expect(missing.isEmpty, "Missing English localization keys: \(missing.joined(separator: ", "))")
    }
}
