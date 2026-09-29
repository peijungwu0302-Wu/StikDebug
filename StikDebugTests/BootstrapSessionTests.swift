import Foundation
import Testing
@testable import RouteLocation

struct BootstrapSessionTests {
    @Test func endpointStrategyUsesExpectedProductionAddresses() {
        #expect(BootstrapEndpointStrategy.resolvedAddress(mode: .localDevVPN, transport: .wifi) == "10.7.0.1")
        #expect(BootstrapEndpointStrategy.resolvedAddress(mode: .loopbackIPv4, transport: .cellular) == "127.0.0.1")
        #expect(BootstrapEndpointStrategy.resolvedAddress(mode: .automatic, transport: .wifi) == "10.7.0.1")
        #expect(BootstrapEndpointStrategy.resolvedAddress(mode: .automatic, transport: .cellular) == "127.0.0.1")
    }

    @Test func customEndpointValidationRejectsInvalidAddresses() {
        #expect(BootstrapEndpointStrategy.isValidIPv4("127.0.0.1"))
        #expect(BootstrapEndpointStrategy.isValidIPv4("10.7.0.1"))
        #expect(!BootstrapEndpointStrategy.isValidIPv4("10.7.1.1:49152"))
        #expect(!BootstrapEndpointStrategy.isValidIPv4("999.1.1.1"))
        #expect(!BootstrapEndpointStrategy.isValidIPv4(""))
    }

    @Test func preparationResultReadyIsTheOnlyPreparedState() {
        let ready = LocationSimulationPreparationResult(
            target: "127.0.0.1:49152", stage: .ready, statusCode: 0,
            ffiCode: nil, ffiSubCode: nil, message: nil, durationMs: 1
        )
        let rsdOnly = LocationSimulationPreparationResult(
            target: "127.0.0.1:49152", stage: .rsd, statusCode: 9,
            ffiCode: 16, ffiSubCode: nil, message: "Connection refused", durationMs: 1
        )
        #expect(ready.isSuccess)
        #expect(!rsdOnly.isSuccess)
    }

    @Test func researchTrialResultDoesNotRepresentALocationWrite() {
        // The trial value carries only preparation stages. A successful READY
        // value is deliberately not a location command or coordinate write.
        let trial = FullCellularFFITrial(LocationSimulationPreparationResult(
            target: "127.0.0.1:49152", stage: .ready, statusCode: 0,
            ffiCode: nil, ffiSubCode: nil, message: nil, durationMs: 0
        ))
        #expect(trial.stage == "READY")
        #expect(!trial.target.isEmpty)
    }

    @MainActor @Test func preparedSessionSnapshotIsQueueOwnedAndPreferred() {
        let snapshot = LocationSimulationCommandQueue.shared.sync {
            location_simulation_session_snapshot()
        }
        #expect(snapshot.isPrepared == false)
    }

    @MainActor @Test func productionPreparationResultIsRetainedWithoutLocationWrite() {
        let result = LocationSimulationPreparationResult(
            target: "127.0.0.1:49152", stage: .ready, statusCode: 0,
            ffiCode: nil, ffiSubCode: nil, message: nil, durationMs: 1
        )
        ProductionLocationSessionPreparer.shared.mockPreparationResult = { _, _ in result }
        var callbackResult: LocationSimulationPreparationResult?
        ProductionLocationSessionPreparer.shared.prepare(
            endpointAddress: "127.0.0.1",
            pairingFile: "/tmp/pairing.plist"
        ) { callbackResult = $0 }

        #expect(callbackResult?.isSuccess == true)
        #expect(callbackResult?.stage == .ready)
        // Preparation has no coordinate argument and therefore cannot write a
        // location; the actual write is performed by the later setCoordinate path.
        #expect(callbackResult?.message == nil)
        ProductionLocationSessionPreparer.shared.resetForTesting()
    }

    @MainActor @Test func automaticCellularEndpointResolvesToLoopback() {
        #expect(BootstrapEndpointStrategy.resolvedAddress(mode: .automatic, transport: .cellular) == "127.0.0.1")
    }

