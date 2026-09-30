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

enum AssistedBootstrapReason: String, Codable, Equatable {
    case coldStart
    case playbackFailureRecovery
    case stalePreparedSessionRecovery

    var usesRecentSuccessEvidence: Bool {
        self == .coldStart
    }
}

@MainActor
final class CellularAssistedBootstrapStateMachine: ObservableObject {
    static let shared = CellularAssistedBootstrapStateMachine()
    /// The known-good Assisted DataOff sequence always bootstraps through
    /// LocalDevVPN, independent of any developer direct-endpoint selection.
    static let assistedBootstrapEndpoint = DeviceConnectionContext.defaultTargetIPAddress
    private static let recoveryIntentKey = "RouteLocation.assistedRecoveryIntent"
    private static let recoveryAttemptKey = "RouteLocation.assistedRecoveryAttemptedForeground"

    @Published private(set) var state: CellularAssistedState = .idle
    @Published private(set) var activeTxId: String?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var requiresManualDataOnAlert: Bool = false

    // Explicit transaction safety flags (Blocker C)
    @Published private(set) var dataOffWasRequested: Bool = false
    @Published private(set) var cellularOffWasObserved: Bool = false
    @Published private(set) var dataRestoreRequired: Bool = false
    private(set) var locationWriteSuccessConfirmed: Bool = false

    private var activeCompletion: ((Result<BootstrapProceedDisposition, Error>) -> Void)?
    private var verificationCoordinate: RouteCoordinate?
    private var cancellables: Set<AnyCancellable> = []
    private var stateTimeoutTask: Task<Void, Never>?
    private var recoveryAttemptedInForeground = false
    private let foregroundRecoveryProcessID = UUID().uuidString
    var simulationSink: any LocationSimulationSink = DeviceLocationSimulationService.shared

    private struct RecoveryIntent: Codable {
        let transactionID: String
        let startedAt: Date
        var phase: String
    }

    private struct RecoveryAttemptMarker: Codable {
        let transactionID: String
        let processID: String
        let attemptedAt: Date
    }

    private init() {}

    var hasPendingRecoveryIntent: Bool {
        UserDefaults.standard.data(forKey: Self.recoveryIntentKey) != nil
    }

    func beginForegroundRecoveryCycle() {
        // A Shortcut round-trip re-enters the app as active while the
        // persistent intent is still present. Never reset the in-flight guard
        // during that round-trip; it would launch a duplicate DataOn.
        guard !hasPendingRecoveryIntent else { return }
        recoveryAttemptedInForeground = false
    }

