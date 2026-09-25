import SwiftUI
import UIKit

struct SetupDiagnosticsView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var playback: RoutePlaybackEngine
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mounting = MountingProgress.shared
    @ObservedObject private var backgroundLocation = BackgroundLocationManager.shared
    @ObservedObject private var dataPath = LocationDataPathHealth.shared
    @ObservedObject private var healthSteps = HealthStepSyncService.shared
    @ObservedObject private var diagnosticsStore = DeveloperDiagnosticsStore.shared
    @ObservedObject private var shortcutService = ShortcutBootstrapService.shared
    @ObservedObject private var signingService = SigningStatusService.shared
    @ObservedObject private var selfRefresh = SelfRefreshCoordinator.shared
    @State private var showPairingImporter = false
    @State private var showDeletePairingConfirm = false
    @State private var pairingState: PairingDiagnosticState = .checking
    @State private var diagnosticInfo: DiagnosticInfo?
    @State private var showManualStepEntry = false
    @State private var showManualStepConfirm = false
    @State private var manualStepText = "500"
    @State private var versionTapCount = 0
    @AppStorage(AppLanguage.defaultsKey) private var appLanguage = AppLanguage.traditionalChinese.rawValue

    private var pairingPresent: Bool { FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path) }

    var body: some View {
        NavigationStack {
            List {
                Section("設定狀態") {
                    status("配對檔案", pairingState.label, pairingState == .present ? .green : .orange, info: "這是目前裝置與受信任電腦之間的敏感信任憑證。RouteLocation 使用它建立裝置服務連線；它不是 IPA 簽名檔，也不會上傳。")
                    status("LocalDevVPN 介面", localVPNStatus, effectiveTunnelHealthy ? .green : .orange, info: "LocalDevVPN 提供本機裝置服務路徑；它與行動網路的 Internet 狀態彼此獨立。")
                    status("裝置 Bootstrap", tunnel.bootstrapAvailable ? "可用" : "目前傳輸不可用", tunnel.bootstrapAvailable ? .green : .orange, info: "表示能否開啟新的裝置連線。新連線被拒絕不代表既有 DVT 定位工作階段已失效。")
                    status("裝置通道", tunnelStatus, effectiveTunnelHealthy ? .green : .orange, info: "顯示既有裝置通道狀態；真實定位指令成功時，不會因輔助 Bootstrap 探測失敗而拆除工作階段。")
                    status("RSD", rsdStatus, effectiveTunnelHealthy ? .green : .orange, info: "RSD 是 DVT 服務發現層。既有 DVT 工作階段可在新的 RSD 探測暫時失敗時繼續工作。")
                    status("開發者磁碟映像", ddiStatus, mounting.coolisMounted ? .green : .orange, info: "DDI 提供 Apple 開發者裝置服務。位置模擬前必須準備並掛載；首次下載需要網際網路。")
                    status("位置模擬", simulationStatus, simulationIsActive ? .green : .gray, info: "顯示目前是否正在傳送單點或路線位置。按下「恢復真實位置」可停止模擬並清除開發者位置。")
                    status("DVT 工作階段", model.connectionMonitor.deviceSession.label, dvtColor, info: "DVT 是實際傳送開發者位置指令的工作階段。若中斷，路線會保留單調時鐘的經過時間並進行有限次重新連線。")
                    status("定位更新", dataPath.status.label, dataPath.status == .healthy ? .green : .orange, info: "真實 setLocation 指令的結果是最高優先健康訊號；連續三次真實失敗後才會開始恢復。")
                    status("傳輸方式", model.connectionMonitor.currentTransport.label, model.connectionMonitor.currentTransport == .offline ? .orange : .green, info: "顯示目前使用 Wi-Fi、行動網路或其他傳輸。RouteLocation 不要求 Wi-Fi；行動網路搭配 LocalDevVPN 是有效啟動方式。")
                    status("網際網路連線", model.connectionMonitor.internetReachable ? "可連線" : "離線", model.connectionMonitor.internetReachable ? .green : .orange, info: "Apple 地圖搜尋、新導航路線計算與首次 DDI 下載需要網際網路；直線及已儲存路線不需要。")
                    status("VPN 介面", model.connectionMonitor.usesVPNInterface ? "已偵測" : "未偵測", .gray, info: "顯示系統是否偵測到 VPN 介面。這只能作為提示，不等同於 DVT 工作階段已成功連線。")
                }
                Section("配對檔案") {
                    HStack {
                        Text("配對驗證狀態")
                        Spacer()
                        Text(pairingState.label)
                            .foregroundStyle(pairingState == .present ? .green : (pairingState == .invalid ? .red : .orange))
                    }
                    HStack {
                        Text("來源")
                        Spacer()
                        Text(PairingFileStore.currentSource.label)
                            .foregroundStyle(.secondary)
                    }
                    if pairingPresent {
                        HStack {
                            Text("儲存位置")
                            Spacer()
                            Text(PairingFileStore.canonicalRelativePath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("重新驗證配對檔案") {
                        refreshPairingState()
                    }
                    Button(L10n.text(pairingPresent ? "更換配對檔案" : "匯入配對檔案")) {
                        showPairingImporter = true
                    }
                    if pairingPresent {
                        Button("移除配對檔案", role: .destructive) {
                            showDeletePairingConfirm = true
                        }
                    }
                    Text("配對檔案是敏感的裝置信任憑證。請妥善保管；RouteLocation 只會儲存在本機，絕不會上傳內容。")
                        .font(.footnote)
                    Text("如果 iLoader 的「Manage Pairing File」沒有列出 RouteLocation，請在 iLoader 選擇 Export，將這台 iPhone 或 iPad 的配對檔案傳到裝置，再按「匯入配對檔案」按鈕手動匯入。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("連線") {
                    Button("檢查／重試裝置通道") {
                        if model.isCellularBootstrapPreparationNeeded {
                            model.requestBootstrapIfCellular {
                                tunnel.checkHealthNow(transport: model.connectionMonitor.currentTransport)
                            }
                        } else {
                            tunnel.checkHealthNow(transport: model.connectionMonitor.currentTransport)
                        }
                    }
                    Button("檢查／掛載 DDI") { MountingProgress.shared.pubMount() }
                    Text("請啟動 LocalDevVPN，使用 Wi-Fi 或行動網路皆可。設定期間保持裝置喚醒及解鎖，並確認配對檔案屬於目前這台 iPhone 或 iPad。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if tunnel.cellularBootstrapRequested {
                    Section("行動網路 Bootstrap 模式") {
                        Text("請暫時關閉行動數據以初始化定位通道。完成後即可重新開啟。")
                        Text("1. 保持 LocalDevVPN 開啟。\n2. 暫時關閉行動數據，不需要開啟飛航模式。\n3. 返回 RouteLocation；系統會自動繼續建立裝置通道。\n4. DVT 與首次定位指令成功後，再重新開啟行動數據。")
                            .font(.footnote)
                        Text("RouteLocation 不會自動切換行動數據或飛航模式；此流程不需要 Wi-Fi。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("介面與操作") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("地圖操作模式", selection: $model.mapInteractionStyle) {
                            ForEach(MapInteractionStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        Text(model.mapInteractionStyle.detail)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("切換定位模式時", selection: $model.modeSwitchConfirmation) {
                            ForEach(ModeSwitchConfirmation.allCases) { conf in
                                Text(conf.title).tag(conf)
                            }
                        }
                        Text(model.modeSwitchConfirmation.detail)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("健康同步") {
                    Toggle("路線播放時同步步數", isOn: $healthSteps.isEnabled)
                        .onChange(of: healthSteps.isEnabled) { _, enabled in
                            if enabled {
                                Task { await healthSteps.requestAuthorization() }
                            }
                        }
                    HStack {
                        Text("HealthKit 狀態")
                        Spacer()
                        Text(healthSteps.isHealthDataAvailable ? L10n.text("可用") : L10n.text("不可用"))
                            .foregroundStyle(healthSteps.isHealthDataAvailable ? .green : .orange)
                    }
                    HStack {
                        Text("步數寫入權限")
                        Spacer()
                        Text(healthSteps.authorizationState.label)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("計算方式").font(.caption).foregroundStyle(.secondary)
                        Picker("計算方式", selection: $healthSteps.calculationMode) {
                            ForEach(StepCalculationMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    if healthSteps.calculationMode == .fixedCadence {
                        HStack {
                            Text("步頻")
                            Spacer()
                            TextField("160", value: $healthSteps.cadenceStepsPerMinute, format: .number.precision(.fractionLength(0)))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text("步／分鐘")
                        }
                    } else {
                        HStack {
                            Text("步長")
                            Spacer()
                            TextField("0.80", value: $healthSteps.strideLengthMeters, format: .number.precision(.fractionLength(2)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text("公尺／步")
                        }
                    }
                    HStack {
                        Text("最近一次寫入")
                        Spacer()
                        Text(healthSteps.lastWriteStatus.label)
                            .foregroundStyle(.secondary)
                    }
                    if let lastError = healthSteps.lastError {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("最近錯誤").font(.caption).foregroundStyle(.red)
                            Text(lastError.formattedDetails)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("測試寫入 10 步") {
                        Task {
                            let result = await healthSteps.testWriteTenSteps()
                            switch result {
                            case .success(let msg):
                                ToastManager.shared.show(msg, kind: .success)
                            case .failure(let err):
                                ToastManager.shared.show(L10n.format("寫入失敗：%@ (%d)", err.localizedDescription, err.code), kind: .error)
                            }
                        }
                    }
                    Button("手動新增 RouteLocation 步數") {
                        showManualStepEntry = true
                    }
                    Text("只在路線實際播放時按新增時間或距離批次寫入；單點傳送不會增加步數。HealthKit 權限或錯誤不會影響定位模擬。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("行動網路啟動策略") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("啟動策略", selection: $shortcutService.cellularBootstrapPolicy) {
                            ForEach(CellularBootstrapPolicy.allCases) { policy in
                                Text(policy.title).tag(policy)
                            }
                        }
                        Text(shortcutService.cellularBootstrapPolicy.detail)
                            .font(.footnote).foregroundStyle(.secondary)
                    }

                    Toggle("Apple 捷徑自動切換輔助（選用）", isOn: $shortcutService.isShortcutAssistedEnabled)

                    if shortcutService.isShortcutAssistedEnabled {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("捷徑執行提示", selection: $shortcutService.shortcutPromptMode) {
                                ForEach(ShortcutExecutionPrompt.allCases) { prompt in
                                    Text(prompt.title).tag(prompt)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        HStack {
                            Text("捷徑名稱")
                            Spacer()
                            TextField("RouteLocationBootstrap", text: $shortcutService.shortcutName)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 180)
                        }

                        Button("複製捷徑設定步驟教學") {
                            UIPasteboard.general.string = ShortcutBootstrapService.shortcutSetupGuide
                            ToastManager.shared.show(L10n.text("已複製教學到剪貼簿"), kind: .success)
                        }

                        Button("測試執行捷徑") {
                            let started = shortcutService.startShortcutBootstrapTransaction { success in
                                if success {
                                    ToastManager.shared.show(L10n.text("捷徑測試成功！"), kind: .success)
                                } else {
                                    ToastManager.shared.show(L10n.text("捷徑測試失敗或逾時"), kind: .error)
                                }
                            }
                            if !started {
                                ToastManager.shared.show(L10n.text("無法啟動捷徑，請檢查名稱是否相符"), kind: .error)
                            }
                        }

                        Text("捷徑為完全選用功能；關閉時絕不呼叫 shortcuts://。無論是否開啟捷徑，所有流程均提供手動完成選項。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("安全診斷") {
                    Button("複製安全診斷報告") { copySanitizedDiagnosticReport() }
                    Text("報告只包含狀態、傳輸類型、錯誤分類與目標位址；不包含配對檔內容、私鑰、憑證或帳號資料。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if diagnosticsStore.isDeveloperModeUnlocked {
                    Section("開發者診斷工具") {
                        NavigationLink {
                            DeveloperDiagnosticsView()
                        } label: {
                            Label("開發者診斷 (Developer Diagnostics)", systemImage: "stethoscope")
                        }

                        NavigationLink {
                            CellularBootstrapLabView()
                        } label: {
                            Label("行動網路實驗室 (Cellular Lab)", systemImage: "antenna.radiowaves.left.and.right")
                        }

                        Button(role: .destructive) {
                            diagnosticsStore.lockDeveloperMode()
                            ToastManager.shared.show(L10n.text("已關閉開發者模式"), kind: .info)
                        } label: {
                            Text("關閉開發者模式")
                        }
                    }
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
                SigningAndRefreshSectionView(
                    signingService: signingService,
                    diagnosticsStore: diagnosticsStore,
                    selfRefresh: selfRefresh,
                    model: model,
                    openSideStoreApp: openSideStoreApp
                )
                Section("SideStore 更新") {
                    Text("RouteLocation 不會自動更新。您可以加入官方 SideStore Source，由 SideStore 進行簽名與更新管理，或前往 GitHub 查看發行版本。")
                        .font(.footnote)

                    Button {
                        openSideStoreSource()
                    } label: {
                        Label("加入 RouteLocation Source", systemImage: "plus.circle")
                    }

                    Button {
                        copySourceURL()
                    } label: {
                        Label("複製 Source URL", systemImage: "doc.on.doc")
                    }

                    Button {
                        openReleasesPage()
                    } label: {
                        Label("查看 GitHub Releases", systemImage: "arrow.up.right.square")
                    }

                    Text("選用功能：您可隨時透過 SideStore 檢查與更新，舊版本仍可正常使用各項功能。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("關於 RouteLocation") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("RouteLocation \(diagnosticsStore.installationIdentity.version)")
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                versionTapCount += 1
                                if versionTapCount >= 7 {
                                    versionTapCount = 0
                                    diagnosticsStore.isDeveloperModeUnlocked.toggle()
                                    let generator = UINotificationFeedbackGenerator()
                                    generator.notificationOccurred(.success)
                                    ToastManager.shared.show(
                                        diagnosticsStore.isDeveloperModeUnlocked
                                            ? L10n.text("已解鎖開發者診斷模式 🛠️")
                                            : L10n.text("已鎖定開發者診斷模式"),
                                        kind: .success
                                    )
                                }
                            }
                    }
                    if diagnosticsStore.isDeveloperModeUnlocked {
                        HStack {
                            Text("開發者模式")
                            Spacer()
                            Text("已啟用").foregroundStyle(.green).bold()
                        }
                    }
                }
            }
            .navigationTitle("設定與診斷")
        }
        .fileImporter(isPresented: $showPairingImporter, allowedContentTypes: PairingFileStore.supportedContentTypes) { result in
            do {
                let url = try result.get()
                try PairingFileStore.importFromPicker(url)
                ToastManager.shared.show(L10n.text("匯入成功。"), kind: .success)
                NotificationCenter.default.post(name: .pairingFileImported, object: nil)
                startTunnelInBackground()
                refreshPairingState()
            } catch { ToastManager.shared.show(L10n.format("匯入失敗：%@", error.localizedDescription), kind: .error) }
        }
        .task { refreshPairingState() }
        .alert(item: $diagnosticInfo) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("好")))
        }
        .alert(L10n.text("手動新增 RouteLocation 步數"), isPresented: $showManualStepEntry) {
            TextField("500", text: $manualStepText)
                .keyboardType(.numberPad)
            Button(L10n.text("下一步")) {
                if let steps = Int(manualStepText), steps > 0 {
                    showManualStepConfirm = true
                } else {
                    ToastManager.shared.show(L10n.text("請輸入大於 0 的有效步數。"), kind: .error)
                }
            }
            Button(L10n.text("取消"), role: .cancel) { manualStepText = "500" }
        } message: {
            Text(L10n.text("輸入要新增至 Apple 健康的步數："))
        }
        .alert(L10n.text("手動新增步數"), isPresented: $showManualStepConfirm) {
            Button(L10n.text("新增")) {
                if let steps = Int(manualStepText), steps > 0 {
                    Task {
                        let result = await healthSteps.manualAddSteps(steps)
                        switch result {
                        case .success(let msg):
                            ToastManager.shared.show(msg, kind: .success)
                        case .failure(let err):
                            ToastManager.shared.show(L10n.format("寫入失敗：%@ (%d)", err.localizedDescription, err.code), kind: .error)
                        }
                    }
                }
                manualStepText = "500"
            }
            Button(L10n.text("取消"), role: .cancel) { manualStepText = "500" }
        } message: {
            Text(L10n.format("將由 RouteLocation 新增 %d 步至 Apple 健康。", Int(manualStepText) ?? 0))
        }
        .alert(L10n.text("確定要移除配對檔案？"), isPresented: $showDeletePairingConfirm) {
            Button(L10n.text("移除"), role: .destructive) {
                try? PairingFileStore.remove()
                refreshPairingState()
                ToastManager.shared.show(L10n.text("已移除配對檔案"), kind: .info)
            }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("移除後將無法建立新的 DVT 裝置通道，直到重新匯入有效的配對檔案。"))
        }
        .alert(L10n.text("目前正在模擬位置"), isPresented: $selfRefresh.showSimulationStopPrompt) {
            Button(L10n.text("停止模擬並重新整理")) {
                selfRefresh.confirmStopSimulationAndContinue(model: model)
            }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("重新整理簽名前必須先停止目前模擬並恢復裝置真實位置。"))
        }
        .alert(L10n.text("目前需要 Wi-Fi"), isPresented: $selfRefresh.showCellularBlockedAlert) {
            Button(L10n.text("好"), role: .cancel) {}
        } message: {
            Text(L10n.text("重新整理簽名目前僅支援 Wi-Fi + LocalDevVPN 連線，不支援行動網路單獨重新整理。請連線至 Wi-Fi 後再試。"))
        }
        .alert(L10n.text("需要 LocalDevVPN"), isPresented: $selfRefresh.showMissingVPNAlert) {
            Button(L10n.text("好"), role: .cancel) {}
        } message: {
            Text(L10n.text("請先至 WireGuard 或設定中啟動 LocalDevVPN 介面。"))
        }
        .alert(L10n.text("重新整理提示"), isPresented: $selfRefresh.showActionableErrorAlert) {
            Button(L10n.text("在 SideStore 中開啟")) {
                openSideStoreApp()
            }
            Button(L10n.text("好"), role: .cancel) {}
        } message: {
            Text(selfRefresh.lastErrorMessage ?? L10n.text("重新整理需要 SideStore 支援。"))
        }
    }

    private var ddiStatus: String {
        if mounting.coolisMounted { return L10n.text("已掛載") }
        if mounting.mountingThread != nil { return L10n.text("準備中") }
        if let error = mounting.lastErrorMessage { return L10n.format("錯誤：%@", error) }
        return L10n.text("未掛載")
    }

    private var tunnelStatus: String {
        if tunnel.isStarting { return L10n.format("%@（第 %d 次）", tunnel.stage.label, max(tunnel.reconnectAttempt, 1)) }
        if model.connectionMonitor.deviceSession == .connected || dataPath.hasRecentSuccess { return L10n.text("已連線") }
        if tunnel.isConnected { return tunnel.stage.label }
        if let error = tunnel.lastErrorMessage { return L10n.format("錯誤：%@", error) }
        return L10n.text("未連線")
    }

    private var localVPNStatus: String {
        if model.connectionMonitor.usesVPNInterface { return L10n.text("已連線") }
        if dataPath.hasRecentSuccess { return L10n.text("已連線（由定位更新確認）") }
        return L10n.text("未偵測")
    }

    private var simulationIsActive: Bool {
        playback.state == .running || playback.state == .reconnecting || model.connectionMonitor.deviceSession == .connected
    }

    private var simulationStatus: String {
        if playback.state == .running || playback.state == .reconnecting { return playback.state.label }
        if model.connectionMonitor.deviceSession == .connected { return L10n.text("單點模擬中") }
        if case .error = playback.state { return playback.state.label }
        return L10n.text("閒置")
    }

    private var dvtColor: Color {
        switch model.connectionMonitor.deviceSession {
        case .connected: return .green
        case .reconnecting: return .orange
        case .error: return .red
        case .idle: return .gray
        }
    }

    private func openSideStoreApp() {
        if let url = URL(string: "sidestore://"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let url = SideStoreSourceConfig.sideStoreDeepLinkURL {
            UIApplication.shared.open(url)
        } else {
            ToastManager.shared.show(L10n.text("未偵測到 SideStore App，請手動開啟 SideStore 進行重新整理。"), kind: .info)
        }
    }

    private func openSideStoreSource() {
        guard let url = SideStoreSourceConfig.sideStoreDeepLinkURL else { return }
        UIApplication.shared.open(url) { success in
            if !success {
                UIPasteboard.general.string = SideStoreSourceConfig.rawSourceURLString
                ToastManager.shared.show(L10n.text("無法直接開啟 SideStore，已複製 Source 網址到剪貼簿。"), kind: .info)
            }
        }
    }

    private func copySourceURL() {
        UIPasteboard.general.string = SideStoreSourceConfig.rawSourceURLString
        ToastManager.shared.show(L10n.text("已複製 SideStore Source 網址。"), kind: .success)
    }

    private func openReleasesPage() {
        guard let url = SideStoreSourceConfig.releasesWebURL else { return }
        UIApplication.shared.open(url)
    }

    private func copySanitizedDiagnosticReport() {
        let pairingLabel = pairingState.label
        let report = """
        RouteLocation Cellular Diagnostic
        Time: \(ISO8601DateFormatter().string(from: .now))
        Transport: \(model.connectionMonitor.currentTransport.rawValue)
        Previous transport: \(model.connectionMonitor.previousTransport.rawValue)
        NWPath satisfied: \(model.connectionMonitor.internetReachable)
        Expensive path: \(model.connectionMonitor.pathIsExpensive)
        VPN interface detected: \(model.connectionMonitor.usesVPNInterface)
        Pairing file: \(pairingLabel)
        Tunnel stage: \(tunnel.stage.rawValue)
        Tunnel connected: \(tunnel.isConnected)
        Tunnel error: \(tunnel.lastErrorMessage ?? "none")
        Bootstrap available: \(tunnel.bootstrapAvailable)
        Location update health: \(dataPath.status.label)
        Consecutive location failures: \(dataPath.consecutiveLocationFailures)
        Last successful location update: \(dataPath.lastSuccessfulLocationUpdate.map { ISO8601DateFormatter().string(from: $0) } ?? "none")
        Last tunnel probe: \(dataPath.lastTunnelHealthProbeResult ?? "none")
        DDI: \(ddiStatus)
        DVT: \(model.connectionMonitor.deviceSession.label)
        Simulation: \(simulationStatus)
        Target: \(DeviceConnectionContext.targetIPAddress):49152
        """
        UIPasteboard.general.string = report
        ToastManager.shared.show(L10n.text("已複製；報告不包含配對憑證。"), kind: .success)
    }

    private var effectiveTunnelHealthy: Bool {
        tunnel.isConnected || model.connectionMonitor.deviceSession == .connected || dataPath.hasRecentSuccess
    }

    private var rsdStatus: String {
        if model.connectionMonitor.deviceSession == .connected || dataPath.hasRecentSuccess { return L10n.text("已連線") }
        return tunnel.stage == .rsdDiscovery ? tunnel.stage.label : L10n.text("未連線")
    }

    private func refreshPairingState() {
        guard pairingPresent else { pairingState = .missing; return }
        pairingState = .checking
        Task.detached {
            let validation = PairingFileStore.validateCurrentPairing()
            let valid = validation.isValid && isPairing()
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

private struct SigningAndRefreshSectionView: View {
    @ObservedObject var signingService: SigningStatusService
    @ObservedObject var diagnosticsStore: DeveloperDiagnosticsStore
    @ObservedObject var selfRefresh: SelfRefreshCoordinator
    @ObservedObject var model: RouteLocationModel
    let openSideStoreApp: () -> Void

    var body: some View {
        Section("簽名狀態與重新整理") {
            HStack {
                Text("簽名狀態")
                Spacer()
                let status = signingService.currentStatus
                Text(status.label)
                    .foregroundStyle(status.color)
            }
            HStack {
                Text("剩餘有效時間")
                Spacer()
                Text(signingService.remainingTimeFormatted)
                    .foregroundStyle(.secondary)
            }
            if signingService.expirationFormatted != "無" {
                HStack {
                    Text("到期時間")
                    Spacer()
                    Text(signingService.expirationFormatted)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let team = signingService.profileInfo?.teamIdentifier.first {
                HStack {
                    Text("開發者團隊 ID")
                    Spacer()
                    Text(team)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("容器識別雜湊")
                Spacer()
                Text(diagnosticsStore.installationIdentity.containerIdentityHash)
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(.blue)
            }

            if selfRefresh.state.isBusy {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                    Text(selfRefresh.state.statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let err = selfRefresh.lastErrorMessage {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                selfRefresh.startSelfRefresh(model: model)
            } label: {
                Label("重新整理 RouteLocation", systemImage: "arrow.clockwise")
            }
            .disabled(selfRefresh.state.isBusy)

            Button {
                openSideStoreApp()
            } label: {
                Label("在 SideStore 中重新整理", systemImage: "arrow.up.forward.app")
            }

            Text("手動重新整理僅續期目前安裝的 RouteLocation 簽名，不跨版本升級，也不會重新整理其他 App。建議在 Wi-Fi 並啟動 LocalDevVPN 的環境下執行。")
                .font(.footnote).foregroundStyle(.secondary)
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
