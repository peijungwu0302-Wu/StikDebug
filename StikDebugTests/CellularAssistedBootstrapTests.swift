import Testing
import Foundation
@testable import RouteLocation

@MainActor
struct CellularAssistedBootstrapTests {

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
}
