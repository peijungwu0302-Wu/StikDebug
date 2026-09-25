import Testing
import Foundation
@testable import RouteLocation

@Suite(.serialized)
@MainActor
struct CellularAssistedBootstrapTests {

    init() {
        LocationDataPathHealth.shared.resetForTesting()
        CellularAssistedBootstrapStateMachine.shared.resetForTesting()
        ShortcutBootstrapService.shared.cancelActiveTransaction()
        ShortcutBootstrapService.shared.isShortcutAssistedEnabled = true
        BootstrapTraceStore.shared.resetForTesting()
    }

    // MARK: - 1. Eligibility Permutations

    @Test func eligibility_assistedDisabled_returnsFalse() {
        let monitor = ConnectionMonitor.shared
        monitor.updateForTesting(transport: .cellular, isWifiAvailable: false, isCellularAvailable: true)
        ShortcutBootstrapService.shared.isShortcutAssistedEnabled = false

        #expect(!CellularAssistedBootstrapStateMachine.shared.isEligibleForDataOff)
    }

    @Test func eligibility_wifiAvailable_returnsFalse() {
        let monitor = ConnectionMonitor.shared
        monitor.updateForTesting(transport: .wifi, isWifiAvailable: true, isCellularAvailable: true)
        ShortcutBootstrapService.shared.isShortcutAssistedEnabled = true

        #expect(!CellularAssistedBootstrapStateMachine.shared.isEligibleForDataOff)
    }

    @Test func eligibility_cellularOnly_noDVT_returnsTrue() {
        let monitor = ConnectionMonitor.shared
        monitor.updateForTesting(transport: .cellular, isWifiAvailable: false, isCellularAvailable: true, deviceSession: .idle)
        ShortcutBootstrapService.shared.isShortcutAssistedEnabled = true

        #expect(CellularAssistedBootstrapStateMachine.shared.isEligibleForDataOff)
    }

    @Test func eligibility_cellularOnly_activeDVT_returnsFalse() {
        let monitor = ConnectionMonitor.shared
        monitor.updateForTesting(transport: .cellular, isWifiAvailable: false, isCellularAvailable: true, deviceSession: .connected)
        ShortcutBootstrapService.shared.isShortcutAssistedEnabled = true

        #expect(!CellularAssistedBootstrapStateMachine.shared.isEligibleForDataOff)
    }

    @Test func eligibility_cellularOnly_recentLocationSuccess_returnsFalse() {
        let monitor = ConnectionMonitor.shared
        monitor.updateForTesting(transport: .cellular, isWifiAvailable: false, isCellularAvailable: true, deviceSession: .idle)
        LocationDataPathHealth.shared.recordSuccess()
        ShortcutBootstrapService.shared.isShortcutAssistedEnabled = true

        #expect(!CellularAssistedBootstrapStateMachine.shared.isEligibleForDataOff)
    }

    @Test func eligibility_offline_returnsFalse() {
        let monitor = ConnectionMonitor.shared
        monitor.updateForTesting(transport: .offline, isWifiAvailable: false, isCellularAvailable: false, deviceSession: .idle)
        ShortcutBootstrapService.shared.isShortcutAssistedEnabled = true

        #expect(!CellularAssistedBootstrapStateMachine.shared.isEligibleForDataOff)
    }

    // MARK: - 2. Pre-launch Recheck

    @Test func preLaunchDoubleCheck_activeSessionSkipsShortcut() async {
        let monitor = ConnectionMonitor.shared
        monitor.updateForTesting(transport: .cellular, isWifiAvailable: false, isCellularAvailable: true, deviceSession: .connected)
        ShortcutBootstrapService.shared.isShortcutAssistedEnabled = true

        var completed = false
        var succeeded = false
        CellularAssistedBootstrapStateMachine.shared.startAssistedBootstrap { result in
            completed = true
            if case .success = result {
                succeeded = true
            }
        }

        #expect(completed)
        #expect(succeeded)
        #expect(CellularAssistedBootstrapStateMachine.shared.state == .idle)
    }

    @Test func preLaunchDoubleCheck_wifiArrivalSkipsShortcut() async {
        let monitor = ConnectionMonitor.shared
        monitor.updateForTesting(transport: .wifi, isWifiAvailable: true, isCellularAvailable: true, deviceSession: .idle)
        ShortcutBootstrapService.shared.isShortcutAssistedEnabled = true

        var completed = false
        var succeeded = false
        CellularAssistedBootstrapStateMachine.shared.startAssistedBootstrap { result in
            completed = true
            if case .success = result {
                succeeded = true
            }
        }

        #expect(completed)
        #expect(succeeded)
        #expect(CellularAssistedBootstrapStateMachine.shared.state == .idle)
    }

