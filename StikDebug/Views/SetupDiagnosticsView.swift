import SwiftUI

struct SetupDiagnosticsView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var playback: RoutePlaybackEngine
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mounting = MountingProgress.shared
    @ObservedObject private var backgroundLocation = BackgroundLocationManager.shared
    @State private var showPairingImporter = false
    @State private var importStatus: String?
    @State private var pairingState = "檢查中"

    private var pairingPresent: Bool { FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path) }

    var body: some View {
        NavigationStack {
            List {
                Section("設定狀態") {
                    status("配對檔案", pairingState, pairingState == "已存在" ? .green : .orange)
                    status("裝置通道", tunnelStatus, tunnel.isConnected ? .green : .orange)
                    status("開發者磁碟映像", ddiStatus, mounting.coolisMounted ? .green : .orange)
                    status("位置模擬", playback.state.label, playback.state == .running ? .green : .gray)
                    status("DVT 工作階段", model.connectionMonitor.deviceSession.label, .gray)
                    status("網路", model.connectionMonitor.networkInterface.rawValue, model.connectionMonitor.internetReachable ? .green : .orange)
                    status("網際網路連線", model.connectionMonitor.internetReachable ? "可連線" : "離線", model.connectionMonitor.internetReachable ? .green : .orange)
                    status("VPN 介面", model.connectionMonitor.usesVPNInterface ? "已偵測" : "未偵測", .gray)
                }
                Section("配對檔案") {
                    Text("配對檔案是敏感的裝置信任憑證。請妥善保管；RouteLocation 只會儲存在本機，絕不會上傳內容。")
                        .font(.footnote)
                    Text("如果 iLoader 的「Manage Pairing File」沒有列出 RouteLocation，請在 iLoader 選擇 Export，將這台 iPhone 或 iPad 的配對檔案傳到裝置，再按下方按鈕手動匯入。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(pairingPresent ? "更換配對檔案" : "匯入配對檔案") { showPairingImporter = true }
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
                importStatus = "匯入成功。"
                NotificationCenter.default.post(name: .pairingFileImported, object: nil)
                startTunnelInBackground()
                refreshPairingState()
            } catch { importStatus = "匯入失敗：\(error.localizedDescription)" }
        }
        .task { refreshPairingState() }
    }

    private var ddiStatus: String {
        if mounting.coolisMounted { return "已掛載" }
        if mounting.mountingThread != nil { return "準備中" }
        if let error = mounting.lastErrorMessage { return "錯誤：\(error)" }
        return "未掛載"
    }

    private var tunnelStatus: String {
        if tunnel.isConnected { return "已連線" }
        if tunnel.isStarting { return "連線中" }
        if let error = tunnel.lastErrorMessage { return "錯誤：\(error)" }
        return "未連線"
    }

    private func refreshPairingState() {
        guard pairingPresent else { pairingState = "缺少"; return }
        pairingState = "檢查中"
        Task.detached {
            let valid = isPairing()
            await MainActor.run { pairingState = valid ? "已存在" : "無效／錯誤" }
        }
    }

    private var backgroundGuidance: String {
        switch backgroundLocation.authorizationStatus {
        case .authorizedAlways: return "已允許永遠取用位置。只有在播放期間才會啟用靜音音訊、低精確度定位與背景工作保活。"
        case .authorizedWhenInUse: return "若要提高背景播放持續運作的機會，請將位置權限設為「永遠」。"
        case .denied, .restricted: return "無法使用背景定位；切換到其他 App 後，播放可能會被暫停。"
        case .notDetermined: return "開始播放時會要求背景運作所需的位置權限。"
        @unknown default: return "請在 iOS「設定」檢查位置權限。"
        }
    }

    private func status(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack { Text(title); Spacer(); Circle().fill(color).frame(width: 8, height: 8); Text(value).foregroundStyle(.secondary) }
    }
}
