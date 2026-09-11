import CoreLocation
import Foundation
import UniformTypeIdentifiers

enum CoordinateImportError: LocalizedError, Equatable {
    case emptyInput
    case invalidCoordinate(line: Int)
    case noCoordinates
    case unsupportedFile(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput: return L10n.text("座標內容是空的。")
        case .invalidCoordinate(let line): return L10n.format("第 %d 行包含不可能的緯度或經度。", line)
        case .noCoordinates: return L10n.text("找不到座標。請使用緯度,經度文字、CSV、GPX、KML、JSON 或 GeoJSON。")
        case .unsupportedFile(let type): return L10n.format("不支援 .%@ 檔案格式。", type)
        }
    }
}

enum CoordinateImportParser {
    static let supportedContentTypes: [UTType] = [
        .item, .plainText, .commaSeparatedText, .tabSeparatedText, .json, .xml,
        UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml,
        UTType(filenameExtension: "kml", conformingTo: .xml) ?? .xml,
        UTType(filenameExtension: "geojson", conformingTo: .json) ?? .json
    ]

    static func parse(url: URL) throws -> [RouteCoordinate] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw CoordinateImportError.emptyInput }
        let ext = url.pathExtension.lowercased()
        guard ["txt", "csv", "tsv", "json", "geojson", "xml", "gpx", "kml", ""].contains(ext) else {
            throw CoordinateImportError.unsupportedFile(ext)
        }
        if ["json", "geojson"].contains(ext), let result = try? parseJSON(data), !result.isEmpty { return result }
        if ["xml", "gpx", "kml"].contains(ext) {
            let result = parseXML(data)
            if !result.isEmpty { return result }
        }
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
            if let result = try? parseInline(text), !result.isEmpty { return result }
        }
        if let result = try? parseJSON(data), !result.isEmpty { return result }
        let xml = parseXML(data)
        if !xml.isEmpty { return xml }
        throw CoordinateImportError.noCoordinates
    }

    static func parseInline(_ text: String) throws -> [RouteCoordinate] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoordinateImportError.emptyInput }
        var result: [RouteCoordinate] = []
        var headers: (lat: Int, lon: Int)?
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let fields = line.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\t" }).map(String.init)
            if headers == nil, let detected = detectHeaders(fields) { headers = detected; continue }
            let values: (Double, Double)?
            if let headers, fields.indices.contains(headers.lat), fields.indices.contains(headers.lon) {
                values = pair(Double(fields[headers.lat].trimmingCharacters(in: .whitespaces)), Double(fields[headers.lon].trimmingCharacters(in: .whitespaces)))
            } else {
                let numbers = numericValues(in: line)
                values = numbers.count >= 2 ? (numbers[0], numbers[1]) : nil
            }
            guard let values else { continue }
            let coordinate = RouteCoordinate(latitude: values.0, longitude: values.1)
            guard coordinate.isValid else { throw CoordinateImportError.invalidCoordinate(line: offset + 1) }
            appendDeduplicated(coordinate, to: &result)
        }
        guard !result.isEmpty else { throw CoordinateImportError.noCoordinates }
        return result
    }

    private static func pair(_ first: Double?, _ second: Double?) -> (Double, Double)? {
        guard let first, let second else { return nil }
        return (first, second)
    }

    private static func detectHeaders(_ fields: [String]) -> (lat: Int, lon: Int)? {
        let values = fields.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let lat = values.firstIndex(where: { ["lat", "latitude"].contains($0) }),
              let lon = values.firstIndex(where: { ["lon", "lng", "long", "longitude"].contains($0) }) else { return nil }
        return (lat, lon)
    }

    private static func numericValues(in text: String) -> [Double] {
        let regex = try? NSRegularExpression(pattern: #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex?.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).flatMap { Double(text[$0]) }
        } ?? []
    }

    private static func appendDeduplicated(_ coordinate: RouteCoordinate, to result: inout [RouteCoordinate]) {
        if result.last != coordinate { result.append(coordinate) }
    }

    private static func parseJSON(_ data: Data) throws -> [RouteCoordinate] {
        let object = try JSONSerialization.jsonObject(with: data)
        var result: [RouteCoordinate] = []
        collectJSON(object, geoJSONOrder: false, into: &result)
        return result
    }

    private static func collectJSON(_ object: Any, geoJSONOrder: Bool, into result: inout [RouteCoordinate]) {
        if let dictionary = object as? [String: Any] {
            let normalized = Dictionary(uniqueKeysWithValues: dictionary.map { ($0.key.lowercased(), $0.value) })
            if let lat = number(normalized["latitude"] ?? normalized["lat"]),
               let lon = number(normalized["longitude"] ?? normalized["lon"] ?? normalized["lng"]) {
                let coordinate = RouteCoordinate(latitude: lat, longitude: lon)
                if coordinate.isValid { appendDeduplicated(coordinate, to: &result) }
                return
            }
            let type = (normalized["type"] as? String)?.lowercased()
            if let features = normalized["features"] as? [Any] { features.forEach { collectJSON($0, geoJSONOrder: true, into: &result) }; return }
            if let geometries = normalized["geometries"] as? [Any] { geometries.forEach { collectJSON($0, geoJSONOrder: true, into: &result) }; return }
            if let geometry = normalized["geometry"] { collectJSON(geometry, geoJSONOrder: true, into: &result); return }
            if let coordinates = normalized["coordinates"] { collectJSON(coordinates, geoJSONOrder: type != nil || geoJSONOrder, into: &result); return }
            dictionary.values.forEach { collectJSON($0, geoJSONOrder: geoJSONOrder, into: &result) }
        } else if let array = object as? [Any] {
            if array.count >= 2, let first = number(array[0]), let second = number(array[1]) {
                let coordinate = geoJSONOrder
                    ? RouteCoordinate(latitude: second, longitude: first)
                    : RouteCoordinate(latitude: first, longitude: second)
                if coordinate.isValid { appendDeduplicated(coordinate, to: &result) }
            } else {
                array.forEach { collectJSON($0, geoJSONOrder: geoJSONOrder, into: &result) }
            }
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func parseXML(_ data: Data) -> [RouteCoordinate] {
        let collector = XMLCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { return [] }
        var result: [RouteCoordinate] = []
        collector.coordinates.filter(\.isValid).forEach { appendDeduplicated($0, to: &result) }
        return result
    }

    private final class XMLCollector: NSObject, XMLParserDelegate {
        var coordinates: [RouteCoordinate] = []
        private var collectingKML = false
        private var buffer = ""
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let name = elementName.lowercased()
            if ["wpt", "trkpt", "rtept"].contains(name), let lat = Double(attributes["lat"] ?? ""), let lon = Double(attributes["lon"] ?? "") {
                coordinates.append(RouteCoordinate(latitude: lat, longitude: lon))
            } else if name == "coordinates" { collectingKML = true; buffer = "" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if collectingKML { buffer += string } }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            guard elementName.lowercased() == "coordinates" else { return }
            for token in buffer.split(whereSeparator: \.isWhitespace) {
                let values = token.split(separator: ",").compactMap { Double($0) }
                if values.count >= 2 { coordinates.append(RouteCoordinate(latitude: values[1], longitude: values[0])) }
            }
            collectingKML = false; buffer = ""
        }
    }
}
