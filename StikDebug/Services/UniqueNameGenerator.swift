import Foundation

enum UniqueNameGenerator {
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Returns `base`, `base1`, `base2`, ... without treating a numeric suffix
    /// as part of the base (so `公司` never becomes `公司11`).
    static func makeUnique(base: String, existing: [String], fallback: String) -> String {
        let normalizedBase = normalized(base).isEmpty ? fallback : normalized(base)
        let folded = Set(existing.map { normalized($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) })
        func available(_ candidate: String) -> Bool {
            !folded.contains(normalized(candidate).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        }
        if available(normalizedBase) { return normalizedBase }
        var index = 1
        while !available("\(normalizedBase)\(index)") { index += 1 }
        return "\(normalizedBase)\(index)"
    }
}
