import SwiftUI

struct MainTabView: View {
    @StateObject private var model = RouteLocationModel()
    @AppStorage(AppearancePreference.defaultsKey)
    private var appearanceRawValue = AppearancePreference.system.rawValue

    var body: some View {
        RouteLocationRootView()
            .environmentObject(model)
            .environmentObject(model.playback)
            .preferredColorScheme(AppearancePreference.resolve(appearanceRawValue).colorScheme)
    }
}
