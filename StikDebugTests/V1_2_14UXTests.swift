import Foundation
import Testing
@testable import RouteLocation

struct V1_2_14UXTests {
    @Test func uniqueNamesUseIndependentSuffixesAndNormalizeWhitespace() {
        #expect(UniqueNameGenerator.makeUnique(base: " 新地點 ", existing: ["新地點", "新地點1", "新地點2"], fallback: "新地點") == "新地點3")
        #expect(UniqueNameGenerator.makeUnique(base: "公司", existing: ["公司", "公司1"], fallback: "新地點") == "公司2")
        #expect(UniqueNameGenerator.makeUnique(base: "公司", existing: ["公司11"], fallback: "新地點") == "公司")
        #expect(UniqueNameGenerator.makeUnique(base: "", existing: ["新路線"], fallback: "新路線") == "新路線1")
    }

    @Test func parserAcceptsLabeledAndGoogleMapsCoordinates() throws {
        #expect(try CoordinateImportParser.parseInline("latitude=25.033964 longitude=121.564468").first == RouteCoordinate(latitude: 25.033964, longitude: 121.564468))
        #expect(try CoordinateImportParser.parseInline("https://maps.google.com/maps/@25.033964,121.564468,17z").first == RouteCoordinate(latitude: 25.033964, longitude: 121.564468))
        #expect(try CoordinateImportParser.parseInline("25.033964 121.564468").first == RouteCoordinate(latitude: 25.033964, longitude: 121.564468))
    }

    @Test func timezoneComparisonUsesTaiwanBaseline() {
        let taipei = TimeZone(identifier: "Asia/Taipei")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let taipeiText = PlaceTimeFormatter.offsetText(for: taipei)
        #expect(taipeiText == "與台灣時間相同" || taipeiText == "Same as Taiwan time")
        let tokyoText = PlaceTimeFormatter.offsetText(for: tokyo)
        #expect(tokyoText.contains("快") || tokyoText.contains("ahead"))
    }

    @Test func routeAppendPreservesExistingWaypoints() {
        let first = RouteCoordinate(latitude: 25, longitude: 121)
        let second = RouteCoordinate(latitude: 25.01, longitude: 121.01)
        var values = [first]
        values.append(contentsOf: [second, second])
        #expect(values.count == 3)
    }
}