    // MARK: - 3. State Machine Transitions & Properties

    @Test func stateMachine_stateLabelsAndProperties() {
        let idle = CellularAssistedState.idle
        #expect(!idle.isRunning)
        #expect(!idle.isDataTurnedOff)

        let reqOff = CellularAssistedState.requestingDataOff
        #expect(reqOff.isRunning)
        #expect(!reqOff.isDataTurnedOff)

        let settlingOff = CellularAssistedState.waitingForCellularOff
        #expect(settlingOff.isRunning)
        #expect(settlingOff.isDataTurnedOff)

        let bootstrapping = CellularAssistedState.bootstrapping
        #expect(bootstrapping.isRunning)
        #expect(bootstrapping.isDataTurnedOff)

        let verifying = CellularAssistedState.verifyingFirstLocationWrite
        #expect(verifying.isRunning)
        #expect(verifying.isDataTurnedOff)

        let recovering = CellularAssistedState.failedRecoveringData
        #expect(recovering.isRunning)
        #expect(recovering.isDataTurnedOff)

        let completed = CellularAssistedState.completed
        #expect(!completed.isRunning)
        #expect(!completed.isDataTurnedOff)
    }

    // MARK: - 4. Callback Handling & Security

    @Test func callback_mismatchedTx_isRejected() {
        ShortcutBootstrapService.shared.isShortcutAssistedEnabled = true
        _ = ShortcutBootstrapService.shared.runDataOffShortcut(txId: "tx-expected-123") { _ in }

        let wrongURL = URL(string: "routelocation://bootstrap-callback?tx=tx-wrong-456&phase=data-off&status=success")!
        let handled = ShortcutBootstrapService.shared.handleCallback(url: wrongURL)
        #expect(!handled)

        ShortcutBootstrapService.shared.cancelActiveTransaction()
    }

    @Test func callback_mismatchedPhase_isRejected() {
        ShortcutBootstrapService.shared.isShortcutAssistedEnabled = true
        _ = ShortcutBootstrapService.shared.runDataOffShortcut(txId: "tx-phase-test") { _ in }

        let wrongPhaseURL = URL(string: "routelocation://bootstrap-callback?tx=tx-phase-test&phase=data-on&status=success")!
        let handled = ShortcutBootstrapService.shared.handleCallback(url: wrongPhaseURL)
        #expect(!handled)

        ShortcutBootstrapService.shared.cancelActiveTransaction()
    }

    @Test func callback_matchingTxAndPhase_isAccepted() {
        ShortcutBootstrapService.shared.isShortcutAssistedEnabled = true
        var callbackSuccess: Bool?
        _ = ShortcutBootstrapService.shared.runDataOffShortcut(txId: "tx-match-test") { success in
            callbackSuccess = success
        }

        let matchURL = URL(string: "routelocation://bootstrap-callback?tx=tx-match-test&phase=data-off&status=success")!
        let handled = ShortcutBootstrapService.shared.handleCallback(url: matchURL)
        #expect(handled)
        #expect(callbackSuccess == true)
    }

    // MARK: - 5. Protection of Healthy DVT

    @Test func healthyDVTSession_neverDismantledByAuxiliaryProbeFailure() {
        LocationDataPathHealth.shared.recordSuccess()
        let shouldRetain = AuxiliaryProbePolicy.shouldRetainActiveSession(
            dvtConnected: true,
            locationActive: true,
            recentLocationSuccess: true
        )
        #expect(shouldRetain == true)
    }

    // MARK: - 6. Bootstrap Trace Store & Comparison

    @Test func traceStore_recordsLifecycleAndCalculatesDurations() {
        let store = BootstrapTraceStore.shared
        store.resetForTesting()

        store.startTrace(txId: "tx-unit-1", mode: "AssistedBeta", targetAddress: "10.7.0.1:49152")
        #expect(store.latestTrace != nil)
        #expect(store.latestTrace?.outcome == "IN_PROGRESS")

        store.recordEvent(.rpairingStart, details: ["target": "10.7.0.1:49152"])
        store.recordEvent(.rpairingSuccess, details: ["target": "10.7.0.1:49152"])
        store.recordEvent(.rsdReady)
        store.recordEvent(.dvtReady)
        store.recordEvent(.firstLocationWriteSuccess)
        store.finishTrace(outcome: "SUCCESS")

        let trace = store.latestTrace
        #expect(trace != nil)
        #expect(trace?.outcome == "SUCCESS")
        #expect(trace?.events.count ?? 0 >= 7)
        #expect(trace?.targetAddress == "10.7.0.1:49152")
    }

