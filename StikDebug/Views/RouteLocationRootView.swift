import SwiftUI
import UIKit

enum RouteLocationTab: Hashable {
    case map, routes, favorites, settings
}

struct RouteLocationRootView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @State private var selectedTab: RouteLocationTab = .map
    @AppStorage(AppLanguage.defaultsKey) private var appLanguage = AppLanguage.traditionalChinese.rawValue
    @ObservedObject private var toast = ToastManager.shared

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
        .onChange(of: model.statusMessage) { _, message in
            guard let message else { return }
            toast.show(message, kind: .success)
            model.statusMessage = nil
        }
        .alert("RouteLocation", isPresented: Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.presentedError = nil } }
        )) { Button("好") { model.presentedError = nil } } message: { Text(model.presentedError ?? "") }
        .overlay(alignment: .top) {
            if let message = toast.current {
                Text(message.text).font(.footnote).padding(10)
                    .background(.regularMaterial, in: Capsule()).padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .onTapGesture { toast.dismiss() }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast.current)
    }
}
