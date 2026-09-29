//
//  BootstrapCoordinator.swift
//  StikDebug
//
//  Created for RouteLocation v1.2.11 Architecture Coordination Layer.
//

import Combine
import Foundation

enum BootstrapProceedDisposition: String, Codable, Equatable {
    case needsLocationWrite
    case locationAlreadyWritten
}

@MainActor
final class BootstrapCoordinator: ObservableObject {
    static let shared = BootstrapCoordinator()

    @Published private(set) var isCoordinating = false
    @Published private(set) var lastFallbackOccurred = false
    @Published private(set) var lastCoordinationPath: String = "idle"

    private init() {}

    // MARK: - Simulation Request Coordination

    func coordinateSimulation(
        targetCoordinate: RouteCoordinate?,
        onRequestPreflight: @escaping @MainActor () -> Void,
        onProceed: @escaping @MainActor (BootstrapProceedDisposition) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        let monitor = ConnectionMonitor.shared
        let health = LocationDataPathHealth.shared

        // 1. Evidence Hierarchy Rule #1: Existing healthy DVT / recent success /
        // a queue-owned prepared LocationSimulation handle have absolute priority.
        // The snapshot is read through the same serial queue that owns the FFI
        // handles; never inspect LocationSimulationState directly on MainActor.
        let preparedSnapshot = LocationSimulationCommandQueue.shared.sync {
            location_simulation_session_snapshot()
        }
        let hasHealthySession = monitor.activeDVTSessionAvailable || health.hasRecentSuccess || preparedSnapshot.isPrepared
        if hasHealthySession {
            lastCoordinationPath = preparedSnapshot.isPrepared && !monitor.activeDVTSessionAvailable && !health.hasRecentSuccess
                ? "prepared_session_direct"
                : "healthy_session_direct"
            LogManager.shared.addInfoLog("BootstrapCoordinator: Existing DVT/location session evidence is healthy. Proceeding with needsLocationWrite.")
            onProceed(.needsLocationWrite)
            return
        }

        // 2. Wi-Fi interface detected or offline: no cellular bootstrap needed
        if monitor.isWifiAvailable || monitor.currentTransport == .wifi {
            lastCoordinationPath = "wifi_direct"
            LogManager.shared.addInfoLog("BootstrapCoordinator: Wi-Fi interface active. Skipping cellular bootstrap.")
            onProceed(.needsLocationWrite)
            return
        }

        // 3. Check Policy
        let policy = ShortcutBootstrapService.shared.cellularBootstrapPolicy
        switch policy {
        case .directOnly:
            attemptProductionDirect(
                targetCoordinate: targetCoordinate,
                policy: .directOnly,
                onRequestPreflight: onRequestPreflight,
                onProceed: onProceed,
                onError: onError
            )

        case .assistedFirst:
            // "每次詢問" (Always Ask) mode
            lastCoordinationPath = "policy_always_ask_preflight"
            onRequestPreflight()

        case .auto:
            // "自動（建議）"
            let isCellular = monitor.currentTransport == .cellular || monitor.isCellularAvailable
            guard isCellular else {
                lastCoordinationPath = "non_cellular_direct"
                onProceed(.needsLocationWrite)
                return
            }

            #if DEBUG
            // Compatibility for historical unit-test seams only. The real
            // application never gates Auto on the Research Beta toggle.
            if DirectCellularResearchService.shared.isBetaEnabled,
               testMockResearchRunner != nil || DirectCellularResearchService.shared.testMockDirectAttempt != nil {
                lastCoordinationPath = "research_beta_direct_attempt"
                attemptResearchBetaWithFallback(
                    targetCoordinate: targetCoordinate,
                    onRequestPreflight: onRequestPreflight,
                    onProceed: onProceed,
                    onError: onError
                )
                return
            }
            #endif

            attemptProductionDirect(
                targetCoordinate: targetCoordinate,
                policy: .auto,
                onRequestPreflight: onRequestPreflight,
                onProceed: onProceed,
                onError: onError
            )
        }
    }