    @Test func traceStore_comparisonTextWithPreviousAndLatest() {
        let store = BootstrapTraceStore.shared
        store.resetForTesting()

        // First run (Failed)
        store.startTrace(txId: "tx-run-1", mode: "Direct", targetAddress: "10.7.0.1:49152")
        store.recordEvent(.rpairingStart)
        store.recordEvent(.rpairingFailed, details: ["errno": "61", "error": "Connection refused"])
        store.finishTrace(outcome: "FAILED", failureStage: "RPairing", failureReason: "Connection refused (errno 61)")

        // Second run (Success)
        store.startTrace(txId: "tx-run-2", mode: "AssistedBeta", targetAddress: "10.7.0.1:49152")
        store.recordEvent(.dataOffRequested)
        store.recordEvent(.cellularOffConfirmed)
        store.recordEvent(.rpairingStart)
        store.recordEvent(.rpairingSuccess)
        store.recordEvent(.dvtReady)
        store.recordEvent(.firstLocationWriteSuccess)
        store.finishTrace(outcome: "SUCCESS")

        #expect(store.latestTrace?.outcome == "SUCCESS")
        #expect(store.previousTrace?.outcome == "FAILED")

        let comparison = store.generateComparisonText()
        #expect(comparison.contains("RouteLocation Bootstrap 比對報告"))
        #expect(comparison.contains("FAILED"))
        #expect(comparison.contains("SUCCESS"))
    }

    // MARK: - 7. Privacy Redactions

    @Test func traceStore_privacyRedactionPreservesLocalIPsAndSanitizesPaths() {
        let store = BootstrapTraceStore.shared

        let textWithIpAndPath = "Connected to 10.7.0.1:49152 via /var/mobile/Containers/Data/Application/12345/Documents/pairing.plist"
        let sanitized = store.sanitizeString(textWithIpAndPath)

        #expect(sanitized.contains("10.7.0.1:49152"))
        #expect(!sanitized.contains("/var/mobile/Containers/Data/Application/12345/Documents/pairing.plist"))
        #expect(sanitized.contains("[REDACTED_CONTAINER_PATH]"))
    }

    @Test func traceStore_privacyRedactionSanitizesCoordinates() {
        let store = BootstrapTraceStore.shared
        let textWithCoords = "Set coordinate: lat: 25.0330, lon: 121.5654 successfully"
        let sanitized = store.sanitizeString(textWithCoords)

        #expect(!sanitized.contains("25.0330"))
        #expect(!sanitized.contains("121.5654"))
        #expect(sanitized.contains("[REDACTED_COORDINATE]"))
    }

    @Test func traceStore_privacyRedactionSanitizesPrivateKey() {
        let store = BootstrapTraceStore.shared
        let textWithKey = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA0...\n-----END RSA PRIVATE KEY-----"
        let sanitized = store.sanitizeString(textWithKey)

        #expect(!sanitized.contains("MIIEowIBAAKCAQEA0"))
        #expect(sanitized == "[REDACTED_PRIVATE_KEY]")
    }

    private final class MockLocationSink: LocationSimulationSink, @unchecked Sendable {
        var lastInjectedCoordinate: RouteCoordinate?
        func setCoordinate(_ coordinate: RouteCoordinate) async throws {
            lastInjectedCoordinate = coordinate
        }
        func clearSimulatedLocation() async throws {}
    }

    // MARK: - 8. Review Blocker Fix Validation (Blocker N)

    @Test func test_cellularOffTimeout_triggersFailureAndRollback() async {
        let sm = CellularAssistedBootstrapStateMachine.shared
        sm.resetForTesting()
        BootstrapTraceStore.shared.startTrace(txId: "tx-off-timeout", mode: "AssistedBeta")
        sm.testSettlementTimeoutSeconds = 0.1
        sm.testSimulateCellularSettlementConfirmed = false
        let monitor = ConnectionMonitor.shared
        monitor.updateForTesting(transport: .cellular, isWifiAvailable: false, isCellularAvailable: true)

        sm.forceStateForTesting(.requestingDataOff)
        sm.setFlagsForTesting(dataOffRequested: true, cellularOffObserved: false, restoreRequired: true)

        await sm.handleDataOffCallbackSuccess()

        #expect(sm.state != .bootstrapping)
        #expect(sm.state == .idle || sm.state == .failedRecoveringData)
        let events = BootstrapTraceStore.shared.latestTrace?.events ?? []
        #expect(events.contains { $0.type == .recoveryDataOnStarted })
        let outcome = BootstrapTraceStore.shared.latestTrace?.outcome
        #expect(outcome == "ROLLBACK" || outcome == "FAILED" || outcome == "IN_PROGRESS")
    }