    func handleStaleRecoveryIfNeeded() {
        guard !state.isRunning, !recoveryAttemptedInForeground,
              let data = UserDefaults.standard.data(forKey: Self.recoveryIntentKey),
              let intent = try? JSONDecoder().decode(RecoveryIntent.self, from: data) else { return }
        if let markerData = UserDefaults.standard.data(forKey: Self.recoveryAttemptKey),
           let marker = try? JSONDecoder().decode(RecoveryAttemptMarker.self, from: markerData),
           marker.processID == foregroundRecoveryProcessID {
            recoveryAttemptedInForeground = true
            return
        }
        recoveryAttemptedInForeground = true
        let marker = RecoveryAttemptMarker(
            transactionID: intent.transactionID,
            processID: foregroundRecoveryProcessID,
            attemptedAt: .now
        )
        if let markerData = try? JSONEncoder().encode(marker) {
            UserDefaults.standard.set(markerData, forKey: Self.recoveryAttemptKey)
        }
        BootstrapTraceStore.shared.recordEvent(.staleRecoveryDetected, details: [
            "transactionID": intent.transactionID,
            "phase": intent.phase,
            "startedAt": intent.startedAt.ISO8601Format()
        ])
        let recoveryTx = UUID().uuidString
        BootstrapTraceStore.shared.recordEvent(.staleRecoveryDataOnStarted, details: ["transactionID": recoveryTx])
        let opened = ShortcutBootstrapService.shared.runDataOnShortcut(txId: recoveryTx) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if success {
                    self.clearRecoveryIntent()
                    BootstrapTraceStore.shared.recordEvent(.staleRecoveryCompleted, details: ["confirmed": "true"])
                    ToastManager.shared.show(L10n.text("已完成待恢復的行動數據復原。"), kind: .success)
                } else {
                    self.requiresManualDataOnAlert = true
                    self.lastErrorMessage = L10n.text("偵測到未完成的行動數據恢復。請手動開啟行動數據，或完成 RouteLocationDataOn 捷徑設定。")
                    BootstrapTraceStore.shared.recordEvent(.staleRecoveryCompleted, details: ["confirmed": "false"])
                }
            }
        }
        if !opened {
            requiresManualDataOnAlert = true
            lastErrorMessage = L10n.text("偵測到未完成的行動數據恢復。請手動開啟行動數據。")
            BootstrapTraceStore.shared.recordEvent(.staleRecoveryCompleted, details: ["confirmed": "false", "opened": "false"])
        }
    }

    // MARK: - Eligibility Check (Blocker K)

    var isEligibleForDataOff: Bool {
        guard ShortcutBootstrapService.shared.isShortcutAssistedEnabled else { return false }
        let monitor = ConnectionMonitor.shared
        let prepared = LocationSimulationCommandQueue.shared.sync { location_simulation_session_snapshot().isPrepared }
        let hasActiveDVT = monitor.activeDVTSessionAvailable || LocationDataPathHealth.shared.hasRecentSuccess || prepared
        guard !hasActiveDVT else { return false }
        guard !monitor.isWifiAvailable && (monitor.currentTransport == .cellular || monitor.isCellularAvailable) else { return false }
        return true
    }

    // MARK: - Start Assisted Bootstrap (Blockers C, K, M)

    func startAssistedBootstrap(
        targetCoordinate: RouteCoordinate? = nil,
        reason: AssistedBootstrapReason = .coldStart,
        completion: @escaping (Result<BootstrapProceedDisposition, Error>) -> Void
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
        let preparedSession = LocationSimulationCommandQueue.shared.sync {
            location_simulation_session_snapshot().isPrepared
        }
        if reason.usesRecentSuccessEvidence && (monitor.activeDVTSessionAvailable || LocationDataPathHealth.shared.hasRecentSuccess || preparedSession) {
            LogManager.shared.addInfoLog("Pre-launch check: Active DVT session already present. Skipping shortcut.")
            completion(.success(.needsLocationWrite))
            return
        }
        if monitor.isWifiAvailable {
            LogManager.shared.addInfoLog("Pre-launch check: Wi-Fi interface detected. Skipping cellular shortcut.")
            completion(.success(.needsLocationWrite))
            return
        }
        guard monitor.currentTransport == .cellular || monitor.isCellularAvailable else {
            completion(.failure(NSError(domain: "RouteLocation.Assisted", code: -106, userInfo: [NSLocalizedDescriptionKey: "未處於純行動網路環境，不符合輔助啟動條件"])))
            return
        }

        let txId = UUID().uuidString
        self.activeTxId = txId
        self.verificationCoordinate = targetCoordinate
        self.locationWriteSuccessConfirmed = false
        self.activeCompletion = completion
        self.lastErrorMessage = nil
        self.requiresManualDataOnAlert = false
        self.dataOffWasRequested = true
        self.cellularOffWasObserved = false
        self.dataRestoreRequired = true

        persistRecoveryIntent(transactionID: txId, phase: "data-off-requested")

        #if DEBUG
        lastAssistedBootstrapEndpointForTesting = Self.assistedBootstrapEndpoint
        #endif
        BootstrapTraceStore.shared.startTrace(
            txId: txId,
            mode: "AssistedBeta",
            targetAddress: "\(Self.assistedBootstrapEndpoint):49152"
        )
        transitionTo(.requestingDataOff)

        BootstrapTraceStore.shared.recordEvent(.dataOffRequested, details: ["txId": txId])

        let opened = ShortcutBootstrapService.shared.runDataOffShortcut(txId: txId) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if success {
                    await self.handleDataOffCallbackSuccess()
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
    var testSimulateCellularSettlementConfirmed: Bool?
    var testStabilizationDelaySeconds: Double?
    var testCellularOffSequence: [Bool]?
    var testMockBootstrapRunner: (() async -> Bool)?
    var testMockTCPSettlingRunner: (() async -> CellularTCPSettlingResult)?
    var testBootstrapAttemptCount: Int = 0
    private(set) var lastAssistedBootstrapEndpointForTesting: String?
    var testVerificationCoordinate: RouteCoordinate? {
        return verificationCoordinate
    }
    #endif

    private var effectiveStabilizationDelay: Double {
        #if DEBUG
        if let custom = testStabilizationDelaySeconds { return custom }
        #endif
        return ShortcutBootstrapService.shared.cellularBootstrapStabilizationDelay
    }

    private var stabilizationTask: Task<Void, Error>?

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

    // MARK: - Cellular OFF Settlement & Additional Stabilization

    func handleDataOffCallbackSuccess() async {
        guard state == .requestingDataOff || state == .waitingForDataOffCallback else { return }
        transitionTo(.waitingForCellularOff)
        updateRecoveryPhase("data-off-callback")

        let additionalDelay = effectiveStabilizationDelay
        let isCellularOff = checkIsCellularOff()

        if isCellularOff {
            BootstrapTraceStore.shared.recordEvent(.dataOffCallbackReceived)
            BootstrapTraceStore.shared.recordEvent(.cellularOffConfirmed, details: ["source": "nwpath"])
            self.cellularOffWasObserved = true
            LogManager.shared.addInfoLog("DataOff callback success received. NWPath cellular off confirmed. Additional stabilization delay: \(additionalDelay)s.")
        } else {
            BootstrapTraceStore.shared.recordEvent(.dataOffCallbackReceived, details: [
                "cellularInterfaceStillObserved": "true"
            ])
            self.cellularOffWasObserved = false
            LogManager.shared.addInfoLog("DataOff callback success received, but cellular interface still observed by NWPath. Proceeding with bootstrap.")
        }

        if additionalDelay > 0 {
            BootstrapTraceStore.shared.recordEvent(
                .additionalStabilizationStart,
                details: ["delaySeconds": String(format: "%.1f", additionalDelay)]
            )
            scheduleTimeout(seconds: additionalDelay + 5.0, stage: "AdditionalStabilization")
            try? await Task.sleep(for: .milliseconds(Int(additionalDelay * 1000)))
            guard state.isRunning else { return }
            BootstrapTraceStore.shared.recordEvent(
                .additionalStabilizationEnd,
                details: ["delaySeconds": String(format: "%.1f", additionalDelay)]
            )
        }

        performSafePreBootstrap()
        await self.proceedToBootstrapping()
    }

    private func performSafePreBootstrap() {
        let pairingURL = PairingFileStore.prepareURL()
        let pairingExists = FileManager.default.fileExists(atPath: pairingURL.path)
        if !pairingExists {
            LogManager.shared.addWarningLog("Pre-bootstrap check: Pairing file not found at \(pairingURL.lastPathComponent)")
        }
        let usesVPN = ConnectionMonitor.shared.usesVPNInterface
        LogManager.shared.addInfoLog("Pre-bootstrap check: VPN active: \(usesVPN), target coord present: \(verificationCoordinate != nil)")
    }

    private func checkIsCellularOff() -> Bool {
        #if DEBUG
        if var sequence = testCellularOffSequence, !sequence.isEmpty {
            let next = sequence.removeFirst()
            testCellularOffSequence = sequence
            return next
        }
        if let sim = testSimulateCellularSettlementConfirmed {
            return sim
        }
        #endif
        return !ConnectionMonitor.shared.isCellularAvailable
    }

    private func waitForContinuousCellularOffDwell(timeoutSeconds: Double, requiredDwellSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var continuousOffStart: Date? = nil
        var recordedConfirmed = false
        var resetCount = 0

        while Date() < deadline && !Task.isCancelled && state.isRunning {
            let isOff = checkIsCellularOff()
            if isOff {
                if continuousOffStart == nil {
                    continuousOffStart = Date()
                    if !recordedConfirmed {
                        BootstrapTraceStore.shared.recordEvent(.cellularOffConfirmed)
                        if requiredDwellSeconds > 0 {
                            BootstrapTraceStore.shared.recordEvent(
                                .stabilizationAfterOffStart,
                                details: ["delaySeconds": String(format: "%.1f", requiredDwellSeconds)]
                            )
                        }
                        recordedConfirmed = true
                    }
                    LogManager.shared.addInfoLog("Cellular OFF observed; starting continuous dwell timer (need \(requiredDwellSeconds)s)")
                }

                let elapsed = Date().timeIntervalSince(continuousOffStart!)
                if elapsed >= requiredDwellSeconds {
                    if requiredDwellSeconds > 0 {
                        let durationMs = Int(elapsed * 1000)
                        BootstrapTraceStore.shared.recordEvent(
                            .stabilizationAfterOffEnd,
                            details: [
                                "delaySeconds": String(format: "%.1f", requiredDwellSeconds),
                                "stableDurationMs": "\(durationMs)",
                                "resetCount": "\(resetCount)"
                            ]
                        )
                    }
                    return true
                }
            } else {
                if continuousOffStart != nil {
                    resetCount += 1
                    LogManager.shared.addWarningLog("Cellular became active during stabilization dwell; resetting continuous timer (reset #\(resetCount)).")
                    continuousOffStart = nil
                }
            }

            try? await Task.sleep(for: .milliseconds(50))
        }

        return false
    }

    // MARK: - Bootstrapping Phase (Blocker E)

    private func proceedToBootstrapping() async {
        guard state == .waitingForCellularOff else { return }
        transitionTo(.bootstrapping)
        updateRecoveryPhase("settling")
        scheduleTimeout(seconds: 25, stage: "BootstrapTunnel")

        #if DEBUG
        if let mock = testMockBootstrapRunner {
            testBootstrapAttemptCount += 1
            let connected = await mock()
            guard connected else {
                handleFailure(stage: "RPairing/Tunnel", reason: "通道建立失敗 (Mock)")
                return
            }
            transitionTo(.waitingForRSD)
            transitionTo(.waitingForDVT)
            await verifyFirstLocationWrite()
            return
        }
        #endif

        // The callback is not a readiness signal.  Wait for the unscoped
        // production socket route to settle before starting exactly one FFI
        // preparation attempt.
        BootstrapTraceStore.shared.recordEvent(.assistedSettlingStarted, details: [
            "target": "\(Self.assistedBootstrapEndpoint):49152",
            "budgetMs": String(Int(CellularTCPSettlingPolicy.production.totalBudget * 1000)),
            "attemptDeadlineMs": String(Int(CellularTCPSettlingPolicy.production.attemptDeadline * 1000))
        ])
        let settling: CellularTCPSettlingResult
        #if DEBUG
        if let mock = testMockTCPSettlingRunner {
            settling = await mock()
        } else {
            settling = await CellularDefaultTCPSettler.settle(targetIP: Self.assistedBootstrapEndpoint) { attempt, elapsedMs in
                Task { @MainActor in
                    BootstrapTraceStore.shared.recordEvent(.assistedTCPProbeAttempt, details: [
                        "attempt": String(attempt),
                        "elapsedFromCallbackMs": String(elapsedMs),
                        "target": "\(Self.assistedBootstrapEndpoint):49152",
                        "deadlineMs": String(Int(CellularTCPSettlingPolicy.production.attemptDeadline * 1000)),
                        "cellularObserved": String(ConnectionMonitor.shared.isCellularAvailable),
                        "vpnObserved": String(ConnectionMonitor.shared.usesVPNInterface)
                    ])
                }
            }
        }
        #else
        settling = await CellularDefaultTCPSettler.settle(targetIP: Self.assistedBootstrapEndpoint) { attempt, elapsedMs in
            Task { @MainActor in
                BootstrapTraceStore.shared.recordEvent(.assistedTCPProbeAttempt, details: [
                    "attempt": String(attempt),
                    "elapsedFromCallbackMs": String(elapsedMs),
                    "target": "\(Self.assistedBootstrapEndpoint):49152",
                    "deadlineMs": String(Int(CellularTCPSettlingPolicy.production.attemptDeadline * 1000)),
                    "cellularObserved": String(ConnectionMonitor.shared.isCellularAvailable),
                    "vpnObserved": String(ConnectionMonitor.shared.usesVPNInterface)
                ])
            }
        }
        #endif
        guard settling.succeeded else {
            BootstrapTraceStore.shared.recordEvent(.assistedTCPProbeFailed, details: [
                "attempts": String(settling.attempts),
                "elapsedFromCallbackMs": String(settling.elapsedMs),
                "target": "\(Self.assistedBootstrapEndpoint):49152"
            ])
            handleFailure(stage: "TCPSettling", reason: "等待 \(Self.assistedBootstrapEndpoint):49152 就緒逾時")
            return
        }
        BootstrapTraceStore.shared.recordEvent(.assistedTCPReady, details: [
            "attempts": String(settling.attempts),
            "elapsedFromCallbackMs": String(settling.elapsedMs),
            "target": "\(Self.assistedBootstrapEndpoint):49152"
        ])

        transitionTo(.waitingForRSD)
        updateRecoveryPhase("ffi-preparing")
        BootstrapTraceStore.shared.recordEvent(.assistedFFIPrepareStarted, details: ["target": Self.assistedBootstrapEndpoint])
        let pairingPath = PairingFileStore.prepareURL().path
        let preparation = await withCheckedContinuation { continuation in
            if LocationSimulationCommandQueue.shared.sync { location_simulation_session_snapshot().isPrepared } {
                continuation.resume(returning: LocationSimulationPreparationResult(
                    target: "\(Self.assistedBootstrapEndpoint):49152", stage: .ready,
                    statusCode: 0, ffiCode: nil, ffiSubCode: nil,
                    message: "Prepared session reused", durationMs: 0
                ))
            } else {
                ProductionLocationSessionPreparer.shared.prepare(
                    endpointAddress: Self.assistedBootstrapEndpoint,
                    pairingFile: pairingPath
                ) { result in
                    continuation.resume(returning: result)
                }
            }
        }
        BootstrapTraceStore.shared.recordEvent(.assistedFFIPrepareResult, details: [
            "stage": preparation.stage.rawValue,
            "status": preparation.isSuccess ? "READY" : "FAILED",
            "ffiCode": preparation.ffiCode.map(String.init) ?? "",
            "ffiSubCode": preparation.ffiSubCode.map(String.init) ?? "",
            "message": preparation.message ?? "",
            "durationMs": String(Int(preparation.durationMs))
        ])
        guard preparation.isSuccess else {
            handleFailure(stage: preparation.stage.rawValue, reason: preparation.message ?? "FFI 準備失敗")
            return
        }

        transitionTo(.waitingForDVT)
        updateRecoveryPhase("dvt-ready")
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
                if let deviceSink = simulationSink as? DeviceLocationSimulationService {
                    try await deviceSink.setCoordinate(
                        target,
                        endpointAddress: Self.assistedBootstrapEndpoint
                    )
                } else {
                    try await simulationSink.setCoordinate(target)
                }
                self.locationWriteSuccessConfirmed = true
                LocationDataPathHealth.shared.recordSuccess()
                BootstrapTraceStore.shared.recordEvent(.firstLocationWriteSuccess, details: [
                    "coordinatePresent": "true",
                    "targetKind": "singlePointOrRouteFirst"
                ])
                LogManager.shared.addInfoLog("First location write verified successfully (coordinate injected).")
                await Task.yield()
                await proceedToDataOn()
            } catch {
                self.locationWriteSuccessConfirmed = false
                LocationDataPathHealth.shared.recordFailure(error)
                BootstrapTraceStore.shared.recordEvent(.firstLocationWriteFailed, details: ["error": error.localizedDescription])
                handleFailure(stage: "FirstLocationWrite", reason: error.localizedDescription)
            }
        } else {
            self.locationWriteSuccessConfirmed = false
            handleFailure(
                stage: "FirstLocationWrite",
                reason: "Missing verification coordinate; refusing to enable cellular data before the first location write."
            )
        }
    }

    // MARK: - Restore Cellular Data Phase (Blockers B, C, M)

    private func proceedToDataOn() async {
        transitionTo(.requestingDataOn)
        updateRecoveryPhase("data-on-requested")
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
                    await self.handleDataOnCallbackSuccess()
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

    func handleDataOnCallbackSuccess() async {
        guard state == .requestingDataOn || state == .waitingForDataOnCallback else { return }
        BootstrapTraceStore.shared.recordEvent(.dataOnCallbackReceived)
        transitionTo(.waitingForCellularOn)

        scheduleTimeout(seconds: 10, stage: "CellularOnSettle")

        let confirmed = await waitForCellularOnSettlement(timeoutSeconds: self.onSettlementTimeout)
        if confirmed {
            self.dataRestoreRequired = false
            self.clearRecoveryIntent()
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

    private func waitForCellularOnSettlement(timeoutSeconds: Double) async -> Bool {
        #if DEBUG
        if let sim = testSimulateCellularSettlementConfirmed { return sim }
        #endif
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

        let disposition: BootstrapProceedDisposition = (locationWriteSuccessConfirmed && verificationCoordinate != nil) ? .locationAlreadyWritten : .needsLocationWrite
        let completion = activeCompletion
        resetTransactionState()
        completion?(.success(disposition))
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

        let disposition: BootstrapProceedDisposition = (locationWriteSuccessConfirmed && verificationCoordinate != nil) ? .locationAlreadyWritten : .needsLocationWrite
        let completion = activeCompletion
        resetTransactionState()
        completion?(.success(disposition))
    }

    // MARK: - Rollback & Recovery Logic (Blocker C)

    private func handleFailure(stage: String, reason: String) {
        stateTimeoutTask?.cancel()
        stateTimeoutTask = nil
        stabilizationTask?.cancel()
        stabilizationTask = nil
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
                await self.handleRollbackDataOnCallback(success: success, stage: stage, reason: reason)
            }
        }

        if !opened {
            self.requiresManualDataOnAlert = true
            finalizeRollback(stage: stage, reason: reason)
        }
    }

    private func handleRollbackDataOnCallback(success: Bool, stage: String, reason: String) async {
        if success {
            let confirmed = await waitForCellularOnSettlement(timeoutSeconds: self.onSettlementTimeout)
            if confirmed {
                self.dataRestoreRequired = false
                self.clearRecoveryIntent()
                BootstrapTraceStore.shared.recordEvent(.cellularOnConfirmed, details: ["context": "rollback"])
                BootstrapTraceStore.shared.recordEvent(.recoveryDataOnCompleted, details: ["confirmed": "true"])
                LogManager.shared.addInfoLog("Rollback DataOn physical cellular restoration confirmed.")
            } else {
                self.requiresManualDataOnAlert = true
                LogManager.shared.addWarningLog("Rollback DataOn callback received but physical cellular restoration unconfirmed.")
                BootstrapTraceStore.shared.recordEvent(.recoveryDataOnCompleted, details: ["confirmed": "false"])
            }
        } else {
            self.requiresManualDataOnAlert = true
            BootstrapTraceStore.shared.recordEvent(.recoveryDataOnCompleted, details: ["success": "false"])
        }
        self.finalizeRollback(stage: stage, reason: reason)
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
        stabilizationTask?.cancel()
        stabilizationTask = nil
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
        locationWriteSuccessConfirmed = false
        stateTimeoutTask?.cancel()
        stateTimeoutTask = nil
        stabilizationTask?.cancel()
        stabilizationTask = nil
    }

    private func persistRecoveryIntent(transactionID: String, phase: String) {
        let intent = RecoveryIntent(transactionID: transactionID, startedAt: Date(), phase: phase)
        if let data = try? JSONEncoder().encode(intent) {
            UserDefaults.standard.set(data, forKey: Self.recoveryIntentKey)
        }
    }

    private func updateRecoveryPhase(_ phase: String) {
        guard let data = UserDefaults.standard.data(forKey: Self.recoveryIntentKey),
              var intent = try? JSONDecoder().decode(RecoveryIntent.self, from: data) else { return }
        intent.phase = phase
        if let updated = try? JSONEncoder().encode(intent) {
            UserDefaults.standard.set(updated, forKey: Self.recoveryIntentKey)
        }
    }

    private func clearRecoveryIntent() {
        UserDefaults.standard.removeObject(forKey: Self.recoveryIntentKey)
        UserDefaults.standard.removeObject(forKey: Self.recoveryAttemptKey)
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
        locationWriteSuccessConfirmed = false
        activeCompletion = nil
        testSettlementTimeoutSeconds = nil
        testSimulateCellularSettlementConfirmed = nil
        testStabilizationDelaySeconds = nil
        testCellularOffSequence = nil
        testMockBootstrapRunner = nil
        testMockTCPSettlingRunner = nil
        testBootstrapAttemptCount = 0
        lastAssistedBootstrapEndpointForTesting = nil
        simulationSink = DeviceLocationSimulationService.shared
        stateTimeoutTask?.cancel()
        stateTimeoutTask = nil
        stabilizationTask?.cancel()
        stabilizationTask = nil
        recoveryAttemptedInForeground = false
        clearRecoveryIntent()
    }

    func seedRecoveryIntentForTesting(transactionID: String, phase: String) {
        persistRecoveryIntent(transactionID: transactionID, phase: phase)
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

    func setActiveTxIdForTesting(_ txId: String?) {
        self.activeTxId = txId
    }

    func testWaitForContinuousCellularOffDwell(
        timeoutSeconds: Double,
        requiredDwellSeconds: Double
    ) async -> Bool {
        return await waitForContinuousCellularOffDwell(
            timeoutSeconds: timeoutSeconds,
            requiredDwellSeconds: requiredDwellSeconds
        )
    }

    func testHandleRollbackDataOnCallback(success: Bool, stage: String = "Rollback", reason: String = "Test") async {
        await handleRollbackDataOnCallback(success: success, stage: stage, reason: reason)
    }
    #endif
}