    // MARK: - Production Direct Preparation

    private func attemptProductionDirect(
        targetCoordinate: RouteCoordinate?,
        policy: CellularBootstrapPolicy,
        onRequestPreflight: @escaping @MainActor () -> Void,
        onProceed: @escaping @MainActor (BootstrapProceedDisposition) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        isCoordinating = true
        lastFallbackOccurred = false

        let monitor = ConnectionMonitor.shared
        let mode = BootstrapEndpointStrategy.storedMode()
        guard let endpoint = BootstrapEndpointStrategy.resolvedAddress(mode: mode, transport: monitor.currentTransport) else {
            isCoordinating = false
            lastCoordinationPath = "production_direct_invalid_endpoint"
            onError(NSError(domain: "RouteLocation.Bootstrap", code: -301, userInfo: [
                NSLocalizedDescriptionKey: L10n.text("設定的 Bootstrap IPv4 位址無效。")
            ]))
            return
        }

        let pairingPath = PairingFileStore.prepareURL().path
        let endpointLabel = "\(endpoint):\(BootstrapEndpointStrategy.port)"
        lastCoordinationPath = policy == .auto ? "production_auto_direct_attempt" : "production_direct_only_attempt"
        LogManager.shared.addInfoLog("BootstrapCoordinator: Preparing production location session at \(endpointLabel) (policy=\(policy.rawValue)).")

        ProductionLocationSessionPreparer.shared.prepare(endpointAddress: endpoint, pairingFile: pairingPath) { [weak self] result in
            guard let self else { return }
            if result.isSuccess {
                self.isCoordinating = false
                self.lastCoordinationPath = policy == .auto ? "production_auto_direct_success" : "production_direct_only_success"
                LogManager.shared.addInfoLog("BootstrapCoordinator: Production location session retained at \(endpointLabel).")
                onProceed(.needsLocationWrite)
                return
            }

            let description = result.message ?? "\(result.stage.rawValue) preparation failed"
            LogManager.shared.addWarningLog("BootstrapCoordinator: Production preparation failed at \(result.stage.rawValue): \(description)")
            guard policy == .auto else {
                self.isCoordinating = false
                self.lastCoordinationPath = "production_direct_only_failed"
                onError(NSError(domain: "RouteLocation.Bootstrap", code: Int(result.statusCode), userInfo: [
                    NSLocalizedDescriptionKey: description
                ]))
                return
            }

            // Auto fallback is deliberately one-shot. The existing assisted
            // state machine owns DataOff/DataOn and coordinate verification.
            self.lastFallbackOccurred = true
            self.lastCoordinationPath = "production_direct_failed_assisted_fallback"
            if ShortcutBootstrapService.shared.isShortcutAssistedEnabled {
                self.executeAssistedBootstrap(targetCoordinate: targetCoordinate, onProceed: onProceed, onError: onError)
            } else {
                self.isCoordinating = false
                onRequestPreflight()
            }
        }
    }

    // MARK: - Research Beta Attempt & Fallback