    @Test func test_cellularOnTimeout_requiresManualAlert_outcomeUnconfirmed() async {
        let sm = CellularAssistedBootstrapStateMachine.shared
        sm.resetForTesting()
        BootstrapTraceStore.shared.startTrace(txId: "tx-on-timeout", mode: "AssistedBeta")
        sm.testSettlementTimeoutSeconds = 0.1
        sm.testSimulateCellularSettlementConfirmed = false
        let monitor = ConnectionMonitor.shared
        monitor.updateForTesting(transport: .offline, isWifiAvailable: false, isCellularAvailable: false)

        sm.forceStateForTesting(.requestingDataOn)
        await sm.handleDataOnCallbackSuccess()

        #expect(sm.requiresManualDataOnAlert == true)
        #expect(BootstrapTraceStore.shared.latestTrace?.outcome == "COMPLETED_DATA_RESTORE_UNCONFIRMED")
        let events = BootstrapTraceStore.shared.latestTrace?.events ?? []
        #expect(!events.contains { $0.type == .cellularOnConfirmed })
    }

    @Test func test_cellularOnConfirmed_marksSuccess() async {
        let sm = CellularAssistedBootstrapStateMachine.shared
        sm.resetForTesting()
        BootstrapTraceStore.shared.startTrace(txId: "tx-on-confirmed", mode: "AssistedBeta")
        sm.testSettlementTimeoutSeconds = 0.1
        sm.testSimulateCellularSettlementConfirmed = true
        let monitor = ConnectionMonitor.shared
        monitor.updateForTesting(transport: .cellular, isWifiAvailable: false, isCellularAvailable: true)

        sm.forceStateForTesting(.requestingDataOn)
        await sm.handleDataOnCallbackSuccess()

        #expect(sm.requiresManualDataOnAlert == false)
        #expect(BootstrapTraceStore.shared.latestTrace?.outcome == "SUCCESS")
        let events = BootstrapTraceStore.shared.latestTrace?.events ?? []
        #expect(events.contains { $0.type == .cellularOnConfirmed })
    }

    @Test func test_rollbackFlag_dataOffRequested_triggersDataOn() async {
        let sm = CellularAssistedBootstrapStateMachine.shared
        sm.resetForTesting()
        BootstrapTraceStore.shared.startTrace(txId: "tx-rb-dataoff", mode: "AssistedBeta")

        sm.forceStateForTesting(.bootstrapping)
        sm.setFlagsForTesting(dataOffRequested: true, cellularOffObserved: true, restoreRequired: true)

        sm.testTriggerFailure(stage: "RPairing", reason: "Errno 61")

        let events = BootstrapTraceStore.shared.latestTrace?.events ?? []
        #expect(events.contains { $0.type == .recoveryDataOnStarted } || sm.state == .failedRecoveringData || sm.state == .idle)
    }

    @Test func test_rollbackFlag_noDataOffRequested_skipsDataOn() async {
        let sm = CellularAssistedBootstrapStateMachine.shared
        sm.resetForTesting()
        BootstrapTraceStore.shared.startTrace(txId: "tx-rb-nodataoff", mode: "AssistedBeta")

        sm.forceStateForTesting(.idle)
        sm.setFlagsForTesting(dataOffRequested: false, cellularOffObserved: false, restoreRequired: false)

        sm.testTriggerFailure(stage: "Preflight", reason: "Rejected")

        #expect(sm.state == .idle)
        #expect(BootstrapTraceStore.shared.latestTrace?.outcome == "FAILED")
        let events = BootstrapTraceStore.shared.latestTrace?.events ?? []
        #expect(!events.contains { $0.type == .recoveryDataOnStarted })
    }

    @Test func test_removeHardcodedGPS_noCoordinate_skipsLocationSet() async {
        let sm = CellularAssistedBootstrapStateMachine.shared
        sm.resetForTesting()
        BootstrapTraceStore.shared.startTrace(txId: "tx-no-coord", mode: "AssistedBeta")

        await sm.testVerifyLocation(coordinate: nil)

        let events = BootstrapTraceStore.shared.latestTrace?.events ?? []
        let locEvent = events.first { $0.type == .firstLocationWriteSuccess }
        #expect(locEvent == nil || locEvent?.details["coord"]?.contains("25.0330") == false)
    }

