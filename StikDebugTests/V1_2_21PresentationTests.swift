import Foundation
import Testing
@testable import RouteLocation

struct V1_2_21PresentationTests {
    @Test func guideContentHasBothLanguageEntriesWithoutFallback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let keys = UserGuideTopic.all.flatMap { [$0.title, $0.summary, $0.note] + $0.steps }
        for language in ["en", "zh-Hant"] {
            let data = try Data(contentsOf: root.appendingPathComponent("StikDebug/\(language).lproj/Localizable.strings"))
            let entries = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            for key in keys {
                #expect(entries[key]?.isEmpty == false, "Missing \(language) guide translation: \(key)")
            }
        }
    }

    @Test func interruptedRouteKeepsControlsButCannotAdjustSpeed() {
        let state = PlaybackRunState.error("Connection interrupted")
        #expect(state.showsRouteControls)
        #expect(!state.allowsSpeedEditing)
        #expect(state.interruptionMessage == "Connection interrupted")
        #expect(PlaybackRunState.paused.showsRouteControls)
        #expect(PlaybackRunState.paused.allowsSpeedEditing)
        #expect(!PlaybackRunState.completed.showsRouteControls)
        #expect(!PlaybackRunState.stopped.showsRouteControls)
        #expect(!PlaybackRunState.reconnecting.allowsSpeedEditing)
    }

    @Test func invalidRepeatInputCannotBeSubmitted() {
        for text in ["", "0", "-1", "10000", "1.5", "abc"] {
            #expect(RouteRepeatEntryPolicy.finiteCount(text) == nil)
        }
        #expect(RouteRepeatEntryPolicy.finiteCount(" 3 ") == 3)
        #expect(RouteRepeatEntryPolicy.finiteCount("9999") == 9999)
    }
}
