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

    // Explicit transaction safety flags (Blocker C)
    @Published private(set) var dataOffWasRequested: Bool = false
    @Published private(set) var cellularOffWasObserved: Bool = false
    @Published private(set) var dataRestoreRequired: Bool = false

    private var activeCompletion: ((Result<Void, Error>) -> Void)?
    private var verificationCoordinate: RouteCoordinate?
    private var cancellables: Set<AnyCancellable> = []
    private var stateTimeoutTask: Task<Void, Never>?
    var simulationSink: any LocationSimulationSink = DeviceLocationSimulationService.shared

    private init() {}

    // MARK: - Eligibility Check (Blocker K)

    var isEligibleForDataOff: Bool {
        guard ShortcutBootstrapService.shared.isShortcutAssistedEnabled else { return false }
        let monitor = ConnectionMonitor.shared
        let hasActiveDVT = monitor.activeDVTSessionAvailable || LocationDataPathHealth.shared.hasRecentSuccess
        guard !hasActiveDVT else { return false }
        guard !monitor.isWifiAvailable && (monitor.currentTransport == .cellular || monitor.isCellularAvailable) else { return false }
        return true
    }

    // MARK: - Start Assisted Bootstrap (Blockers C, K, M)

    func startAssistedBootstrap(
        targetCoordinate: RouteCoordinate? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !state.isRunning else {
            completion(.failure(NSError(domain: "RouteLocation.Assisted", code: -100, userInfo: [NSLocalizedDescriptionKey: "已有進行中的輔助啟動程序"])))
            return
        }

        guard ShortcutBootstrapService.shared.isShortcutAssistedEnabled else {
            completion(.failure(NSError(domain: "RouteLocation.Assisted", code: -104, userInfo: [NSLocalizedDescriptionKey: "捷徑輔助啟動未啟用"])))
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
        guard monitor.currentTransport == .cellular || monitor.isCellularAvailable else {
            completion(.failure(NSError(domain: "RouteLocation.Assisted", code: -106, userInfo: [NSLocalizedDescriptionKey: "未處於純行動網路環境，不符合輔助啟動條件"])))
            return
        }

        let txId = "tx-\(UUID().uuidString.prefix(8))"
        self.activeTxId = txId
        self.verificationCoordinate = targetCoordinate
        self.activeCompletion = completion
        self.lastErrorMessage = nil
        self.requiresManualDataOnAlert = false
        self.dataOffWasRequested = true
        self.cellularOffWasObserved = false
        self.dataRestoreRequired = true

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
            transitionTo(.waitingForDataOffCallback)
            scheduleTimeout(seconds: 20, stage: "DataOffCallback")
        }
    }

    #if DEBUG
    var testSettlementTimeoutSeconds: Double?
    #endif

    private var offSettlementTimeout: Double {
        #if DEBUG
        if let custom = testSettlementTimeoutSeconds { return custom }
        #endif
        return 4.0
    }

    private var onSettlementTimeout: Double {
        #if DEBUG
        if let custom = testSettlementTimeoutSeconds { return custom }
        #endif
        return 5.0
    }

    // MARK: - Cellular OFF Settlement (Blocker A)

    func handleDataOffCallbackSuccess() {
        guard state == .requestingDataOff || state == .waitingForDataOffCallback else { return }
        BootstrapTraceStore.shared.recordEvent(.dataOffCallbackReceived)
        transitionTo(.waitingForCellularOff)

        // Wait for physical radio interface settlement (ConnectionMonitor observes isCellularAvailable == false)
        scheduleTimeout(seconds: 8, stage: "CellularSettle")

        Task {
            let settled = await waitForCellularOffSettlement(timeoutSeconds: self.offSettlementTimeout)
            if settled {
                self.cellularOffWasObserved = true
                BootstrapTraceStore.shared.recordEvent(.cellularOffConfirmed)
                LogManager.shared.addInfoLog("Physical cellular settlement confirmed.")
                await self.proceedToBootstrapping()
            } else {
                LogManager.shared.addErrorLog("Cellular settlement timed out; physical cellular radio remains active. Aborting bootstrap and restoring data.")
                self.handleFailure(
                    stage: "CellularSettle",
                    reason: "行動數據關閉確認逾時：系統仍偵測到行動網路，無法安全建立通道，自動觸發恢復"
                )
            }
        }
    }

    private func waitForCellularOffSettlement(timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !ConnectionMonitor.shared.isCellularAvailable {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !ConnectionMonitor.shared.isCellularAvailable
    }

    // MARK: - Bootstrapping Phase (Blocker E)

    private func proceedToBootstrapping() async {
        guard state == .waitingForCellularOff else { return }
        transitionTo(.bootstrapping)
        scheduleTimeout(seconds: 25, stage: "BootstrapTunnel")

        // Trigger TunnelManager start
        TunnelManager.shared.start(showErrorUI: false)

        // Await connection / RSD ready
        let connected = await waitForTunnelConnected(timeoutSeconds: 15.0)
        guard connected else {
            handleFailure(stage: "RPairing/Tunnel", reason: TunnelManager.shared.lastErrorMessage ?? "通道建立失敗")
            return
        }

        transitionTo(.waitingForRSD)
        transitionTo(.waitingForDVT)

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

    // MARK: - Location Verification (Blocker D)

    private func verifyFirstLocationWrite() async {
        guard state == .waitingForDVT else { return }
        transitionTo(.verifyingFirstLocationWrite)
        scheduleTimeout(seconds: 10, stage: "FirstLocationWrite")

        if let target = verificationCoordinate {
            do {
                try await simulationSink.setCoordinate(target)
                LocationDataPathHealth.shared.recordSuccess()
                BootstrapTraceStore.shared.recordEvent(.firstLocationWriteSuccess, details: ["coord": "\(target.latitude),\(target.longitude)"])
                LogManager.shared.addInfoLog("First location write verified successfully at \(target.latitude), \(target.longitude)")
                await proceedToDataOn()
            } catch {
                LocationDataPathHealth.shared.recordFailure(error)
                BootstrapTraceStore.shared.recordEvent(.firstLocationWriteFailed, details: ["error": error.localizedDescription])
                handleFailure(stage: "FirstLocationWrite", reason: error.localizedDescription)
            }
        } else {
            LogManager.shared.addInfoLog("No verification coordinate provided; skipping mock location injection in bootstrap.")
            await proceedToDataOn()
        }
    }

    // MARK: - Restore Cellular Data Phase (Blockers B, C, M)

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
                    self.requiresManualDataOnAlert = true
                    self.finishWithUnconfirmedOutcome(stage: "DataOnCallback", reason: "DataOn 捷徑回呼逾時或未成功，請確認行動數據")
                }
            }
        }

        if !opened {
            LogManager.shared.addWarningLog("Could not open DataOn shortcut URL; prompting user to restore manually.")
            self.requiresManualDataOnAlert = true
            finishWithUnconfirmedOutcome(stage: "OpenDataOnShortcut", reason: "無法開啟 DataOn 捷徑，請手動開啟行動數據")
        } else {
            transitionTo(.waitingForDataOnCallback)
        }
    }

    // MARK: - Cellular ON Settlement (Blocker B)

    func handleDataOnCallbackSuccess() {
        guard state == .requestingDataOn || state == .waitingForDataOnCallback else { return }
        BootstrapTraceStore.shared.recordEvent(.dataOnCallbackReceived)
        transitionTo(.waitingForCellularOn)

        scheduleTimeout(seconds: 10, stage: "CellularOnSettle")

        Task {
            let confirmed = await waitForCellularOnSettlement(timeoutSeconds: self.onSettlementTimeout)
            if confirmed {
                self.dataRestoreRequired = false
                BootstrapTraceStore.shared.recordEvent(.cellularOnConfirmed)
                self.finishSuccess()
            } else {
                LogManager.shared.addWarningLog("Cellular ON confirmation timed out; radio not observed as available.")
                self.requiresManualDataOnAlert = true
                self.finishWithUnconfirmedOutcome(
                    stage: "CellularOnSettle",
                    reason: "行動數據恢復回呼已收到，但尚未偵測到行動網路恢復，請確認行動數據開關"
                )
            }
        }
    }

    private func waitForCellularOnSettlement(timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if ConnectionMonitor.shared.isCellularAvailable {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return ConnectionMonitor.shared.isCellularAvailable
    }

    private func finishSuccess() {
        stateTimeoutTask?.cancel()
        stateTimeoutTask = nil
        dataRestoreRequired = false
        transitionTo(.completed)
        BootstrapTraceStore.shared.finishTrace(outcome: "SUCCESS")
        TunnelManager.shared.locationDataPathReady()

        let completion = activeCompletion
        resetTransactionState()
        completion?(.success(()))
    }

    private func finishWithUnconfirmedOutcome(stage: String, reason: String) {
        stateTimeoutTask?.cancel()
        stateTimeoutTask = nil
        transitionTo(.completed)
        BootstrapTraceStore.shared.finishTrace(
            outcome: "COMPLETED_DATA_RESTORE_UNCONFIRMED",
            failureStage: stage,
            failureReason: reason
        )
        TunnelManager.shared.locationDataPathReady()

        let completion = activeCompletion
        resetTransactionState()
        completion?(.success(()))
    }

    // MARK: - Rollback & Recovery Logic (Blocker C)

    private func handleFailure(stage: String, reason: String) {
        stateTimeoutTask?.cancel()
        stateTimeoutTask = nil
        lastErrorMessage = "\(stage): \(reason)"
        LogManager.shared.addErrorLog("CellularAssistedBootstrap failed at \(stage): \(reason)")

        let shouldRollback = dataRestoreRequired || dataOffWasRequested
        transitionTo(.failedRecoveringData)
        BootstrapTraceStore.shared.recordEvent(.failed, details: ["stage": stage, "reason": reason])

        if shouldRollback {
            performRollbackRecovery(stage: stage, reason: reason)
        } else {
            BootstrapTraceStore.shared.finishTrace(outcome: "FAILED", failureStage: stage, failureReason: reason)
            transitionTo(.idle)
            let completion = activeCompletion
            resetTransactionState()
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
                } else {
                    self.dataRestoreRequired = false
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
        resetTransactionState()
        completion?(.failure(NSError(domain: "RouteLocation.Assisted", code: -102, userInfo: [NSLocalizedDescriptionKey: reason])))
    }

    // MARK: - Cancellation & Timeouts (Blocker M)

    func cancel() {
        guard state.isRunning else { return }
        stateTimeoutTask?.cancel()
        stateTimeoutTask = nil
        let shouldRollback = dataRestoreRequired || dataOffWasRequested
        transitionTo(.cancelled)
        BootstrapTraceStore.shared.recordEvent(.failed, details: ["reason": "CancelledByUser"])

        if shouldRollback {
            performRollbackRecovery(stage: "Cancellation", reason: "使用者取消操作")
        } else {
            BootstrapTraceStore.shared.finishTrace(outcome: "CANCELLED")
            transitionTo(.idle)
            let comp = activeCompletion
            resetTransactionState()
            comp?(.failure(NSError(domain: "RouteLocation.Assisted", code: -103, userInfo: [NSLocalizedDescriptionKey: "操作已取消"])))
        }
    }

    private func resetTransactionState() {
        activeTxId = nil
        verificationCoordinate = nil
        activeCompletion = nil
        stateTimeoutTask?.cancel()
        stateTimeoutTask = nil
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
        dataOffWasRequested = false
        cellularOffWasObserved = false
        dataRestoreRequired = false
        verificationCoordinate = nil
        activeCompletion = nil
        testSettlementTimeoutSeconds = nil
        simulationSink = DeviceLocationSimulationService.shared
        stateTimeoutTask?.cancel()
        stateTimeoutTask = nil
    }

    func forceStateForTesting(_ newState: CellularAssistedState) {
        self.state = newState
    }

    func setFlagsForTesting(dataOffRequested: Bool, cellularOffObserved: Bool, restoreRequired: Bool) {
        self.dataOffWasRequested = dataOffRequested
        self.cellularOffWasObserved = cellularOffObserved
        self.dataRestoreRequired = restoreRequired
    }

    func testTriggerFailure(stage: String, reason: String) {
        handleFailure(stage: stage, reason: reason)
    }

    func testVerifyLocation(coordinate: RouteCoordinate?) async {
        self.verificationCoordinate = coordinate
        self.state = .waitingForDVT
        await verifyFirstLocationWrite()
    }
    #endif
}
