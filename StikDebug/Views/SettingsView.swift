import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var playback: RoutePlaybackEngine
    
    @AppStorage("RouteLocation.showMiniPlayer") private var showMiniPlayer = true
    @AppStorage(AppLanguage.defaultsKey) private var appLanguage = AppLanguage.traditionalChinese.rawValue
    
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mounting = MountingProgress.shared
    @ObservedObject private var dataPath = LocationDataPathHealth.shared
    @ObservedObject private var healthSteps = HealthStepSyncService.shared
    @ObservedObject private var diagnosticsStore = DeveloperDiagnosticsStore.shared
    @ObservedObject private var signingService = SigningStatusService.shared
    @ObservedObject private var selfRefresh = SelfRefreshCoordinator.shared
    
    @State private var versionTapCount = 0

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.text("一般")) {
                    HStack {
                        Text(L10n.text("預設速度 (km/h)"))
                        Spacer()
                        TextField("18.6", value: $model.speedKmh, format: .number.precision(.fractionLength(1)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    
                    Picker(L10n.text("切換定位模式時"), selection: $model.modeSwitchConfirmation) {
                        ForEach(ModeSwitchConfirmation.allCases) { conf in
                            Text(conf.title).tag(conf)
                        }
                    }
                    
                    Toggle(L10n.text("顯示執行中的迷你控制器"), isOn: $showMiniPlayer)
                }
                
                Section(L10n.text("定位設定")) {
                    HStack {
                        Text(L10n.text("定位通道"))
                        Spacer()
                        Circle()
                            .fill(effectiveTunnelHealthy ? .green : .orange)
                            .frame(width: 8, height: 8)
                        Text(effectiveTunnelHealthy ? L10n.text("已就緒") : L10n.text("需要處理"))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text(L10n.text("開發者磁碟映像 (DDI)"))
                        Spacer()
                        Circle()
                            .fill(mounting.coolisMounted ? .green : .orange)
                            .frame(width: 8, height: 8)
                        Text(mounting.coolisMounted ? L10n.text("已掛載") : (mounting.mountingThread != nil ? L10n.text("準備中") : L10n.text("未掛載")))
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Text(L10n.text("模擬狀態"))
                        Spacer()
                        Text(model.simulationMode.label)
                            .foregroundStyle(.secondary)
                    }
                    
                    NavigationLink(L10n.text("配對檔案")) {
                        Form {
                            PairingSettingsSection()
                        }
                        .navigationTitle(L10n.text("配對檔案"))
                    }
                    
                    Button(L10n.text("檢查／重試裝置通道")) {
                        if model.isCellularBootstrapPreparationNeeded {
                            model.requestBootstrapIfCellular {
                                tunnel.checkHealthNow(transport: model.connectionMonitor.currentTransport)
                            }
                        } else {
                            tunnel.checkHealthNow(transport: model.connectionMonitor.currentTransport)
                        }
                    }
                    .accessibilityLabel(L10n.text("檢查或重試裝置通道"))
                    
                    Button(L10n.text("檢查／掛載 DDI")) {
                        MountingProgress.shared.pubMount()
                    }
                    .accessibilityLabel(L10n.text("檢查或掛載 DDI"))
                }
                
                Section(L10n.text("健康同步")) {
                    Toggle(L10n.text("路線播放時同步步數"), isOn: $healthSteps.isEnabled)
                        .onChange(of: healthSteps.isEnabled) { _, enabled in
                            if enabled {
                                Task { await healthSteps.requestAuthorization() }
                            }
                        }
                    
                    if healthSteps.isEnabled {
                        Picker(L10n.text("計算方式"), selection: $healthSteps.calculationMode) {
                            ForEach(StepCalculationMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        
                        if healthSteps.calculationMode == .fixedCadence {
                            HStack {
                                Text(L10n.text("步頻"))
                                Spacer()
                                TextField("160", value: $healthSteps.cadenceStepsPerMinute, format: .number.precision(.fractionLength(0)))
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                                Text(L10n.text("步／分鐘"))
                            }
                        } else {
                            HStack {
                                Text(L10n.text("步長"))
                                Spacer()
                                TextField("0.80", value: $healthSteps.strideLengthMeters, format: .number.precision(.fractionLength(2)))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                                Text(L10n.text("公尺／步"))
                            }
                        }
                    }
                }
                
                Section(L10n.text("介面")) {
                    Picker(L10n.text("介面語言"), selection: $appLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    }
                }
                
                Section(L10n.text("進階")) {
                    Picker(L10n.text("地圖操作模式"), selection: $model.mapInteractionStyle) {
                        ForEach(MapInteractionStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    
                    if diagnosticsStore.isDeveloperModeUnlocked {
                        NavigationLink(L10n.text("開發者診斷工具")) {
                            DeveloperDiagnosticsView()
                        }
                        NavigationLink(L10n.text("行動網路 Bootstrap 實驗室")) {
                            CellularBootstrapLabView()
                        }
                    }
                    
                    Button(L10n.text("複製安全診斷報告")) {
                        copySanitizedDiagnosticReport()
                    }
                    
                    NavigationLink(L10n.text("背景播放")) {
                        Form {
                            Section(L10n.text("背景播放限制")) {
                                Text(L10n.text("背景執行受 iOS 系統限制。強制結束 RouteLocation、重新啟動裝置、iOS 終止程序或系統層級錯誤都會停止播放。"))
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .navigationTitle(L10n.text("背景播放"))
                    }
                    
                    NavigationLink(L10n.text("完整設定與診斷")) {
                        SetupDiagnosticsView()
                    }
                }
                
                Section(L10n.text("簽名與更新")) {
                    NavigationLink(L10n.text("SideStore 設定")) {
                        Form {
                            SigningAndRefreshSectionViewProxy(
                                signingService: signingService,
                                diagnosticsStore: diagnosticsStore,
                                selfRefresh: selfRefresh,
                                model: model
                            )
                        }
                        .navigationTitle(L10n.text("簽名狀態與重新整理"))
                    }
                }
                
                Section(L10n.text("關於 RouteLocation")) {
                    HStack {
                        Text(L10n.text("版本"))
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
                            .accessibilityLabel(L10n.text("版本資訊"))
                    }
                    
                    Text(L10n.text("沒有帳號、分析、遙測、後端、CloudKit 或路線上傳。只有在你要求 MapKit 圖磚、搜尋及導航計算時才會連接 Apple 服務。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.text("設定"))
        }
    }
    
    private var effectiveTunnelHealthy: Bool {
        tunnel.isConnected || model.connectionMonitor.deviceSession == .connected || dataPath.hasRecentSuccess
    }

    private func copySanitizedDiagnosticReport() {
        let pairingLabel = FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path) ? "present" : "missing"
        let ddiStatus = mounting.coolisMounted ? "mounted" : (mounting.mountingThread != nil ? "mounting" : "unmounted")
        let simulationStatus: String
        if playback.state == .running || playback.state == .reconnecting {
            simulationStatus = playback.state.label
        } else if model.connectionMonitor.deviceSession == .connected {
            simulationStatus = "single point"
        } else {
            simulationStatus = "idle"
        }
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
        ToastManager.shared.show(L10n.text("已複製安全診斷報告。"), kind: .success)
    }
}

private struct PairingSettingsSection: View {
    @State private var showPairingImporter = false
    @State private var showDeletePairingConfirm = false
    @State private var pairingState: String = L10n.text("檢查中")

    private var pairingPresent: Bool { FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path) }

    var body: some View {
        Section(L10n.text("配對檔案")) {
            HStack {
                Text(L10n.text("狀態"))
                Spacer()
                Text(pairingState)
                    .foregroundStyle(pairingPresent ? .green : .orange)
            }

            Button(L10n.text(pairingPresent ? "更換配對檔案" : "匯入配對檔案")) {
                showPairingImporter = true
            }

            if pairingPresent {
                Button(L10n.text("移除配對檔案"), role: .destructive) {
                    showDeletePairingConfirm = true
                }
            }

            Text(L10n.text("配對檔案是敏感的裝置信任憑證。請妥善保管；RouteLocation 只會儲存在本機，絕不會上傳內容。"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $showPairingImporter, allowedContentTypes: PairingFileStore.supportedContentTypes) { result in
            do {
                let url = try result.get()
                try PairingFileStore.importFromPicker(url)
                ToastManager.shared.show(L10n.text("匯入成功。"), kind: .success)
                pairingState = L10n.text("已存在")
            } catch {
                ToastManager.shared.show(L10n.format("匯入失敗：%@", error.localizedDescription), kind: .error)
            }
        }
        .alert(L10n.text("確定要移除配對檔案？"), isPresented: $showDeletePairingConfirm) {
            Button(L10n.text("移除"), role: .destructive) {
                try? PairingFileStore.remove()
                pairingState = L10n.text("缺少")
                ToastManager.shared.show(L10n.text("已移除配對檔案"), kind: .info)
            }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("移除後將無法建立新的 DVT 裝置通道，直到重新匯入有效的配對檔案。"))
        }
        .onAppear {
            pairingState = pairingPresent ? L10n.text("已存在") : L10n.text("缺少")
        }
    }
}

private struct SigningAndRefreshSectionViewProxy: View {
    @ObservedObject var signingService: SigningStatusService
    @ObservedObject var diagnosticsStore: DeveloperDiagnosticsStore
    @ObservedObject var selfRefresh: SelfRefreshCoordinator
    @ObservedObject var model: RouteLocationModel

    var body: some View {
        Section(L10n.text("簽名狀態與重新整理")) {
            HStack {
                Text(L10n.text("簽名狀態"))
                Spacer()
                Text(signingService.currentStatus.label)
                    .foregroundStyle(signingService.currentStatus.color)
            }
            
            Button {
                selfRefresh.startSelfRefresh(model: model)
            } label: {
                Label(L10n.text("重新整理 RouteLocation"), systemImage: "arrow.clockwise")
            }
            .disabled(selfRefresh.state.isBusy)
            
            Button {
                if let url = URL(string: "sidestore://"), UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url)
                } else if let url = SideStoreSourceConfig.sideStoreDeepLinkURL {
                    UIApplication.shared.open(url)
                } else {
                    ToastManager.shared.show(L10n.text("未偵測到 SideStore App。"), kind: .info)
                }
            } label: {
                Label(L10n.text("在 SideStore 中開啟"), systemImage: "arrow.up.forward.app")
            }
        }
    }
}
