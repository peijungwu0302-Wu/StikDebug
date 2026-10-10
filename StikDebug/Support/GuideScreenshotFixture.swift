#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Explicit UI-test demonstration only. Never compiled into device/Release apps.
/// Uses temporary local data and a sink that rejects every device command.
@MainActor
enum GuideScreenshotFixture {
    static var scenario: String? {
        ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--guide-demo=") })?
            .replacingOccurrences(of: "--guide-demo=", with: "")
    }

    static func makeModel() -> RouteLocationModel {
        RouteLocationModel(
            persistence: RoutePersistenceStore(rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("GuideDemo-\(UUID().uuidString)", isDirectory: true)),
            simulationService: ScreenshotRejectingSink()
        )
    }

    static func prepare(_ model: RouteLocationModel) async {
        guard let scenario else { return }
        let taipei101 = RouteCoordinate(latitude: 25.033964, longitude: 121.564468)
        model.mapInteractionStyle = scenario == "classicPreview" ? .classic : .quickRoute
        if ["editor", "player", "library", "preview", "classicPreview"].contains(scenario) {
            model.quickRouteMode = .route
            model.routeName = "Taipei 101 Demo"
            model.addWaypoint(taipei101)
            model.addWaypoint(RouteCoordinate(latitude: 25.040123, longitude: 121.570456))
            model.addWaypoint(RouteCoordinate(latitude: 25.028765, longitude: 121.568321))
            if scenario == "library" {
                _ = await model.saveCurrentRoute()
                await model.addFavorite(name: "Taipei 101", coordinate: taipei101)
            }
            if ["preview", "classicPreview"].contains(scenario) {
                _ = await model.saveCurrentRoute()
                if let route = model.currentSavedRoute { model.previewRoute(route) }
            }
            if scenario == "player" {
                model.playback.testSetScreenshotMetadataForTesting(name: model.routeName, speed: 18.6)
                model.playback.testSetStateForTesting(.running, currentCoordinate: taipei101)
                model.testSetSimulationModeForTesting(.routePlaying)
            }
        } else if scenario == "singlePoint" {
            model.selectedCoordinate = taipei101
            model.testSetSimulationModeForTesting(.singlePoint(taipei101))
        }
    }

    private struct ScreenshotRejectingSink: LocationSimulationSink {
        func setCoordinate(_ coordinate: RouteCoordinate) async throws {
            throw LocationSimulationError.deviceTunnelUnavailable
        }
        func clearSimulatedLocation() async throws {
            throw LocationSimulationError.deviceTunnelUnavailable
        }
    }
}

struct GuideScreenshotPresentationModifier: ViewModifier {
    @EnvironmentObject private var model: RouteLocationModel
    @State private var ready = false
    @State private var showEditor = false

    func body(content: Content) -> some View {
        content
            .task {
                guard GuideScreenshotFixture.scenario != nil, !ready else { return }
                await GuideScreenshotFixture.prepare(model)
                ready = true
                showEditor = GuideScreenshotFixture.scenario == "editor"
            }
            .overlay(alignment: .top) {
                if ready {
                    Text("Simulator UI demonstration")
                        .font(.caption2).padding(3).background(.regularMaterial)
                        .accessibilityIdentifier("guide.fixture.ready")
                        .allowsHitTesting(false)
                }
            }
            .sheet(isPresented: $showEditor) { RouteEditorView() }
    }
}
#endif
