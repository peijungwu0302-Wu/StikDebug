import SwiftUI
import UIKit

struct CellularBootstrapLabView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @ObservedObject private var monitor = ConnectionMonitor.shared
    @ObservedObject private var coordinator = LocationSessionCoordinator.shared
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var shortcutService = ShortcutBootstrapService.shared
    @ObservedObject private var probeService = CellularBootstrapTransportProbe.shared
    @ObservedObject private var traceStore = BootstrapTraceStore.shared
    @ObservedObject private var stateMachine = CellularAssistedBootstrapStateMachine.shared
    @ObservedObject private var researchService = DirectCellularResearchService.shared
    @ObservedObject private var bonjourDiscovery = BonjourRemotePairingDiscovery.shared

    @State private var isTestingAssisted = false
    @State private var currentReport: DiagnosisReport? = nil
    @State private var showCopiedAlert = false
    @State private var copiedMessage = ""
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var utunReport: UtunTopologyReport? = nil

    private var hasHealthySession: Bool {
        monitor.activeDVTSessionAvailable || LocationDataPathHealth.shared.hasRecentSuccess
    }

    private var currentStateClassification: BootstrapStateClassification {
        DirectCellularResearchService.classifyCurrentState()
    }

    var body: some View {
        List {
            // ==========================================
            // 1. 目前 Session Health
            // ==========================================
            Section(L10n.text("1. 目前 Session Health (即時狀態)")) {
                HStack {
                    Text(L10n.text("研究狀態快照"))
                    Spacer()
                    Text(currentStateClassification.title)
                        .font(.caption.bold())
                        .foregroundStyle(currentStateClassification == .stateC ? .green : (currentStateClassification == .stateA ? .blue : .secondary))
                }
                HStack {
                    Text(L10n.text("DVT 工作階段"))
                    Spacer()
                    Text(monitor.deviceSession.label)
                        .foregroundStyle(monitor.deviceSession == .connected ? .green : .secondary)
                }
                HStack {
                    Text(L10n.text("定位數據路徑"))
                    Spacer()
                    Text(LocationDataPathHealth.shared.status.label)
                        .foregroundStyle(LocationDataPathHealth.shared.status == .healthy ? .green : .orange)
                }
                if LocationDataPathHealth.shared.consecutiveLocationFailures > 0 {
                    HStack {
                        Text(L10n.text("連續失敗次數"))
                        Spacer()
                        Text("\(LocationDataPathHealth.shared.consecutiveLocationFailures)")
                            .foregroundStyle(.red)
                    }
                }
                HStack {
                    Text(L10n.text("最近成功定位寫入"))
                    Spacer()
                    if let lastSuccess = LocationDataPathHealth.shared.lastSuccessfulLocationUpdate {
                        Text(lastSuccess, format: .dateTime.hour().minute().second())
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.text("無"))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(L10n.text("裝置通道 (Tunnel)"))
                    Spacer()
                    Text(tunnel.isConnected ? L10n.text("連線中") : L10n.text("未連線"))
                        .foregroundStyle(tunnel.isConnected ? .green : .secondary)
                }
                HStack {
                    Text(L10n.text("LocalDevVPN 介面"))
                    Spacer()
                    Text(monitor.usesVPNInterface ? L10n.text("已偵測 (utun)") : L10n.text("未偵測"))
                        .foregroundStyle(monitor.usesVPNInterface ? .green : .secondary)
                }
                HStack {
                    Text(L10n.text("主要傳輸"))
                    Spacer()
                    Text(monitor.currentTransport.label)
                        .foregroundStyle(monitor.currentTransport == .cellular ? .blue : (monitor.currentTransport == .wifi ? .green : .secondary))
                }
                HStack {
                    Text(L10n.text("Wi-Fi 介面可用"))
                    Spacer()
                    Text(monitor.isWifiAvailable ? L10n.text("是") : L10n.text("否"))
                        .foregroundStyle(monitor.isWifiAvailable ? .green : .secondary)
                }
                HStack {
                    Text(L10n.text("行動網路介面可用"))
                    Spacer()
                    Text(monitor.isCellularAvailable ? L10n.text("是") : L10n.text("否"))
                        .foregroundStyle(monitor.isCellularAvailable ? .blue : .secondary)
                }
            }

            // ==========================================
            // 2. Assisted Bootstrap Beta
            // ==========================================
            Section(L10n.text("2. 行動網路輔助啟動 (Assisted Beta)")) {
                Toggle(L10n.text("啟用捷徑輔助啟動 (Beta)"), isOn: $shortcutService.isShortcutAssistedEnabled)

                if shortcutService.isShortcutAssistedEnabled {
                    Picker(L10n.text("啟動策略"), selection: $shortcutService.cellularBootstrapPolicy) {
                        ForEach(CellularBootstrapPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }

                    HStack {
                        Text(L10n.text("狀態機當前階段"))
                        Spacer()
                        Text(stateMachine.state.label)
                            .font(.subheadline.bold())
                            .foregroundStyle(stateMachine.state.isRunning ? .indigo : .secondary)
                    }

                    if let txId = stateMachine.activeTxId {
                        HStack {
                            Text(L10n.text("目前交易 ID"))
                            Spacer()
                            Text(txId)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }

                    if stateMachine.requiresManualDataOnAlert {
                        Text(L10n.text("⚠️ 無法自動恢復行動數據，請至控制中心手動重新開啟。"))
                            .font(.footnote.bold())
                            .foregroundStyle(.red)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            shortcutService.runSafeRoundTripTest { success, message in
                                ToastManager.shared.show(message, kind: success ? .success : .error)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                Text(L10n.text("安全雙向測試 (Off ➔ On)"))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)

                        Button(L10n.text("測試 Data On 恢復 (Recovery)")) {
                            shortcutService.testDataOnShortcut()
                        }
                        .buttonStyle(.bordered)

                        if let coord = model.selectedCoordinate ?? model.pendingSinglePointCoordinate {
                            Text("驗證目標座標：\(String(format: "%.4f, %.4f", coord.latitude, coord.longitude))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("（未指定地圖座標，啟動時將僅驗證通道建立，不寫入偽造位置）")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        runAssistedBootstrapTest()
                    } label: {
                        HStack {
                            Text(stateMachine.state.isRunning ? L10n.text("輔助啟動進行中...") : L10n.text("執行完整輔助啟動測試"))
                            if stateMachine.state.isRunning {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(stateMachine.state.isRunning)

                    DisclosureGroup(L10n.text("進階設定 (Advanced)")) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(L10n.text("額外穩定等待"))
                                Spacer()
                                Text(String(format: "%.1f 秒", shortcutService.cellularBootstrapStabilizationDelay))
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.secondary)
                            }

                            Picker(L10n.text("額外穩定等待時間"), selection: $shortcutService.cellularBootstrapStabilizationDelay) {
                                ForEach([0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0], id: \.self) { delay in
                                    Text(String(format: "%.1f 秒", delay)).tag(delay)
                                }
                            }
                            .pickerStyle(.segmented)

                            Text(L10n.text("收到 DataOff 回呼成功後，額外等待短暫時間再建立通道。預設 0.0 秒（即刻啟動，不額外等待）。若特定機型需要電信網路完全沉降，可微調此設定。"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Button(L10n.text("恢復預設值")) {
                                shortcutService.resetStabilizationDelayToDefault()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }

                    DisclosureGroup(L10n.text("查看二階段捷徑設定教學")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(ShortcutBootstrapService.shortcutSetupGuide)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)

                            Button(L10n.text("複製教學步驟")) {
                                UIPasteboard.general.string = ShortcutBootstrapService.shortcutSetupGuide
                                showCopyFeedback(L10n.text("已複製教學步驟至剪貼簿"))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            // ==========================================
            // 3. Direct Cellular Bootstrap — Research Beta
            // ==========================================
            Section(L10n.text("3. 直接連線研究測試 (Research Beta)")) {
                Toggle(L10n.text("啟用直接連線研究模式 (Beta)"), isOn: $researchService.isBetaEnabled)

                Text(L10n.text("此模式僅供研究探測。若開啟，在行動網路環境下發起定位時會先嘗試直連一次，失敗自動切換為 One-Tap 輔助啟動，絕不損壞健康連線與目標座標。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Text(L10n.text("當前狀態分類"))
                    Spacer()
                    Text(currentStateClassification.title)
                        .font(.caption.bold())
                        .foregroundStyle(currentStateClassification == .stateC ? .green : (currentStateClassification == .stateA ? .blue : .secondary))
                }

                Button {
                    runResearchDirectAttempt()
                } label: {
                    HStack {
                        Text(researchService.isAttemptInProgress ? L10n.text("直連研究測試中...") : L10n.text("執行單次直連研究測試"))
                        if researchService.isAttemptInProgress {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(researchService.isAttemptInProgress || stateMachine.state.isRunning)

                if let lastRes = researchService.lastResult {
                    researchResultView(result: lastRes)
                }
            }

            // ==========================================
            // 4. 端點研究矩陣 (Endpoint Research Matrix — PROBE ONLY)
            // ==========================================
            Section(L10n.text("4. 端點研究矩陣 (Endpoint Research Matrix)")) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                        Text(L10n.text("僅供診斷研究 (PROBE ONLY)。探測端點為分析 iOS NWPath 與 utun 封包路由行為，不干擾生產定位與 DVT 工作階段。"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    runEndpointMatrix()
                } label: {
                    HStack {
                        Text(probeService.isProbingMatrix ? L10n.text("矩陣探測中...") : L10n.text("執行端點研究矩陣探測 (Run Matrix Probes)"))
                        if probeService.isProbingMatrix {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(probeService.isProbingMatrix || probeService.isProbing)

                if !probeService.matrixResults.isEmpty {
                    ForEach(probeService.matrixResults) { item in
                        matrixResultRow(result: item)
                    }
                } else {
                    Text(L10n.text("尚未執行矩陣探測。點擊上方按鈕測試 10.7.0.1、127.0.0.1、::1。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // ==========================================
            // 5. 生產底層真理 (Production FFI Truth & Route Analysis)
            // ==========================================
            Section(L10n.text("5. 生產底層真理 (Production FFI Truth)")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.text("生產連線目標 (Target)"))
                        Spacer()
                        Text("10.7.0.1:49152")
                            .font(.caption.monospaced().bold())
                    }
                    HStack {
                        Text(L10n.text("來源 IP 綁定 (Source IP Bind)"))
                        Spacer()
                        Text("NO (由 OS 核心路由決定)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(L10n.text("介面綁定 (Interface Bind)"))
                        Spacer()
                        Text("NO (底層 C 庫無 SO_BINDTODEVICE)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(L10n.text("路由表操控 (Routing Sockets)"))
                        Spacer()
                        Text("UNAVAILABLE (iOS Sandbox 禁止)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    Text(L10n.text("行為事實說明：\n• 當行動網路開啟時，iOS 預設路由表將 10.7.0.1 封包導向 pdp_ip0 (蜂巢網路)，因而收到 POSIX 65 (No route to host)。\n• 當行動網路關閉時，LocalDevVPN 的 utun 介面接管或成為唯一直連路徑，連線瞬間成功。\n• 一旦建立 DVT Session，即便重新開啟行動數據，既有 TCP/TLS 保持活躍 (State C)，因此 One-Tap 輔助流程是當前最穩定可靠的解決方案。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            // ==========================================
            // 6. utun 網路拓撲快照 (Utun Topology Collector)
            // ==========================================
            Section(L10n.text("6. utun 網路拓撲快照 (Utun Topology)")) {
                HStack {
                    Text(L10n.text("拓撲摘要"))
                    Spacer()
                    if let report = utunReport {
                        Text(report.summary)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.text("未載入"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Button(L10n.text("重新收集 utun 拓撲快照")) {
                    refreshUtunTopology()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let report = utunReport, !report.interfaces.isEmpty {
                    ForEach(report.interfaces) { iface in
                        utunEntryRow(entry: iface)
                    }
                } else {
                    Text(L10n.text("未偵測到作用中之 utun 介面。請確認 LocalDevVPN 是否已啟用。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // ==========================================
            // 7. 生產引導追蹤 (Bootstrap Trace v3)
            // ==========================================
            Section(L10n.text("7. 生產引導追蹤 (Bootstrap Trace v3)")) {
                if let trace = traceStore.latestTrace {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L10n.text("最新執行結果"))
                                .font(.caption.bold())
                            Spacer()
                            Text(trace.outcome)
                                .font(.caption.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(trace.outcome == "SUCCESS" ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                                .cornerRadius(4)
                        }

                        if let state = trace.observedState {
                            Text("觀測狀態分類：\(state)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if let utunSummary = trace.utunTopologySummary {
                            Text("utun 拓撲：\(utunSummary)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if let totalMs = trace.overallDurationMs {
                            Text(L10n.format("總耗時：%.1f ms", totalMs))
                                .font(.caption.monospaced())
                        }
                        if let rppMs = trace.rpairingDurationMs {
                            Text(L10n.format("RPairing 耗時：%.1f ms", rppMs))
                                .font(.caption.monospaced())
                        }
                        if let errno = trace.rpairingErrno {
                            Text(L10n.format("RPairing Errno：%@", errno))
                                .font(.caption.monospaced())
                                .foregroundStyle(.red)
                        }
                        if let stage = trace.failureStage {
                            Text(L10n.format("失敗階段：%@", stage))
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        if let reason = trace.failureReason {
                            Text(L10n.format("原因：%@", reason))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        HStack {
                            Button(L10n.text("複製 Trace 摘要")) {
                                UIPasteboard.general.string = traceStore.formatTraceSummary(trace)
                                showCopyFeedback(L10n.text("已複製 Trace 摘要"))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Spacer()

                            Button(L10n.text("分享 TXT")) {
                                if let url = traceStore.exportSafeTXTURL(trace: trace) {
                                    shareItems = [url]
                                    showShareSheet = true
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button(L10n.text("分享 JSON")) {
                                if let url = traceStore.exportSafeJSONURL(trace: trace) {
                                    shareItems = [url]
                                    showShareSheet = true
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Text(L10n.text("目前尚無引導追蹤記錄。發起定位或測試後將自動記錄。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            // ==========================================
            // 8. RemotePairing / Peer 網路拓撲
            // ==========================================
            Section(L10n.text("8. RemotePairing / Peer 網路拓撲")) {
                HStack {
                    Text(L10n.text("設定目標 (Target)"))
                    Spacer()
                    Text("\(DeviceConnectionContext.targetIPAddress):49152")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(L10n.text("預期 Peer IP"))
                    Spacer()
                    Text("10.7.1.1 (P2P_DSTADDR)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(L10n.text("本機 VPN 介面"))
                    Spacer()
                    Text(monitor.usesVPNInterface ? "utun (LocalDevVPN)" : L10n.text("無"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.text("Bonjour 服務探索 (_remotepairing._tcp)"))
                            .font(.caption.bold())
                        Spacer()
                        Text(L10n.text("研究專用"))
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                    }
                    Text(L10n.text("探索本機或鄰近設備廣播之 RemotePairing 服務。RouteLocation 固定使用生產目標 10.7.0.1:49152，不自動替換。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button {
                        if bonjourDiscovery.isSearching {
                            bonjourDiscovery.stopDiscovery()
                        } else {
                            bonjourDiscovery.startDiscovery()
                        }
                    } label: {
                        HStack {
                            Text(bonjourDiscovery.isSearching ? L10n.text("停止 Bonjour 探索") : L10n.text("搜尋 _remotepairing._tcp"))
                            if bonjourDiscovery.isSearching {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text(bonjourDiscovery.lastStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if !bonjourDiscovery.discoveredServices.isEmpty {
                        ForEach(bonjourDiscovery.discoveredServices) { s in
                            Text(s.summaryText)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // ==========================================
            // 9. 多次執行比對 (Previous vs Latest)
            // ==========================================
            Section(L10n.text("9. 多次執行比對 (Previous vs Latest)")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(traceStore.generateComparisonText())
                        .font(.caption2.monospaced())
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(6)

                    if traceStore.previousTrace != nil {
                        Button(L10n.text("複製比對報告")) {
                            UIPasteboard.general.string = traceStore.generateComparisonText()
                            showCopyFeedback(L10n.text("已複製比對報告"))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }

            // ==========================================
            // 10. 診斷探測矩陣 (Candidate Matrix & Probes)
            // ==========================================
            Section(L10n.text("10. 診斷探測矩陣 (Candidate Matrix & Probes)")) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.orange)
                        Text(L10n.text("診斷探測僅供網路分析。探測失敗不代表 DVT 工作階段失效，絕不中斷目前健康的定位模擬。"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    runPathProbes()
                } label: {
                    HStack {
                        Text(probeService.isProbing ? L10n.text("路徑探測中...") : L10n.text("執行路徑診斷探測 (Run Path Probes)"))
                        if probeService.isProbing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(probeService.isProbing)

                // Probe A
                VStack(alignment: .leading, spacing: 4) {
                    Text("PROBE A — Baseline (目前預設路徑)").font(.caption.bold())
                    probeResultView(result: probeService.latestCompletedRun?.probeA)
                }

                // Probe B
                VStack(alignment: .leading, spacing: 4) {
                    Text("PROBE B — Cellular-Prohibited TCP (僅診斷)").font(.caption.bold())
                    probeResultView(result: probeService.latestCompletedRun?.probeB)
                }

                // Probe C
                VStack(alignment: .leading, spacing: 4) {
                    Text("PROBE C — Required VPN Interface (僅診斷)").font(.caption.bold())
                    probeResultView(result: probeService.latestCompletedRun?.probeC)
                }

                // Candidate Peer Probe
                if let peerResult = probeService.latestCompletedRun?.candidatePeerProbe {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PEER PROBE — Candidate Peer 驗證探測").font(.caption.bold())
                        probeResultView(result: peerResult)
                    }
                }

                // Diagnosis Report
                if let report = currentReport {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L10n.text("自動診斷結論 (Verdict)"))
                                .font(.caption.bold())
                            Spacer()
                            Text(report.confidence.rawValue)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(report.confidence == .high ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                                .cornerRadius(4)
                        }
                        Text(report.verdict.rawValue)
                            .font(.subheadline.bold())
                            .foregroundStyle(verdictColor(report.verdict))
                        Text(report.interpretation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(report.recommendedNextStep)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(L10n.text("複製完整診斷結論")) {
                            UIPasteboard.general.string = report.formattedText
                            showCopyFeedback(L10n.text("已複製診斷結論"))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(L10n.text("行動網路實驗室"))
        .onAppear {
            refreshUtunTopology()
        }
        .alert(L10n.text("提示"), isPresented: $showCopiedAlert) {
            Button(L10n.text("確定"), role: .cancel) {}
        } message: {
            Text(copiedMessage)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: shareItems)
        }
    }

    // MARK: - Subviews & Actions

    @ViewBuilder
    private func researchResultView(result: DirectCellularResearchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.text("直連研究最新結果"))
                    .font(.caption.bold())
                Spacer()
                Text(result.productionRPairingResult)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(result.productionRPairingResult == "SUCCESS" ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                    .cornerRadius(4)
            }
            Text("狀態：\(result.stateClassification.rawValue) | 目標：\(result.productionTarget)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Text("耗時：\(String(format: "%.1f ms", result.durationMs))")
                .font(.caption2.monospaced())
            if let ffi = result.ffiCode {
                Text("FFI Code: \(ffi)").font(.caption2.monospaced()).foregroundStyle(.red)
            }
            if let errno = result.posixErrno {
                Text("POSIX Errno: \(errno)").font(.caption2.monospaced()).foregroundStyle(.red)
            }
            if result.fallbackOccurred {
                Text("自動 Fallback 至輔助啟動：是")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(6)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func matrixResultRow(result: EndpointMatrixProbeResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(result.target)
                    .font(.caption.monospaced().bold())
                Spacer()
                Text(result.policy.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(result.status.rawValue)
                    .font(.caption2.bold())
                    .foregroundStyle(result.status == .success ? .green : (result.status == .failure ? .red : .secondary))
                Text("\(result.elapsedMs) ms")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let err = result.errorDescription {
                Text("錯誤：\(err)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(6)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func utunEntryRow(entry: UtunInterfaceEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.interfaceName)
                    .font(.caption.bold())
                Text("(\(entry.addressFamily))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if entry.isPointToPoint {
                    Text("P2P")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                }
                if entry.isUp {
                    Text("UP")
                        .font(.caption2.bold())
                        .foregroundStyle(.blue)
                }
            }
            if let ifAddr = entry.observedInterfaceAddress {
                Text("位址: \(ifAddr)")
                    .font(.caption2.monospaced())
            }
            if let p2pLocal = entry.observedP2PLocalAddress {
                Text("本機: \(p2pLocal)")
                    .font(.caption2.monospaced())
            }
            if let p2pDst = entry.observedP2PDestination {
                Text("對端 (DST): \(p2pDst)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.purple)
            }
            if let mask = entry.observedNetmask {
                Text("遮罩: \(mask)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func probeResultView(result: CellularPathProbeResult?) -> some View {
        if let result {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(result.status.rawValue)
                        .font(.caption.bold())
                        .foregroundStyle(result.status == .success ? .green : (result.status == .failure ? .red : .secondary))
                    Spacer()
                    Text("\(result.elapsedMs) ms")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let local = result.localEndpoint {
                    Text("本機：\(local)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let remote = result.remoteEndpoint {
                    Text("遠端：\(remote)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let err = result.errorDescription {
                    Text("錯誤：\(err)\(result.posixErrno.map { " (errno \($0))" } ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(6)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(6)
        } else {
            Text(L10n.text("尚未執行"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func verdictColor(_ verdict: DiagnosisVerdict) -> Color {
        switch verdict {
        case .EXISTING_SESSION_HEALTHY:
            return .green
        case .PATH_OR_INTERFACE_SELECTION_PROBLEM, .TARGET_OR_PEER_MISMATCH, .DIAGNOSTIC_PROBE_ONLY_SUCCESS:
            return .blue
        case .REMOTE_LISTENER_NOT_ACCEPTING, .FFI_TRANSPORT_NOT_CONTROLLABLE, .NO_LOCAL_VPN_PATH:
            return .orange
        case .VPN_INTERFACE_AMBIGUOUS, .NETWORK_OFFLINE, .INSUFFICIENT_EVIDENCE:
            return .secondary
        }
    }

    private func runPathProbes() {
        Task {
            await probeService.runAllProbes()
            if let run = probeService.latestCompletedRun {
                let report = CellularBootstrapDiagnosisEngine.evaluate(
                    run: run,
                    simulationModeLabel: model.simulationMode.label
                )
                await MainActor.run {
                    self.currentReport = report
                }
            }
        }
    }

    private func runAssistedBootstrapTest() {
        let target = model.selectedCoordinate ?? model.pendingSinglePointCoordinate
        stateMachine.startAssistedBootstrap(targetCoordinate: target) { result in
            switch result {
            case .success:
                ToastManager.shared.show(L10n.text("輔助啟動測試成功！"), kind: .success)
            case .failure(let error):
                ToastManager.shared.show(L10n.format("輔助啟動測試失敗：%@", error.localizedDescription), kind: .error)
            }
        }
    }

    private func runResearchDirectAttempt() {
        let target = model.selectedCoordinate ?? model.pendingSinglePointCoordinate
        researchService.performResearchDirectAttempt(targetCoordinate: target) { result in
            switch result {
            case .success:
                ToastManager.shared.show(L10n.text("直連研究測試成功建立！"), kind: .success)
            case .failure(let err):
                ToastManager.shared.show(L10n.format("直連研究測試失敗：%@", err.localizedDescription), kind: .error)
            }
        }
    }

    private func runEndpointMatrix() {
        Task {
            _ = await probeService.runEndpointMatrixProbes()
        }
    }

    private func refreshUtunTopology() {
        utunReport = UtunTopologyCollector.collectTopology()
    }

    private func showCopyFeedback(_ msg: String) {
        copiedMessage = msg
        showCopiedAlert = true
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
