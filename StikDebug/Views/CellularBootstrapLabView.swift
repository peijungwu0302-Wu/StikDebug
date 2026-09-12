import SwiftUI

struct CellularBootstrapLabView: View {
    @ObservedObject private var monitor = ConnectionMonitor.shared
    @ObservedObject private var coordinator = LocationSessionCoordinator.shared
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var shortcutService = ShortcutBootstrapService.shared
    @AppStorage("RouteLocation.cellularTestDelayMs") private var testDelayMs: Double = 500
    @State private var isTesting = false
    @State private var testResultText: String? = nil

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

            let success = tunnel.bootstrapAvailable || tunnel.isConnected || monitor.activeDVTSessionAvailable
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
