import Foundation
import Testing
@testable import RouteLocation

struct V1_2_27LayoutTests {
    @Test func missingOrUnknownLayoutUsesFullAndTutorialOverrideDoesNotPersist() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(QuickMapLayoutPreference.resolve(defaults.string(forKey: QuickMapLayoutPreference.defaultsKey)) == .full)
        #expect(QuickMapLayoutPreference.resolve("unknown") == .full)
        defaults.set("compact", forKey: QuickMapLayoutPreference.defaultsKey)
        #expect(QuickMapLayoutPreference.effective(defaults.string(forKey: QuickMapLayoutPreference.defaultsKey), tutorialActive: false) == .compact)
        #expect(QuickMapLayoutPreference.effective(defaults.string(forKey: QuickMapLayoutPreference.defaultsKey), tutorialActive: true) == .full)
        #expect(defaults.string(forKey: QuickMapLayoutPreference.defaultsKey) == "compact")
    }

    @MainActor @Test func changingLayoutDoesNotChangeDraftOrSinglePointSimulation() {
        let model = RouteLocationModel()
        let a = RouteCoordinate(latitude: 25.033964, longitude: 121.564468)
        let b = RouteCoordinate(latitude: 25.04, longitude: 121.57)
        model.replaceWaypoints([a, b])
        model.testSetSimulationModeForTesting(.singlePoint(a))
        let geometry = model.geometry
        let speed = model.speedKmh
        for layout in QuickMapLayoutPreference.allCases {
            #expect(QuickMapLayoutPreference.resolve(layout.rawValue) == layout)
            #expect(MapTapRoutePolicy.action(mode: .route, routeIsActive: false) == .addWaypoint)
            #expect(MapTapRoutePolicy.action(mode: .singlePoint, routeIsActive: false) == .selectPlace)
        }
        #expect(model.waypoints == [a, b])
        #expect(model.geometry == geometry)
        #expect(model.speedKmh == speed)
        #expect(model.simulationMode == .singlePoint(a))
    }
}