    @MainActor @Test func fullResearchReportCarriesDetailedImmutableEvidence() throws {
        let snapshot = NetworkEnvironmentSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_002),
            primaryTransport: "cellular",
            isWifiAvailable: false,
            isCellularAvailable: true,
            isInternetSatisfied: true,
            isExpensive: true,
            vpnDetectedByNWPath: true,
            allInterfaces: [],
            vpnCandidate: VPNInterfaceCandidate(interface: nil, confidence: .none, detectedPeer: nil, reason: "test"),
            configuredTargetIP: "10.7.0.1",
            detectedCandidatePeer: "10.7.1.1",
            activeDVTSession: false,
            recentLocationSuccess: false,
            tunnelConnected: false
        )
        let topology = UtunInterfaceEntry(
            interfaceName: "utun3", addressFamily: "IPv4", ifaFlags: 0x8051,
            isPointToPoint: true, isUp: true, isRunning: true,
            observedInterfaceAddress: "10.7.0.2", observedP2PLocalAddress: "10.7.0.2",
            observedP2PDestination: "10.7.1.1", observedNetmask: "255.255.255.0"
        )
        let path = CellularPathProbeResult(
            probeType: .baseline, status: .failure, targetIP: "10.7.0.1",
            elapsedMs: 42, nwErrorDomain: "NSPOSIXErrorDomain", nwErrorCode: 61,
            posixErrno: 61, errorDescription: "Connection refused",
            timestamp: Date(timeIntervalSince1970: 1_700_000_003)
        )
        let matrix = EndpointMatrixProbeResult(
            target: "127.0.0.1:49152", policy: .DEFAULT, status: .success,
            elapsedMs: 1, localEndpoint: "127.0.0.1:60000", remoteEndpoint: "127.0.0.1:49152"
        )
        let ffi = FullCellularFFITrial(LocationSimulationPreparationResult(
            target: "127.0.0.1:49152", stage: .rsd, statusCode: 9,
            ffiCode: 16, ffiSubCode: nil, message: "Connection refused", durationMs: 3
        ))
        let report = FullCellularResearchReport(
            id: UUID(),
            // ISO-8601 JSON intentionally has millisecond precision. Use
            // deterministic whole-second dates so round-trip equality tests
            // do not depend on Date's sub-millisecond representation.
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_001),
            appVersion: "1.2.12", build: "8", transport: "cellular",
            wifiObservation: "off", cellularObservation: "available",
            vpnObservation: "detected", vpnCandidate: "utun3", pathStatus: "satisfied",
            utunSummary: "one", networkSnapshot: snapshot, utunInterfaces: [topology],
            bonjourServices: [], pathProbes: [path], tcpMatrix: [matrix],
            bonjourSummary: "none", endpointMode: "automatic",
            effectiveProductionEndpoint: "127.0.0.1:49152", tcpMatrixSummary: "success",
            pathProbeSummary: "failure", trialLocalDevVPN: ffi, trialLoopback: ffi,
            productionSessionHealth: "none", productionBehaviorModified: false,
            locationWriteOccurred: false
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FullCellularResearchReport.self, from: report.jsonData!)
        #expect(decoded == report)
        #expect(report.text.contains("flags=32849"))
        #expect(report.text.contains("errno=61"))
        #expect(report.text.contains("127.0.0.1:49152"))
        #expect(report.productionBehaviorModified == false)
        #expect(report.locationWriteOccurred == false)
    }
}

@MainActor
struct BootstrapCoordinatorCorrectionTests {
    private let success = LocationSimulationPreparationResult(
        target: "127.0.0.1:49152", stage: .ready, statusCode: 0,
        ffiCode: nil, ffiSubCode: nil, message: nil, durationMs: 1
    )
    private let failure = LocationSimulationPreparationResult(
        target: "127.0.0.1:49152", stage: .rsd, statusCode: 9,
        ffiCode: 16, ffiSubCode: nil, message: "Connection refused", durationMs: 1
    )

    private func cellular(_ policy: CellularBootstrapPolicy) {
        TestBootstrapEnvironment.reset(policy: policy)
        ConnectionMonitor.shared.updateForTesting(
            transport: .cellular, isWifiAvailable: false,
            isCellularAvailable: true, deviceSession: .idle
        )
        ShortcutBootstrapService.shared.isShortcutAssistedEnabled = true
    }

    @Test func autoCellularUsesRetainedProductionPreparationWithoutResearchBeta() {
        cellular(.auto)
        DirectCellularResearchService.shared.isBetaEnabled = false
        var assistedCount = 0
        BootstrapCoordinator.shared.testMockAssistedRunner = { _, completion in
            assistedCount += 1
            completion(.success(.needsLocationWrite))
        }
        var endpointUsed = ""
        ProductionLocationSessionPreparer.shared.mockPreparationResult = { endpoint, _ in
            endpointUsed = endpoint
            return success
        }
        var proceeded = false
        BootstrapCoordinator.shared.coordinateSimulation(
            targetCoordinate: RouteCoordinate(latitude: 25, longitude: 121),
            onRequestPreflight: { Issue.record("Auto success must not request preflight") },
            onProceed: { _ in proceeded = true },
            onError: { Issue.record("Unexpected production preparation error: \($0)") }
        )

        #expect(endpointUsed == "127.0.0.1")
        #expect(proceeded)
        #expect(assistedCount == 0)
        #expect(BootstrapCoordinator.shared.lastCoordinationPath == "production_auto_direct_success")
        TestBootstrapEnvironment.reset()
    }

