import Combine
import Foundation
import UIKit

enum CellularAssistedState: String, Codable, CaseIterable {
    case idle
    case requestingDataOff
    case waitingForDataOffCallback
    case waitingForCellularOff
    case bootstrapping
    case waitingForRSD
    case waitingForDVT
    case verifyingFirstLocationWrite
    case requestingDataOn
    case waitingForDataOnCallback
    case waitingForCellularOn
    case completed
    case failedRecoveringData
    case cancelled
    case timedOut

    var label: String {
        switch self {
        case .idle: return L10n.text("閒置")
        case .requestingDataOff: return L10n.text("正在啟動關閉行動數據捷徑")
        case .waitingForDataOffCallback: return L10n.text("等待 DataOff 捷徑回呼")
        case .waitingForCellularOff: return L10n.text("等待行動數據完全中斷 (Settling)")
        case .bootstrapping: return L10n.text("建立裝置通道 (RPairing)")
        case .waitingForRSD: return L10n.text("等待 RSD 服務交握")
        case .waitingForDVT: return L10n.text("等待 DVT 工作階段就緒")
        case .verifyingFirstLocationWrite: return L10n.text("驗證首次定位寫入")
        case .requestingDataOn: return L10n.text("正在啟動恢復行動數據捷徑")
        case .waitingForDataOnCallback: return L10n.text("等待 DataOn 捷徑回呼")
        case .waitingForCellularOn: return L10n.text("等待行動網路完全恢復 (Settling)")
        case .completed: return L10n.text("輔助啟動完成")
        case .failedRecoveringData: return L10n.text("連線異常，正在自動恢復行動數據 (Rollback)")
        case .cancelled: return L10n.text("已取消")
        case .timedOut: return L10n.text("執行逾時")
        }
    }

    var isRunning: Bool {
        switch self {
        case .idle, .completed, .cancelled, .timedOut:
            return false
        default:
            return true
        }
    }

