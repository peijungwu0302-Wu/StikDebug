import SwiftUI

struct MainTabView: View {
    @StateObject private var model = RouteLocationModel()

    var body: some View {
        RouteLocationRootView()
            .environmentObject(model)
            .environmentObject(model.playback)
    }
}
