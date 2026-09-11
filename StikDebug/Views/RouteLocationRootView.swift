import SwiftUI
import UIKit

enum RouteLocationTab: Hashable {
    case map, routes, favorites, settings
}

struct RouteLocationRootView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @State private var selectedTab: RouteLocationTab = .map
    @AppStorage(AppLanguage.defaultsKey) private var appLanguage = AppLanguage.traditionalChinese.rawValue

    var body: some View {
        TabView(selection: $selectedTab) {
            RouteMapView().tabItem { Label("地圖", systemImage: "map") }.tag(RouteLocationTab.map)
            RouteEditorView().tabItem { Label("路線", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }.tag(RouteLocationTab.routes)
            FavoritesView(selectedTab: $selectedTab).tabItem { Label("喜愛", systemImage: "star") }.tag(RouteLocationTab.favorites)
            SetupDiagnosticsView().tabItem { Label("設定", systemImage: "gearshape") }.tag(RouteLocationTab.settings)
        }
        .onChange(of: selectedTab) { _, _ in
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .environment(\.locale, Locale(identifier: appLanguage))
        .alert("RouteLocation", isPresented: Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.presentedError = nil } }
        )) { Button("好") { model.presentedError = nil } } message: { Text(model.presentedError ?? "") }
        .overlay(alignment: .top) {
            if let status = model.statusMessage {
                Text(status).font(.footnote).padding(10).background(.regularMaterial, in: Capsule()).padding(.top, 8)
                    .onTapGesture { model.statusMessage = nil }
            }
        }
    }
}
