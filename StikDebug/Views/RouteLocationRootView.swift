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
            AdaptiveRouteMapView().tabItem { Label("地圖", systemImage: "map") }.tag(RouteLocationTab.map)
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
        .alert(L10n.text("目前正在執行路線"), isPresented: $model.showModeSwitchAlert) {
            Button(L10n.text("取消"), role: .cancel) {
                model.cancelModeSwitch()
            }
            Button(L10n.text("切換到單點")) {
                Task { await model.confirmModeSwitchToSinglePoint() }
            }
        } message: {
            Text(L10n.text("切換到單點定位會停止目前路線，\n但不會刪除路線。"))
        }
        .alert(L10n.text("切換模擬路線"), isPresented: $model.showActiveRouteSwitchAlert) {
            Button(L10n.text("取消"), role: .cancel) {
                model.pendingSwitchRoute = nil
            }
            Button(L10n.text("切換路線")) {
                if let route = model.pendingSwitchRoute {
                    Task { await model.confirmSwitchToRoute(route) }
                }
            }
        } message: {
            if let pending = model.pendingSwitchRoute {
                Text(L10n.format("目前正在模擬「%@」，是否切換到「%@」？", model.playback.routeName, pending.name))
            } else {
                Text(L10n.text("是否切換模擬路線？"))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToRoutesTab)) { _ in
            selectedTab = .routes
        }
        .sheet(isPresented: $model.showBootstrapPreflightSheet) {
            BootstrapPreflightSheet(
                onRecheck: { model.confirmBootstrapPreflightRecheck() },
                onForceConnect: { model.confirmBootstrapPreflightForce() },
                onCancel: { model.cancelBootstrapPreflight() }
            )
        }
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