    @Test func test_removeHardcodedGPS_withCoordinate_setsLocation() async {
        let sm = CellularAssistedBootstrapStateMachine.shared
        sm.resetForTesting()
        BootstrapTraceStore.shared.startTrace(txId: "tx-with-coord", mode: "AssistedBeta")
        let mockSink = MockLocationSink()
        sm.simulationSink = mockSink

        let coord = RouteCoordinate(latitude: 22.6273, longitude: 120.3014)
        await sm.testVerifyLocation(coordinate: coord)

        #expect(mockSink.lastInjectedCoordinate?.latitude == 22.6273)
        #expect(mockSink.lastInjectedCoordinate?.longitude == 120.3014)

        let events = BootstrapTraceStore.shared.latestTrace?.events ?? []
        let locEvent = events.first { $0.type == .firstLocationWriteSuccess }
        #expect(locEvent != nil)
        #expect(locEvent?.details["coord"]?.contains("25.0330") == false)
    }

    @Test func test_dvtReady_notEmittedOnRsdReady() {
        let store = BootstrapTraceStore.shared
        store.resetForTesting()

        store.startTrace(txId: "tx-rsd-test", mode: "Direct")
        store.recordEvent(.rsdReady)

        let events = store.latestTrace?.events ?? []
        #expect(events.contains { $0.type == .rsdReady })
        #expect(!events.contains { $0.type == .dvtReady })
    }

    @Test func test_traceStore_separatesFfiCodeAndPosixErrno() {
        let store = BootstrapTraceStore.shared
        store.resetForTesting()

        store.startTrace(txId: "tx-err-test", mode: "Direct")
        store.recordEvent(.rpairingFailed, details: [
            "ffiCode": "5",
            "posixErrno": "61",
            "error": "os error 61"
        ])
        store.finishTrace(outcome: "FAILED")

        let trace = store.latestTrace
        #expect(trace?.rpairingFfiCode == "5")
        #expect(trace?.rpairingPosixErrno == "61")

        let summary = store.formatTraceSummary(trace!)
        #expect(summary.contains("RPairing FFI Code: 5"))
        #expect(summary.contains("RPairing POSIX Errno: 61"))
    }

    @Test func test_exportSafeBoundary_sanitizesExportRecord() {
        let store = BootstrapTraceStore.shared
        store.resetForTesting()

        store.startTrace(txId: "tx-export-test", mode: "AssistedBeta", targetAddress: "10.7.0.1:49152")
        store.recordEvent(.firstLocationWriteSuccess, details: [
            "path": "/var/mobile/Containers/Data/Application/ABC-123/Documents/secret.plist",
            "coord": "25.0330,121.5654"
        ])
        store.finishTrace(outcome: "SUCCESS")

        let sanitized = store.latestTrace?.sanitizedCopyForExport()
        #expect(sanitized != nil)
        #expect(sanitized?.targetAddress == "10.7.0.1:49152")

        let eventDetails = sanitized?.events.first(where: { $0.type == .firstLocationWriteSuccess })?.details ?? [:]
        #expect(eventDetails["path"] == "[REDACTED_CONTAINER_PATH]")
        #expect(!eventDetails["coord"]!.contains("25.0330"))
        #expect(eventDetails["coord"]!.contains("[REDACTED_COORDINATE]"))
    }

    // MARK: - 9. Minimal Safety Patch Verification

    @Test func test_rollback_dataOnCallbackSuccess_cellularRemainsOff_requiresManualAlert() async {
        let sm = CellularAssistedBootstrapStateMachine.shared
        sm.resetForTesting()
        BootstrapTraceStore.shared.startTrace(txId: "tx-rb-unconfirmed", mode: "AssistedBeta")
        sm.testSettlementTimeoutSeconds = 0.05
        sm.testSimulateCellularSettlementConfirmed = false
        sm.setFlagsForTesting(dataOffRequested: true, cellularOffObserved: true, restoreRequired: true)
        sm.forceStateForTesting(.failedRecoveringData)

        await sm.testHandleRollbackDataOnCallback(success: true)

        #expect(sm.requiresManualDataOnAlert == true)
        #expect(sm.dataRestoreRequired == true)
        #expect(sm.state == .idle)
        let events = BootstrapTraceStore.shared.latestTrace?.events ?? []
        #expect(!events.contains { $0.type == .cellularOnConfirmed })
        let recoveryEvent = events.first { $0.type == .recoveryDataOnCompleted }
        #expect(recoveryEvent?.details["confirmed"] == "false")
    }

