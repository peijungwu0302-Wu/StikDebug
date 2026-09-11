import SwiftUI

struct SetupDiagnosticsView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var playback: RoutePlaybackEngine
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mounting = MountingProgress.shared
    @ObservedObject private var backgroundLocation = BackgroundLocationManager.shared
    @State private var showPairingImporter = false
    @State private var importStatus: String?
    @State private var pairingState: PairingDiagnosticState = .checking
    @State private var diagnosticInfo: DiagnosticInfo?
    @AppStorage(AppLanguage.defaultsKey) private var appLanguage = AppLanguage.traditionalChinese.rawValue

    private var pairingPresent: Bool { FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path) }

    var body: some View {
        NavigationStack {
            List {
                Section("設定狀態") {
                    status("配對檔案", pairingState.label, pairingState == .present ? .green : .orange, info: "這是目前裝置與受信任電腦之間的敏感信任憑證。RouteLocation 使用它建立裝置服務連線；它不是 IPA 簽名檔，也不會上傳。")
                    status("裝置通道", tunnelStatus, tunnel.isConnected ? .green : .orange, info: "透過 LocalDevVPN 建立的本機通道，讓 RouteLocation 能連接這台裝置。它與一般網際網路連線是不同狀態。")
                    status("開發者磁碟映像", ddiStatus, mounting.coolisMounted ? .green : .orange, info: "DDI 提供 Apple 開發者裝置服務。位置模擬前必須準備並掛載；首次下載需要網際網路。")
                    status("位置模擬", playback.state.label, playback.state == .running ? .green : .gray, info: "顯示目前是否正在傳送單點或路線位置。按下「恢復真實位置」可停止模擬並清除開發者位置。")
                    status("DVT 工作階段", model.connectionMonitor.deviceSession.label, .gray, info: "DVT 是實際傳送開發者位置指令的工作階段。若中斷，路線會保留經過時間並進行有限次重新連線。")
                    status("網路", model.connectionMonitor.networkInterface.label, model.connectionMonitor.internetReachable ? .green : .orange, info: "顯示目前使用 Wi-Fi、行動網路或離線。已快取的路線播放不需要網際網路。")
                    status("網際網路連線", model.connectionMonitor.internetReachable ? "可連線" : "離線", model.connectionMonitor.internetReachable ? .green : .orange, info: "Apple 地圖搜尋、新導航路線計算與首次 DDI 下載需要網際網路；直線及已儲存路線不需要。")
                    status("VPN 介面", model.connectionMonitor.usesVPNInterface ? "已偵測" : "未偵測", .gray, info: "顯示系統是否偵測到 VPN 介面。這只能作為提示，不等同於 DVT 工作階段已成功連線。")
                }
                Section("配對檔案") {
                    Text("配對檔案是敏感的裝置信任憑證。請妥善保管；RouteLocation 只會儲存在本機，絕不會上傳內容。")
                        .font(.footnote)
                    Text("如果 iLoader 的「Manage Pairing File」沒有列出 RouteLocation，請在 iLoader 選擇 Export，將這台 iPhone 或 iPad 的配對檔案傳到裝置，再按下方按鈕手動匯入。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(L10n.text(pairingPresent ? "更換配對檔案" : "匯入配對檔案")) { showPairingImporter = true }
                    if let importStatus { Text(importStatus).font(.footnote).foregroundStyle(.secondary) }
                }
                Section("連線") {
                    Button("重試裝置通道") { startTunnelInBackground() }
                    Button("檢查／掛載 DDI") { MountingProgress.shared.pubMount() }
                    Text("請啟動 LocalDevVPN，設定期間保持裝置喚醒及解鎖，並確認配對檔案屬於目前這台 iPhone 或 iPad。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("背景播放") {
                    Text(backgroundGuidance).font(.footnote)
                    Text("背景執行受 iOS 系統限制。強制結束 RouteLocation、重新啟動裝置、iOS 終止程序或系統層級錯誤都會停止播放。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("語言") {
                    Picker("介面語言", selection: $appLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    }
                    Text("繁體中文是預設語言；切換後會立即更新主要介面。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("隱私權") {
                    Text("沒有帳號、分析、遙測、後端、CloudKit 或路線上傳。只有在你要求 MapKit 圖磚、搜尋及導航計算時才會連接 Apple 服務。")
                        .font(.footnote)
                }
            }
            .navigationTitle("設定與診斷")
        }
        .fileImporter(isPresented: $showPairingImporter, allowedContentTypes: PairingFileStore.supportedContentTypes) { result in
            do {
                let url = try result.get()
                try PairingFileStore.importFromPicker(url)
                importStatus = L10n.text("匯入成功。")
                NotificationCenter.default.post(name: .pairingFileImported, object: nil)
                startTunnelInBackground()
                refreshPairingState()
            } catch { importStatus = L10n.format("匯入失敗：%@", error.localizedDescription) }
        }
        .task { refreshPairingState() }
        .alert(item: $diagnosticInfo) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("好")))
        }
    }

    private var ddiStatus: String {
        if mounting.coolisMounted { return L10n.text("已掛載") }
        if mounting.mountingThread != nil { return L10n.text("準備中") }
        if let error = mounting.lastErrorMessage { return L10n.format("錯誤：%@", error) }
        return L10n.text("未掛載")
    }

    private var tunnelStatus: String {
        if tunnel.isConnected { return L10n.text("已連線") }
        if tunnel.isStarting { return L10n.text("連線中") }
        if let error = tunnel.lastErrorMessage { return L10n.format("錯誤：%@", error) }
        return L10n.text("未連線")
    }

    private func refreshPairingState() {
        guard pairingPresent else { pairingState = .missing; return }
        pairingState = .checking
        Task.detached {
            let valid = isPairing()
            await MainActor.run { pairingState = valid ? .present : .invalid }
        }
    }

    private var backgroundGuidance: String {
        switch backgroundLocation.authorizationStatus {
        case .authorizedAlways: return L10n.text("已允許永遠取用位置。只有在播放期間才會啟用靜音音訊、低精確度定位與背景工作保活。")
        case .authorizedWhenInUse: return L10n.text("若要提高背景播放持續運作的機會，請將位置權限設為「永遠」。")
        case .denied, .restricted: return L10n.text("無法使用背景定位；切換到其他 App 後，播放可能會被暫停。")
        case .notDetermined: return L10n.text("開始播放時會要求背景運作所需的位置權限。")
        @unknown default: return L10n.text("請在 iOS「設定」檢查位置權限。")
        }
    }

    private func status(_ title: String, _ value: String, _ color: Color, info: String) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
            Button { diagnosticInfo = DiagnosticInfo(title: L10n.text(title), message: L10n.text(info)) } label: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            Spacer()
            Circle().fill(color).frame(width: 8, height: 8)
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

private struct DiagnosticInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum PairingDiagnosticState {
    case checking, present, missing, invalid

    var label: String {
        switch self {
        case .checking: return L10n.text("檢查中")
        case .present: return L10n.text("已存在")
        case .missing: return L10n.text("缺少")
        case .invalid: return L10n.text("無效／錯誤")
        }
    }
}