    private func attemptResearchBetaWithFallback(
        targetCoordinate: RouteCoordinate?,
        onRequestPreflight: @escaping @MainActor () -> Void,
        onProceed: @escaping @MainActor (BootstrapProceedDisposition) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        isCoordinating = true
        lastFallbackOccurred = false

        #if DEBUG
        if let mock = testMockResearchRunner {
            mock(targetCoordinate) { [weak self] success in
                guard let self else { return }
                if success {
                    self.isCoordinating = false
                    BootstrapTraceStore.shared.finishTrace(outcome: "RESEARCH_DIRECT_TUNNEL_SUCCESS")
                    onProceed(.needsLocationWrite)
                } else {
                    self.lastFallbackOccurred = true
                    LogManager.shared.addWarningLog("BootstrapCoordinator: Research beta failed in mock. Falling back.")
                    BootstrapTraceStore.shared.recordEvent(.fallbackToAssisted, details: ["reason": "ResearchDirectAttemptFailed"])
                    BootstrapTraceStore.shared.finishTrace(
                        outcome: "RESEARCH_FAILED_FALLBACK",
                        failureStage: "ResearchDirect",
                        failureReason: "Research direct attempt failed"
                    )

                    if ShortcutBootstrapService.shared.isShortcutAssistedEnabled {
                        self.executeAssistedBootstrap(targetCoordinate: targetCoordinate, onProceed: onProceed, onError: onError)
                    } else {
                        self.lastCoordinationPath = "research_fail_shortcut_disabled_preflight"
                        self.isCoordinating = false
                        onRequestPreflight()
                    }
                }
            }
            return
        }
        #endif

        DirectCellularResearchService.shared.performResearchDirectAttempt(targetCoordinate: targetCoordinate) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.isCoordinating = false
                LogManager.shared.addInfoLog("BootstrapCoordinator: Direct Cellular Research Beta SUCCEEDED. Proceeding with needsLocationWrite.")
                onProceed(.needsLocationWrite)

            case .failure(let error):
                self.lastFallbackOccurred = true
                LogManager.shared.addWarningLog("BootstrapCoordinator: Direct Cellular Research Beta failed (\(error.localizedDescription)). Preserving trace and falling back.")
                BootstrapTraceStore.shared.recordEvent(.fallbackToAssisted, details: [
                    "reason": "ResearchDirectAttemptFailed",
                    "error": error.localizedDescription
                ])
                BootstrapTraceStore.shared.finishTrace(
                    outcome: "RESEARCH_FAILED_FALLBACK",
                    failureStage: "ResearchDirect",
                    failureReason: error.localizedDescription
                )

                if ShortcutBootstrapService.shared.isShortcutAssistedEnabled {
                    self.executeAssistedBootstrap(
                        targetCoordinate: targetCoordinate,
                        onProceed: onProceed,
                        onError: onError
                    )
                } else {
                    self.lastCoordinationPath = "research_fail_shortcut_disabled_preflight"
                    LogManager.shared.addInfoLog("BootstrapCoordinator: Research failed and shortcut disabled. Falling back to preflight.")
                    self.isCoordinating = false
                    onRequestPreflight()
                }
            }
        }
    }

    // MARK: - One-Tap Assisted Bootstrap

    func executeAssistedBootstrap(
        targetCoordinate: RouteCoordinate?,
        onProceed: @escaping @MainActor (BootstrapProceedDisposition) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        isCoordinating = true
        #if DEBUG
        if let mock = testMockAssistedRunner {
            mock(targetCoordinate) { [weak self] result in
                guard let self else { return }
                self.isCoordinating = false
                switch result {
                case .success(let disposition):
                    onProceed(disposition)
                case .failure(let err):
                    onError(err)
                }
            }
            return
        }
        #endif

        CellularAssistedBootstrapStateMachine.shared.startAssistedBootstrap(targetCoordinate: targetCoordinate) { [weak self] result in
            guard let self else { return }
            self.isCoordinating = false
            switch result {
            case .success(let disposition):
                LogManager.shared.addInfoLog("BootstrapCoordinator: Assisted bootstrap completed successfully (disposition: \(disposition.rawValue)).")
                onProceed(disposition)
            case .failure(let err):
                LogManager.shared.addErrorLog("BootstrapCoordinator: Assisted bootstrap failed: \(err.localizedDescription)")
                onError(err)
            }
        }
    }

    // MARK: - Testing Seams

    #if DEBUG
    var testMockResearchRunner: ((RouteCoordinate?, @escaping (Bool) -> Void) -> Void)?
    var testMockAssistedRunner: ((RouteCoordinate?, @escaping (Result<BootstrapProceedDisposition, Error>) -> Void) -> Void)?

    func resetForTesting() {
        isCoordinating = false
        lastFallbackOccurred = false
        lastCoordinationPath = "idle"
        testMockResearchRunner = nil
        testMockAssistedRunner = nil
        ProductionLocationSessionPreparer.shared.resetForTesting()
    }
    #endif
}