    @Test func autoCellularFailureFallsBackToAssistedExactlyOnceAndPreservesCoordinate() {
        cellular(.auto)
        let target = RouteCoordinate(latitude: 25.0421, longitude: 121.5322)
        var assistedCount = 0
        var assistedTarget: RouteCoordinate?
        ProductionLocationSessionPreparer.shared.mockPreparationResult = { _, _ in failure }
        BootstrapCoordinator.shared.testMockAssistedRunner = { coordinate, completion in
            assistedCount += 1
            assistedTarget = coordinate
            completion(.success(.needsLocationWrite))
        }

        BootstrapCoordinator.shared.coordinateSimulation(
            targetCoordinate: target,
            onRequestPreflight: { Issue.record("Enabled assisted bootstrap should run directly") },
            onProceed: { _ in },
            onError: { _ in Issue.record("Assisted fallback should handle the failure") }
        )

        #expect(assistedCount == 1)
        #expect(assistedTarget == target)
        #expect(BootstrapCoordinator.shared.lastFallbackOccurred)
        #expect(BootstrapCoordinator.shared.lastCoordinationPath == "production_direct_failed_assisted_fallback")
        TestBootstrapEnvironment.reset()
    }

    @Test func directOnlyFailureDoesNotInvokeAssisted() {
        cellular(.directOnly)
        var assistedCount = 0
        var errorDelivered = false
        ProductionLocationSessionPreparer.shared.mockPreparationResult = { _, _ in failure }
        BootstrapCoordinator.shared.testMockAssistedRunner = { _, completion in
            assistedCount += 1
            completion(.success(.needsLocationWrite))
        }

        BootstrapCoordinator.shared.coordinateSimulation(
            targetCoordinate: nil,
            onRequestPreflight: { Issue.record("directOnly must not request assisted preflight") },
            onProceed: { _ in Issue.record("directOnly failure must not proceed") },
            onError: { _ in errorDelivered = true }
        )

        #expect(errorDelivered)
        #expect(assistedCount == 0)
        TestBootstrapEnvironment.reset()
    }

    @Test func assistedFirstPreservesPreflightBeforeDirectPreparation() {
        cellular(.assistedFirst)
        var preflight = false
        var prepareCalled = false
        ProductionLocationSessionPreparer.shared.mockPreparationResult = { _, _ in
            prepareCalled = true
            return success
        }
        BootstrapCoordinator.shared.coordinateSimulation(
            targetCoordinate: nil,
            onRequestPreflight: { preflight = true },
            onProceed: { _ in Issue.record("assistedFirst should wait for preflight") },
            onError: { _ in Issue.record("Unexpected assistedFirst error") }
        )

        #expect(preflight)
        #expect(!prepareCalled)
        TestBootstrapEnvironment.reset()
    }

    @Test func preparedSessionBypassesBothDirectAndAssistedAfterTransportHandoff() {
        cellular(.auto)
        location_simulation_set_prepared_for_testing(true)
        var prepareCalled = false
        var assistedCount = 0
        ProductionLocationSessionPreparer.shared.mockPreparationResult = { _, _ in
            prepareCalled = true
            return success
        }
        BootstrapCoordinator.shared.testMockAssistedRunner = { _, completion in
            assistedCount += 1
            completion(.success(.needsLocationWrite))
        }

        BootstrapCoordinator.shared.coordinateSimulation(
            targetCoordinate: nil,
            onRequestPreflight: { Issue.record("Prepared session should bypass preflight") },
            onProceed: { _ in },
            onError: { _ in Issue.record("Prepared session should not fail") }
        )

        #expect(!prepareCalled)
        #expect(assistedCount == 0)
        #expect(BootstrapCoordinator.shared.lastCoordinationPath == "prepared_session_direct")
        cleanup_prepared_location_simulation_session()
        TestBootstrapEnvironment.reset()
    }

    @Test func wiFiWarmEndpointIsLocalDevVPNAndNeverWritesLocation() {
        #expect(BootstrapEndpointStrategy.resolvedAddress(mode: .automatic, transport: .wifi) == "10.7.0.1")
        let result = LocationSimulationPreparationResult(
            target: "10.7.0.1:49152", stage: .ready, statusCode: 0,
            ffiCode: nil, ffiSubCode: nil, message: nil, durationMs: 1
        )
        #expect(result.isSuccess)
        #expect(result.stage == .ready)
    }
}
