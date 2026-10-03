import Testing
@testable import RouteLocation

struct V1_2_21PresentationTests {
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
