import Foundation

public enum SideStoreSourceConfig {
    public static let rawSourceURLString = "https://raw.githubusercontent.com/peijungwu0302-Wu/StikDebug/main/source.json"
    public static let releasesWebURLString = "https://github.com/peijungwu0302-Wu/StikDebug/releases"
    public static let sideStoreSchemePrefix = "sidestore://source?url="

    public static var encodedSourceURLString: String {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return rawSourceURLString.addingPercentEncoding(withAllowedCharacters: unreserved) ?? rawSourceURLString
    }

    public static var sideStoreDeepLinkURL: URL? {
        URL(string: "\(sideStoreSchemePrefix)\(encodedSourceURLString)")
    }

    public static var rawSourceURL: URL? {
        URL(string: rawSourceURLString)
    }

    public static var releasesWebURL: URL? {
        URL(string: releasesWebURLString)
    }
}