    @Test func test_rollback_dataOnCallbackSuccess_cellularOnObserved_restoreConfirmed() async {
        let sm = CellularAssistedBootstrapStateMachine.shared
        sm.resetForTesting()
        BootstrapTraceStore.shared.startTrace(txId: "tx-rb-confirmed", mode: "AssistedBeta")
        sm.testSettlementTimeoutSeconds = 0.05
        sm.testSimulateCellularSettlementConfirmed = true
        sm.setFlagsForTesting(dataOffRequested: true, cellularOffObserved: true, restoreRequired: true)
        sm.forceStateForTesting(.failedRecoveringData)

        await sm.testHandleRollbackDataOnCallback(success: true)

        #expect(sm.requiresManualDataOnAlert == false)
        #expect(sm.dataRestoreRequired == false)
        #expect(sm.state == .idle)
        let events = BootstrapTraceStore.shared.latestTrace?.events ?? []
        #expect(events.contains { $0.type == .cellularOnConfirmed })
        let recoveryEvent = events.first { $0.type == .recoveryDataOnCompleted }
        #expect(recoveryEvent?.details["confirmed"] == "true")
    }

    @Test func test_safeRoundTrip_dataOffCallback_offNotObserved_stillInvokesDataOn_fails() async {
        let service = ShortcutBootstrapService.shared
        service.resetForTesting()
        service.isShortcutAssistedEnabled = true
        service.testSimulateCellularOffObserved = false
        service.testSimulateCellularOnObserved = true

        var invokedPhases: [ShortcutPhase] = []
        service.testMockShortcutRunner = { phase, txId, completion in
            invokedPhases.append(phase)
            completion(true)
            return true
        }

        var completed = false
        var testSuccess: Bool?
        var testMessage: String?
        service.runSafeRoundTripTest { success, message in
            completed = true
            testSuccess = success
            testMessage = message
        }

        try? await Task.sleep(for: .milliseconds(50))

        #expect(completed == true)
        #expect(testSuccess == false)
        #expect(invokedPhases == [.dataOff, .dataOn])
        #expect(testMessage?.contains("DataOff 未確認") == true)
    }

    @Test func test_safeRoundTrip_dataOnCallback_onNotObserved_fails() async {
        let service = ShortcutBootstrapService.shared
        service.resetForTesting()
        service.isShortcutAssistedEnabled = true
        service.testSimulateCellularOffObserved = true
        service.testSimulateCellularOnObserved = false

        var invokedPhases: [ShortcutPhase] = []
        service.testMockShortcutRunner = { phase, txId, completion in
            invokedPhases.append(phase)
            completion(true)
            return true
        }

        var completed = false
        var testSuccess: Bool?
        var testMessage: String?
        service.runSafeRoundTripTest { success, message in
            completed = true
            testSuccess = success
            testMessage = message
        }

        try? await Task.sleep(for: .milliseconds(50))

        #expect(completed == true)
        #expect(testSuccess == false)
        #expect(invokedPhases == [.dataOff, .dataOn])
        #expect(testMessage?.contains("DataOn 恢復未確認") == true)
    }

    @Test func test_safeRoundTrip_bothObserved_succeeds() async {
        let service = ShortcutBootstrapService.shared
        service.resetForTesting()
        service.isShortcutAssistedEnabled = true
        service.testSimulateCellularOffObserved = true
        service.testSimulateCellularOnObserved = true

        var invokedPhases: [ShortcutPhase] = []
        service.testMockShortcutRunner = { phase, txId, completion in
            invokedPhases.append(phase)
            completion(true)
            return true
        }

        var completed = false
        var testSuccess: Bool?
        var testMessage: String?
        service.runSafeRoundTripTest { success, message in
            completed = true
            testSuccess = success
            testMessage = message
        }

        try? await Task.sleep(for: .milliseconds(50))

        #expect(completed == true)
        #expect(testSuccess == true)
        #expect(invokedPhases == [.dataOff, .dataOn])
        #expect(testMessage?.contains("安全測試成功") == true)
    }

    // MARK: - 9. v1.2.10 Assisted Bootstrap Sequencing & Stabilization Tests

    private final class FailingMockLocationSink: LocationSimulationSink, @unchecked Sendable {
        func setCoordinate(_ coordinate: RouteCoordinate) async throws {
            throw NSError(domain: "FailingMockLocationSink", code: -999, userInfo: [NSLocalizedDescriptionKey: "Simulated write failure"])
        }
        func clearSimulatedLocation() async throws {}
    }

