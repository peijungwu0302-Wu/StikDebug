import SwiftUI

struct MainTabView: View {
    @StateObject private var model = MainTabView.makeModel()
    @AppStorage(AppearancePreference.defaultsKey)
    private var appearanceRawValue = AppearancePreference.system.rawValue

    @MainActor
    private static func makeModel() -> RouteLocationModel {
        #if DEBUG && targetEnvironment(simulator)
        if GuideScreenshotFixture.scenario != nil { return GuideScreenshotFixture.makeModel() }
        #endif
        return RouteLocationModel()
    }

    var body: some View {
        RouteLocationRootView()
            .environmentObject(model)
            .environmentObject(model.playback)
            .preferredColorScheme(AppearancePreference.resolve(appearanceRawValue).colorScheme)
    }
}
