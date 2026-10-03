import SwiftUI
import UIKit

enum RouteLocationTab: Hashable {
    case map, my, settings
}

struct RouteLocationRootView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var playback: RoutePlaybackEngine
    @State private var selectedTab: RouteLocationTab = .map
    @State private var showPairingImporter = false
    @AppStorage(AppLanguage.defaultsKey) private var appLanguage = AppLanguage.traditionalChinese.rawValue
    @AppStorage("RouteLocation.showMiniPlayer") private var showMiniPlayer = true
    @ObservedObject private var toast = ToastManager.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                AdaptiveRouteMapView()
                    .tabItem { Label(L10n.text("地圖"), systemImage: "map") }
                    .tag(RouteLocationTab.map)
                MyLibraryView(selectedTab: $selectedTab)
                    .tabItem { Label(L10n.text("我的"), systemImage: "tray.full") }
                    .tag(RouteLocationTab.my)
                SettingsView()
                    .tabItem { Label(L10n.text("設定"), systemImage: "gearshape") }
                    .tag(RouteLocationTab.settings)
            }

            // Active Mini Player — only visible on non-map tabs when simulation is active
            if selectedTab != .map && model.simulationMode.isSimulating && showMiniPlayer {
                ActiveSimulationMiniPlayer {
                    selectedTab = .map
                }
                .padding(.bottom, 50) // Above tab bar
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedTab)
        .animation(.easeInOut(duration: 0.25), value: model.simulationMode.isSimulating)
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
        )) { Button(L10n.text("好")) { model.presentedError = nil } } message: { Text(model.presentedError ?? "") }
        .alert(L10n.text("定位連線已中斷"), isPresented: $model.showPlaybackRecoveryConsent) {
            Button(L10n.text("重新建立連線")) { model.approvePlaybackRecovery() }
            Button(L10n.text("結束路線"), role: .destructive) { model.endPlaybackRecovery() }
        } message: {
            Text(L10n.text("路線已暫停在目前位置。重新建立定位需要暫時關閉行動數據。"))
        }
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
            selectedTab = .my
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPairingFilePicker)) { _ in
            selectedTab = .settings
            showPairingImporter = true
        }
        .fileImporter(isPresented: $showPairingImporter, allowedContentTypes: PairingFileStore.supportedContentTypes) { result in
            do {
                try PairingFileStore.importFromPicker(try result.get())
                ToastManager.shared.show(L10n.text("匯入成功。"), kind: .success)
                NotificationCenter.default.post(name: .pairingFileImported, object: nil)
                TunnelManager.shared.start()
            } catch {
                let cocoaError = error as NSError
                if cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == NSUserCancelledError {
                    return
                }
                model.presentedError = L10n.format("匯入失敗：%@", error.localizedDescription)
            }
        }
        .sheet(isPresented: $model.showBootstrapPreflightSheet) {
            BootstrapPreflightSheet(
                onStartAssisted: { model.startAssistedBootstrapFromPreflight() },
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