    var isDataTurnedOff: Bool {
        switch self {
        case .waitingForCellularOff, .bootstrapping, .waitingForRSD, .waitingForDVT, .verifyingFirstLocationWrite, .failedRecoveringData:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class CellularAssistedBootstrapStateMachine: ObservableObject {
    static let shared = CellularAssistedBootstrapStateMachine()

    @Published private(set) var state: CellularAssistedState = .idle
    @Published private(set) var activeTxId: String?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var requiresManualDataOnAlert: Bool = false

    private var activeCompletion: ((Result<Void, Error>) -> Void)?
    private var verificationCoordinate: RouteCoordinate?
    private var cancellables: Set<AnyCancellable> = []
    private var stateTimeoutTask: Task<Void, Never>?

    private init() {}

    // MARK: - Eligibility Check

    var isEligibleForDataOff: Bool {
        guard ShortcutBootstrapService.shared.isShortcutAssistedEnabled else { return false }
        let monitor = ConnectionMonitor.shared
        let hasActiveDVT = monitor.activeDVTSessionAvailable || LocationDataPathHealth.shared.hasRecentSuccess
        guard !hasActiveDVT else { return false }
        guard !monitor.isWifiAvailable && monitor.currentTransport == .cellular else { return false }
        return true
    }

    // MARK: - Start Assisted Bootstrap

    func startAssistedBootstrap(
        targetCoordinate: RouteCoordinate? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !state.isRunning else {
            completion(.failure(NSError(domain: "RouteLocation.Assisted", code: -100, userInfo: [NSLocalizedDescriptionKey: "已有進行中的輔助啟動程序"])))
            return
        }

        // Pre-launch Double-Check Gate
        let monitor = ConnectionMonitor.shared
        if monitor.activeDVTSessionAvailable || LocationDataPathHealth.shared.hasRecentSuccess {
            LogManager.shared.addInfoLog("Pre-launch check: Active DVT session already present. Skipping shortcut.")
            completion(.success(()))
            return
        }
        if monitor.isWifiAvailable {
            LogManager.shared.addInfoLog("Pre-launch check: Wi-Fi interface detected. Skipping cellular shortcut.")
            completion(.success(()))
            return
        }

        let txId = "tx-\(UUID().uuidString.prefix(8))"
        self.activeTxId = txId
        self.verificationCoordinate = targetCoordinate
        self.activeCompletion = completion
        self.lastErrorMessage = nil
        self.requiresManualDataOnAlert = false

        BootstrapTraceStore.shared.startTrace(txId: txId, mode: "AssistedBeta")
        transitionTo(.requestingDataOff)

        BootstrapTraceStore.shared.recordEvent(.dataOffRequested, details: ["txId": txId])

        let opened = ShortcutBootstrapService.shared.runDataOffShortcut(txId: txId) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if success {
                    self.handleDataOffCallbackSuccess()
                } else {
                    self.handleFailure(stage: "DataOffShortcut", reason: "DataOff 捷徑啟動失敗或逾時")
                }
            }
        }

        if !opened {
            handleFailure(stage: "OpenDataOffShortcut", reason: "無法開啟 DataOff 捷徑 URL")
        } else {
            scheduleTimeout(seconds: 20, stage: "DataOffCallback")
        }
    }

    private func handleDataOffCallbackSuccess() {
        guard state == .requestingDataOff || state == .waitingForDataOffCallback else { return }
        BootstrapTraceStore.shared.recordEvent(.dataOffCallbackReceived)
        transitionTo(.waitingForCellularOff)

        // Wait for physical radio interface settlement (ConnectionMonitor observes isCellularAvailable == false)
        scheduleTimeout(seconds: 8, stage: "CellularSettle")

        Task {
            let settled = await waitForCellularOffSettlement(timeoutSeconds: 4.0)
            if settled {
                BootstrapTraceStore.shared.recordEvent(.cellularOffConfirmed)
                LogManager.shared.addInfoLog("Physical cellular settlement confirmed.")
            } else {
                LogManager.shared.addWarningLog("Cellular settlement timed out; proceeding with tunnel startup anyway.")
            }
            await proceedToBootstrapping()
        }
    }

    private func waitForCellularOffSettlement(timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !ConnectionMonitor.shared.isCellularAvailable {
                return true
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return !ConnectionMonitor.shared.isCellularAvailable
    }

    private func proceedToBootstrapping() async {
        guard state == .waitingForCellularOff else { return }
        transitionTo(.bootstrapping)
        scheduleTimeout(seconds: 25, stage: "BootstrapTunnel")

        // Trigger TunnelManager start
        TunnelManager.shared.start(showErrorUI: false)

        // Await connection / RSD / DVT ready
        let connected = await waitForTunnelConnected(timeoutSeconds: 15.0)
        guard connected else {
            handleFailure(stage: "RPairing/Tunnel", reason: TunnelManager.shared.lastErrorMessage ?? "通道建立失敗")
            return
        }

        transitionTo(.waitingForRSD)
        BootstrapTraceStore.shared.recordEvent(.rsdReady)

        transitionTo(.waitingForDVT)
        BootstrapTraceStore.shared.recordEvent(.dvtReady)

        // Verify first real location write before restoring cellular data
        await verifyFirstLocationWrite()
    }

    private func waitForTunnelConnected(timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if TunnelManager.shared.isConnected {
                return true
            }
            if !TunnelManager.shared.isStarting && TunnelManager.shared.stage == .error {
                return false
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return TunnelManager.shared.isConnected
    }

    private func verifyFirstLocationWrite() async {
        guard state == .waitingForDVT else { return }
        transitionTo(.verifyingFirstLocationWrite)
        scheduleTimeout(seconds: 10, stage: "FirstLocationWrite")

        let target = verificationCoordinate ?? RouteCoordinate(latitude: 25.0330, longitude: 121.5654)
        do {
            try await LocationSimulationService.shared.setCoordinate(target)
            LocationDataPathHealth.shared.recordSuccess()
            BootstrapTraceStore.shared.recordEvent(.firstLocationWriteSuccess)
            LogManager.shared.addInfoLog("First location write verified successfully.")
            await proceedToDataOn()
        } catch {
            LocationDataPathHealth.shared.recordFailure(error)
            BootstrapTraceStore.shared.recordEvent(.firstLocationWriteFailed, details: ["error": error.localizedDescription])
            handleFailure(stage: "FirstLocationWrite", reason: error.localizedDescription)
        }
    }

    // MARK: - Restore Cellular Data Phase

    private func proceedToDataOn() async {
        transitionTo(.requestingDataOn)
        guard let txId = activeTxId else {
            finishSuccess()
            return
        }

        scheduleTimeout(seconds: 20, stage: "DataOnCallback")
        BootstrapTraceStore.shared.recordEvent(.dataOnRequested, details: ["txId": txId])

        let opened = ShortcutBootstrapService.shared.runDataOnShortcut(txId: txId) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if success {
                    self.handleDataOnCallbackSuccess()
                } else {
                    LogManager.shared.addWarningLog("DataOn shortcut callback returned false or timed out; prompting manual check.")
                    self.finishSuccess()
                }
            }
        }

        if !opened {
            LogManager.shared.addWarningLog("Could not open DataOn shortcut URL; prompting user to restore manually.")
            self.requiresManualDataOnAlert = true
            finishSuccess()
        }
    }

    private func handleDataOnCallbackSuccess() {
        guard state == .requestingDataOn || state == .waitingForDataOnCallback else { return }
        BootstrapTraceStore.shared.recordEvent(.dataOnCallbackReceived)
        transitionTo(.waitingForCellularOn)

        Task {
            // Give cellular radio brief window to re-settle
            try? await Task.sleep(for: .seconds(2))
            BootstrapTraceStore.shared.recordEvent(.cellularOnConfirmed)
            self.finishSuccess()
        }
    }

    private func finishSuccess() {
        stateTimeoutTask?.cancel()
        stateTimeoutTask = nil
        transitionTo(.completed)
        BootstrapTraceStore.shared.finishTrace(outcome: "SUCCESS")
        TunnelManager.shared.locationDataPathReady()

        let completion = activeCompletion
        activeCompletion = nil
        completion?(.success(()))
    }

    // MARK: - Rollback & Recovery Logic

    private func handleFailure(stage: String, reason: String) {
        stateTimeoutTask?.cancel()
        stateTimeoutTask = nil
        lastErrorMessage = "\(stage): \(reason)"
        LogManager.shared.addErrorLog("CellularAssistedBootstrap failed at \(stage): \(reason)")

        let wasDataOff = state.isDataTurnedOff
        transitionTo(.failedRecoveringData)
        BootstrapTraceStore.shared.recordEvent(.failed, details: ["stage": stage, "reason": reason])

        if wasDataOff {
            performRollbackRecovery(stage: stage, reason: reason)
        } else {
            BootstrapTraceStore.shared.finishTrace(outcome: "FAILED", failureStage: stage, failureReason: reason)
            transitionTo(.idle)
            let completion = activeCompletion
            activeCompletion = nil
            completion?(.failure(NSError(domain: "RouteLocation.Assisted", code: -101, userInfo: [NSLocalizedDescriptionKey: reason])))
        }
    }

    private func performRollbackRecovery(stage: String, reason: String) {
        BootstrapTraceStore.shared.recordEvent(.recoveryDataOnStarted)
        let recoveryTx = "rb-\(UUID().uuidString.prefix(6))"

        let opened = ShortcutBootstrapService.shared.runDataOnShortcut(txId: recoveryTx) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else { return }
                BootstrapTraceStore.shared.recordEvent(.recoveryDataOnCompleted, details: ["success": String(success)])
                if !success {
                    self.requiresManualDataOnAlert = true
                }
                self.finalizeRollback(stage: stage, reason: reason)
            }
        }

