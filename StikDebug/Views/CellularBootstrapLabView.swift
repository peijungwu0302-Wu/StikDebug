import SwiftUI
import UIKit

struct CellularBootstrapLabView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @ObservedObject private var monitor = ConnectionMonitor.shared
    @ObservedObject private var coordinator = LocationSessionCoordinator.shared
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var shortcutService = ShortcutBootstrapService.shared
    @ObservedObject private var probeService = CellularBootstrapTransportProbe.shared

    @AppStorage("RouteLocation.cellularTestDelayMs") private var testDelayMs: Double = 500
    @State private var isTesting = false
    @State private var testResultText: String? = nil
    @State private var currentReport: DiagnosisReport? = nil
    @State private var showCopiedAlert = false

    private var hasHealthySession: Bool {
        monitor.activeDVTSessionAvailable || LocationDataPathHealth.shared.hasRecentSuccess
    }

    var body: some View {
        List {
            Section("即時網路傳輸狀態 (Live Transport)") {
                HStack {
                    Text("主要傳輸")
                    Spacer()
                    Text(monitor.currentTransport.label)
                        .foregroundStyle(monitor.currentTransport == .cellular ? .blue : (monitor.currentTransport == .wifi ? .green : .secondary))
                }
                HStack {
                    Text("先前傳輸")
                    Spacer()
                    Text(monitor.previousTransport.label)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("網際網路連線 (Satisfied)")
                    Spacer()
                    Text(monitor.internetReachable ? "正常 (True)" : "離線 (False)")
                        .foregroundStyle(monitor.internetReachable ? .green : .orange)
                }
                HStack {
                    Text("計費路徑 (isExpensive)")
                    Spacer()
                    Text(monitor.pathIsExpensive ? "是 (Expensive)" : "否")
                        .foregroundStyle(monitor.pathIsExpensive ? .orange : .secondary)
                }
                HStack {
                    Text("VPN 介面偵測")
                    Spacer()
                    Text(monitor.usesVPNInterface ? "已偵測 (utun)" : "未偵測")
                        .foregroundStyle(monitor.usesVPNInterface ? .green : .secondary)
                }
                HStack {
                    Text("新 Bootstrap 可用性")
                    Spacer()
                    Text(tunnel.bootstrapAvailable ? "可用" : "不可用")
                        .foregroundStyle(tunnel.bootstrapAvailable ? .green : .orange)
                }
            }

            Section("動態 VPN Peer 觀察 (Dynamic VPN Peer Observation)") {
                Text("此區域僅即時觀察系統底層回報之通道介面狀態，絕不修改或注入任何 NetworkExtension、PacketTunnelProvider 或外部設定。")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Text("LocalDevVPN 狀態")
                    Spacer()
                    Text(monitor.localDevVPNAvailable ? "連線中" : "未連線")
                        .foregroundStyle(monitor.localDevVPNAvailable ? .green : .orange)
                }
                HStack {
                    Text("DVT Session 狀態")
                    Spacer()
                    Text(monitor.deviceSession.label)
                        .foregroundStyle(monitor.deviceSession == .connected ? .green : .secondary)
                }
                HStack {
                    Text("定位數據路徑")
                    Spacer()
                    Text(LocationDataPathHealth.shared.status.label)
                        .foregroundStyle(LocationDataPathHealth.shared.status == .healthy ? .green : .orange)
                }
            }

            // ==========================================
            // SPIKE: Bootstrap Network Path
            // ==========================================
            Section("通道引導網路路徑實驗 (Bootstrap Network Path)") {
                Text("本實驗僅發起受控的診斷 TCP 探測（Diagnostic TCP Probe），絕不修改生產環境定位架構，亦不中斷現有健康工作階段。")
                    .font(.footnote).foregroundStyle(.secondary)

                if hasHealthySession {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                        Text("目前已有健康定位工作階段。為避免破壞正在使用的 DVT，新的 Bootstrap 實驗已停用。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    .padding(.vertical, 2)
                }

                // Environment Snapshot
                Group {
                    HStack {
                        Text("傳輸狀態 (Transport)")
                        Spacer()
                        Text(monitor.currentTransport.label)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("行動網路 (Cellular)")
                        Spacer()
                        Text(cellularAvailabilityText)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("VPN 介面")
                        Spacer()
                        Text(vpnInterfaceText)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("VPN Candidate 信心")
                        Spacer()
                        Text(vpnConfidenceText)
                            .foregroundStyle(vpnConfidenceColor)
                    }
                    HStack {
                        Text("設定目標 (Target)")
                        Spacer()
                        Text("\(DeviceConnectionContext.targetIPAddress):49152")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("推導 Candidate Peer")
                        Spacer()
                        Text(candidatePeerText)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("實際 Bootstrap 擁有者")
                        Spacer()
                        Text("PREBUILT_FFI (libidevice_ffi.a)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("FFI 介面綁定能力")
                        Spacer()
                        Text("不可用 (需擴充 FFI)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                // Action Button
                Button {
                    runPathProbes()
                } label: {
                    HStack {
                        Text(probeService.isProbing ? "路徑探測中..." : "執行路徑診斷探測 (Run Path Probes)")
                        if probeService.isProbing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(probeService.isProbing)

                // Probe A
                VStack(alignment: .leading, spacing: 4) {
                    Text("PROBE A — Baseline (目前預設路徑)")
                        .font(.caption.bold())
                    probeResultView(result: probeService.probeAResult)
                }
                .padding(.vertical, 2)

                // Probe B
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("PROBE B — Cellular-Prohibited TCP")
                            .font(.caption.bold())
                        Spacer()
                        Text("僅診斷探測")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                    }
                    Text("測試 prohibitedInterfaceTypes = [.cellular]")
                        .font(.caption2).foregroundStyle(.secondary)
                    probeResultView(result: probeService.probeBResult)
                }
                .padding(.vertical, 2)

                // Probe C
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("PROBE C — Required VPN Interface")
                            .font(.caption.bold())
                        Spacer()
                        Text("僅診斷探測")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                    }
                    Text("強制指定 NWParameters.requiredInterface = candidate")
                        .font(.caption2).foregroundStyle(.secondary)
                    probeResultView(result: probeService.probeCResult)
                }
                .padding(.vertical, 2)

                // Diagnosis Report
                if let report = currentReport {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("自動診斷結論 (Verdict)")
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
                        Text(report.verdict.localizedTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        Text("分析判讀：").font(.caption2.bold())
                        Text(report.interpretation)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("建議下一步：").font(.caption2.bold())
                        Text(report.recommendedNextStep)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            copyReportToClipboard(report.formattedText)
                        } label: {
                            HStack {
                                Image(systemName: "doc.on.doc")
                                Text("複製完整診斷 (One-Tap Copy)")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("直連行動網路延遲實驗 (Direct Cellular Delay Lab)") {
                Text("調整在行動網路下直接發起通道交握前的等待緩衝時間（0ms～5000ms），以驗證蜂巢網路數據流穩定性。")
                    .font(.footnote).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("連線延遲緩衝")
                        Spacer()
                        Text("\(Int(testDelayMs)) ms")
                            .font(.subheadline.monospaced().bold())
                    }
                    Slider(value: $testDelayMs, in: 0...5000, step: 100)
                }

                Button {
                    runDirectCellularTest()
                } label: {
                    HStack {
                        Text(isTesting ? "測試探測中..." : "執行直連測試 (Run Direct Probe)")
                        if isTesting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isTesting)

                if let result = testResultText {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("測試結果：").font(.caption.bold())
                        Text(result)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }

            Section("傳輸切換歷史 (Recent Transport Handoffs)") {
                if coordinator.transportHistory.isEmpty {
                    Text("目前尚無傳輸切換記錄。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(coordinator.transportHistory) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(entry.previousTransport) ➔ \(entry.transport)")
                                    .font(.subheadline.bold())
                                Spacer()
                                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            if let action = entry.action {
                                Text("動作: \(action)")
                                    .font(.caption2)
                                    .foregroundStyle(action == "SKIP_RECOVERY" ? .green : .blue)
                            }
                            if let reason = entry.reason {
                                Text("原因: \(reason)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(L10n.text("行動網路實驗室"))
        .onAppear {
            let snap = probeService.captureSnapshot()
            currentReport = CellularBootstrapDiagnosisEngine.evaluate(
                snapshot: snap,
                probeA: probeService.probeAResult,
                probeB: probeService.probeBResult,
                probeC: probeService.probeCResult,
                simulationModeLabel: model.simulationMode.label
            )
        }
        .alert(L10n.text("診斷報告已複製"), isPresented: $showCopiedAlert) {
            Button(L10n.text("確定"), role: .cancel) {}
        } message: {
            Text(L10n.text("完整診斷報告已複製至剪貼簿，可直接貼上回報。"))
        }
    }

    // MARK: - Subviews & Helpers

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
                if let ifName = result.selectedInterfaceName {
                    Text("使用介面：\(ifName)\(result.selectedInterfaceIndex.map { " (idx: \($0))" } ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let local = result.localEndpoint {
                    Text("本機端點：\(local)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let remote = result.remoteEndpoint {
                    Text("遠端端點：\(remote)")
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
            Text("尚未執行")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var cellularAvailabilityText: String {
        if monitor.currentTransport == .cellular {
            return "主要路徑 (Primary)"
        }
        if probeService.latestSnapshot?.isCellularAvailable == true {
            return "已偵測 (非主要路徑)"
        }
        return "未偵測 / 未開啟"
    }

    private var vpnInterfaceText: String {
        if let iface = probeService.latestSnapshot?.vpnCandidate.interface {
            return "\(iface.name) (idx: \(iface.index))"
        }
        return "無"
    }

    private var vpnConfidenceText: String {
        probeService.latestSnapshot?.vpnCandidate.confidence.rawValue ?? "None"
    }

    private var vpnConfidenceColor: Color {
        switch probeService.latestSnapshot?.vpnCandidate.confidence {
        case .confident: return .green
        case .ambiguous: return .orange
        case .none, .none?: return .secondary
        }
    }

    private var candidatePeerText: String {
        probeService.latestSnapshot?.detectedCandidatePeer ?? "unavailable"
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
            if let snapshot = probeService.latestSnapshot {
                let report = CellularBootstrapDiagnosisEngine.evaluate(
                    snapshot: snapshot,
                    probeA: probeService.probeAResult,
                    probeB: probeService.probeBResult,
                    probeC: probeService.probeCResult,
                    simulationModeLabel: model.simulationMode.label
                )
                await MainActor.run {
                    self.currentReport = report
                }
            }
        }
    }

    private func copyReportToClipboard(_ text: String) {
        UIPasteboard.general.string = text
        showCopiedAlert = true
    }

    private func runDirectCellularTest() {
        guard !isTesting else { return }
        isTesting = true
        testResultText = nil

        Task {
            let delaySeconds = testDelayMs / 1000.0
            DeveloperDiagnosticsStore.shared.record(
                category: .transport,
                action: "CELLULAR_LAB_PROBE_START",
                details: ["delayMs": String(Int(testDelayMs)), "currentTransport": monitor.currentTransport.rawValue]
            )

            if delaySeconds > 0 {
                try? await Task.sleep(for: .seconds(delaySeconds))
            }

            let startTime = Date()
            tunnel.checkHealthNow(transport: monitor.currentTransport)
            try? await Task.sleep(for: .seconds(1))
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

            let resultSummary = "耗時: \(durationMs)ms, Bootstrap: \(tunnel.bootstrapAvailable ? "OK" : "拒絕/失敗"), Tunnel: \(tunnel.isConnected ? "連線" : "未連線")"

            await MainActor.run {
                self.isTesting = false
                self.testResultText = resultSummary
                DeveloperDiagnosticsStore.shared.record(
                    category: .transport,
                    action: "CELLULAR_LAB_PROBE_RESULT",
                    details: [
                        "delayMs": String(Int(self.testDelayMs)),
                        "durationMs": String(durationMs),
                        "bootstrap": String(self.tunnel.bootstrapAvailable),
                        "connected": String(self.tunnel.isConnected)
                    ]
                )
            }
        }
    }
}