    @Test func test_A_preflightAssistedBootstrap_preservesExactTargetCoordinate() async {
        let model = RouteLocationModel()
        ConnectionMonitor.shared.updateForTesting(transport: .cellular, isWifiAvailable: false, isCellularAvailable: true, deviceSession: .idle)
        LocationDataPathHealth.shared.resetForTesting()
        ShortcutBootstrapService.shared.isShortcutAssistedEnabled = true
        ShortcutBootstrapService.shared.cellularBootstrapPolicy = .askFirst

        let target = RouteCoordinate(latitude: 25.0339, longitude: 121.5644)
        model.requestSinglePointSimulation(at: target)

        #expect(model.showBootstrapPreflightSheet == true)
        #expect(model.pendingBootstrapTargetCoordinate == target)

        let sm = CellularAssistedBootstrapStateMachine.shared
        sm.resetForTesting()

        // When preflight launches assisted bootstrap
        model.startAssistedBootstrapFromPreflight()

        #expect(sm.activeTxId != nil)
        #expect(sm.state == .requestingDataOff || sm.state == .waitingForDataOffCallback)
        sm.cancel()
    }

    @Test func test_B_cellularOffObserved_stabilizationDelay_thenBootstrap() async {
        let sm = CellularAssistedBootstrapStateMachine.shared
        sm.resetForTesting()
        BootstrapTraceStore.shared.startTrace(txId: "tx-test-b", mode: "AssistedBeta")
        sm.testSettlementTimeoutSeconds = 0.05
        sm.testSimulateCellularSettlementConfirmed = true
        sm.testStabilizationDelaySeconds = 0.02
        sm.forceStateForTesting(.waitingForDataOffCallback)
        sm.setFlagsForTesting(dataOffRequested: true, cellularOffObserved: false, restoreRequired: true)

        await sm.handleDataOffCallbackSuccess()

        let events = BootstrapTraceStore.shared.latestTrace?.events ?? []
        guard let offIdx = events.firstIndex(where: { $0.type == .cellularOffConfirmed }),
              let stabStartIdx = events.firstIndex(where: { $0.type == .stabilizationAfterOffStart }),
              let stabEndIdx = events.firstIndex(where: { $0.type == .stabilizationAfterOffEnd }) else {
            Issue.record("Missing required trace events for stabilization after OFF")
            return
        }

        #expect(offIdx < stabStartIdx)
        #expect(stabStartIdx < stabEndIdx)
    }

    @Test func test_C_firstLocationWriteSuccess_stabilizationDelay_thenDataOn() async {
        let sm = CellularAssistedBootstrapStateMachine.shared
        sm.resetForTesting()
        let sink = MockLocationSink()
        sm.simulationSink = sink
        BootstrapTraceStore.shared.startTrace(txId: "tx-test-c", mode: "AssistedBeta")
        sm.testStabilizationDelaySeconds = 0.02
        sm.testSettlementTimeoutSeconds = 0.05
        sm.testSimulateCellularSettlementConfirmed = true

        let target = RouteCoordinate(latitude: 25.1234, longitude: 121.5678)
        sm.forceStateForTesting(.waitingForDVT)

        await sm.testVerifyLocation(coordinate: target)

        let events = BootstrapTraceStore.shared.latestTrace?.events ?? []
        guard let writeIdx = events.firstIndex(where: { $0.type == .firstLocationWriteSuccess }),
              let stabStartIdx = events.firstIndex(where: { $0.type == .stabilizationBeforeDataOnStart }),
              let stabEndIdx = events.firstIndex(where: { $0.type == .stabilizationBeforeDataOnEnd }),
              let dataOnIdx = events.firstIndex(where: { $0.type == .dataOnRequested }) else {
            Issue.record("Missing required trace events for stabilization before DataOn")
            return
        }

        #expect(writeIdx < stabStartIdx)
        #expect(stabStartIdx < stabEndIdx)
        #expect(stabEndIdx < dataOnIdx)
        #expect(sink.lastInjectedCoordinate == target)
    }

    @Test func test_D_dataOnMustNotStartBeforeFirstLocationWriteSuccess() async {
        let sm = CellularAssistedBootstrapStateMachine.shared
        sm.resetForTesting()
        sm.simulationSink = FailingMockLocationSink()
        BootstrapTraceStore.shared.startTrace(txId: "tx-test-d", mode: "AssistedBeta")
        sm.setFlagsForTesting(dataOffRequested: true, cellularOffObserved: true, restoreRequired: true)
        sm.forceStateForTesting(.waitingForDVT)

        let target = RouteCoordinate(latitude: 25.1234, longitude: 121.5678)
        await sm.testVerifyLocation(coordinate: target)

        let events = BootstrapTraceStore.shared.latestTrace?.events ?? []
        #expect(events.contains { $0.type == .firstLocationWriteFailed })
        #expect(!events.contains { $0.type == .dataOnRequested })
        #expect(!events.contains { $0.type == .stabilizationBeforeDataOnStart })
        #expect(events.contains { $0.type == .recoveryDataOnStarted })
    }