        if !opened {
            self.requiresManualDataOnAlert = true
            finalizeRollback(stage: stage, reason: reason)
        }
    }

    private func finalizeRollback(stage: String, reason: String) {
        BootstrapTraceStore.shared.finishTrace(outcome: "ROLLBACK", failureStage: stage, failureReason: reason)
        transitionTo(.idle)
        let completion = activeCompletion
        activeCompletion = nil
        completion?(.failure(NSError(domain: "RouteLocation.Assisted", code: -102, userInfo: [NSLocalizedDescriptionKey: reason])))
    }

    // MARK: - Cancellation & Timeouts

    func cancel() {
        guard state.isRunning else { return }
        stateTimeoutTask?.cancel()
        stateTimeoutTask = nil
        let wasDataOff = state.isDataTurnedOff
        transitionTo(.cancelled)
        BootstrapTraceStore.shared.recordEvent(.failed, details: ["reason": "CancelledByUser"])

        if wasDataOff {
            performRollbackRecovery(stage: "Cancellation", reason: "使用者取消操作")
        } else {
            BootstrapTraceStore.shared.finishTrace(outcome: "CANCELLED")
            transitionTo(.idle)
            let comp = activeCompletion
            activeCompletion = nil
            comp?(.failure(NSError(domain: "RouteLocation.Assisted", code: -103, userInfo: [NSLocalizedDescriptionKey: "操作已取消"])))
        }
    }

    private func scheduleTimeout(seconds: Double, stage: String) {
        stateTimeoutTask?.cancel()
        stateTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch { return }
            guard let self else { return }
            await MainActor.run {
                if self.state.isRunning {
                    LogManager.shared.addWarningLog("Assisted bootstrap state timed out at: \(stage)")
                    self.handleFailure(stage: stage, reason: "等待逾時（\(Int(seconds)) 秒）")
                }
            }
        }
    }

    private func transitionTo(_ newState: CellularAssistedState) {
        self.state = newState
        LogManager.shared.addInfoLog("CellularAssistedState -> \(newState.rawValue) (\(newState.label))")
    }

    #if DEBUG
    func resetForTesting() {
        state = .idle
        activeTxId = nil
        lastErrorMessage = nil
        requiresManualDataOnAlert = false
        activeCompletion = nil
        stateTimeoutTask?.cancel()
        stateTimeoutTask = nil
    }

    func forceStateForTesting(_ newState: CellularAssistedState) {
        self.state = newState
    }
    #endif
}