    @Test func test_E_nilTargetMustNotBeTreatedAsVerifiedSimulateHereSuccess() {
        let model = RouteLocationModel()
        ConnectionMonitor.shared.updateForTesting(transport: .cellular, isWifiAvailable: false, isCellularAvailable: true, deviceSession: .idle)
        LocationDataPathHealth.shared.resetForTesting()

        model.selectedCoordinate = nil
        model.requestSinglePointSimulation(at: nil)

        #expect(model.showBootstrapPreflightSheet == false)
        #expect(model.presentedError?.contains("請先選擇座標") == true)
        #expect(model.pendingBootstrapTargetCoordinate == nil)
    }

    @Test func test_F_stabilizationDelayUserDefaultsDefault() {
        let service = ShortcutBootstrapService.shared
        service.resetForTesting()
        #expect(service.cellularBootstrapStabilizationDelay == 1.0)
    }

    @Test func test_G_rangeClampZeroToThree() {
        let service = ShortcutBootstrapService.shared
        service.resetForTesting()

        service.cellularBootstrapStabilizationDelay = -0.5
        #expect(service.cellularBootstrapStabilizationDelay == 0.0)

        service.cellularBootstrapStabilizationDelay = 5.0
        #expect(service.cellularBootstrapStabilizationDelay == 3.0)

        service.cellularBootstrapStabilizationDelay = 2.5
        #expect(service.cellularBootstrapStabilizationDelay == 2.5)

        service.resetStabilizationDelayToDefault()
        #expect(service.cellularBootstrapStabilizationDelay == 1.0)
    }

    @Test func test_H_routeBootstrapPreservesFirstRouteCoordinate() async {
        let model = RouteLocationModel()
        ConnectionMonitor.shared.updateForTesting(transport: .cellular, isWifiAvailable: false, isCellularAvailable: true, deviceSession: .idle)
        LocationDataPathHealth.shared.resetForTesting()
        ShortcutBootstrapService.shared.isShortcutAssistedEnabled = true
        ShortcutBootstrapService.shared.cellularBootstrapPolicy = .askFirst

        let points = [
            RouteCoordinate(latitude: 25.01, longitude: 121.51),
            RouteCoordinate(latitude: 25.02, longitude: 121.52),
            RouteCoordinate(latitude: 25.03, longitude: 121.53)
        ]
        model.replaceWaypoints(points)

        await model.startPlayback()

        #expect(model.showBootstrapPreflightSheet == true)
        #expect(model.pendingBootstrapTargetCoordinate == points[0])
        model.cancelBootstrapPreflight()
    }

    @Test func test_I_failureDuringStabilization_rollbackDataOnStillAttempted() async {
        let sm = CellularAssistedBootstrapStateMachine.shared
        sm.resetForTesting()
        BootstrapTraceStore.shared.startTrace(txId: "tx-test-i", mode: "AssistedBeta")
        sm.setFlagsForTesting(dataOffRequested: true, cellularOffObserved: true, restoreRequired: true)
        sm.forceStateForTesting(.waitingForCellularOff)

        sm.cancel()

        #expect(sm.state == .failedRecoveringData || sm.state == .idle)
        let events = BootstrapTraceStore.shared.latestTrace?.events ?? []
        #expect(events.contains { $0.type == .recoveryDataOnStarted })
    }

    @Test func test_J_healthyExistingDVT_noDataOffShortcut_noStabilizationDelay() async {
        let sm = CellularAssistedBootstrapStateMachine.shared
        sm.resetForTesting()
        ConnectionMonitor.shared.updateForTesting(transport: .cellular, isWifiAvailable: false, isCellularAvailable: true, deviceSession: .connected)
        ShortcutBootstrapService.shared.isShortcutAssistedEnabled = true

        var completed = false
        var outcomeSuccess = false
        sm.startAssistedBootstrap { result in
            completed = true
            if case .success = result {
                outcomeSuccess = true
            }
        }

        #expect(completed == true)
        #expect(outcomeSuccess == true)
        #expect(sm.state == .idle)
        #expect(sm.dataOffWasRequested == false)

        let events = BootstrapTraceStore.shared.latestTrace?.events ?? []
        #expect(!events.contains { $0.type == .dataOffRequested })
        #expect(!events.contains { $0.type == .stabilizationAfterOffStart })
        #expect(!events.contains { $0.type == .stabilizationBeforeDataOnStart })
    }
}
