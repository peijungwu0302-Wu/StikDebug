//
//  CellularBootstrapDiagnosisTests.swift
//  StikDebugTests
//
//  Created for RouteLocation Cellular Bootstrap Transport Spike.
//

import Testing
import Foundation
@testable import StikDebug

struct CellularBootstrapDiagnosisTests {

    private func makeBaseSnapshot(
        activeDVT: Bool = false,
        recentLocationSuccess: Bool = false,
        tunnelConnected: Bool = false,
        primaryTransport: String = "cellular",
        isWifiAvailable: Bool = false,
        isCellularAvailable: Bool = true,
        isInternetSatisfied: Bool = true,
        vpnCandidate: VPNInterfaceCandidate = VPNInterfaceCandidate(
            interface: NetworkInterfaceInfo(
                id: "utun0-5",
                name: "utun0",
                index: 5,
                nwInterfaceType: "tunnel/vpn",
                addresses: ["10.7.0.2"],
                destinationAddresses: ["10.7.0.1"],
                isPointToPoint: true,
                isUp: true,
                isLoopback: false,
                isTunnelLike: true
            ),
            confidence: .confident,
            detectedPeer: "10.7.0.1",
            reason: "Single active utun interface with 10.7.x.x"
        ),
        configuredTargetIP: String = "10.7.0.1",
        configuredTargetPort: Int = 49152
    ) -> NetworkEnvironmentSnapshot {
        NetworkEnvironmentSnapshot(
            primaryTransport: primaryTransport,
            isWifiAvailable: isWifiAvailable,
            isCellularAvailable: isCellularAvailable,
            isInternetSatisfied: isInternetSatisfied,
            isExpensive: true,
            vpnDetectedByNWPath: true,
            allInterfaces: vpnCandidate.interface.map { [$0] } ?? [],
            vpnCandidate: vpnCandidate,
            configuredTargetIP: configuredTargetIP,
            configuredTargetPort: configuredTargetPort,
            detectedCandidatePeer: vpnCandidate.detectedPeer,
            activeDVTSession: activeDVT,
            recentLocationSuccess: recentLocationSuccess,
            tunnelConnected: tunnelConnected
        )
    }

    // MARK: - Rule A: Active Session or Recent Success

    @Test func ruleA_activeDVTSession_yieldsExistingSessionHealthy() {
        let snapshot = makeBaseSnapshot(activeDVT: true, recentLocationSuccess: false)
        let report = CellularBootstrapDiagnosisEngine.evaluate(
            snapshot: snapshot,
            probeA: nil,
            probeB: nil,
            probeC: nil
        )

        #expect(report.verdict == .EXISTING_SESSION_HEALTHY)
        #expect(report.confidence == .high)
        #expect(report.recommendedNextStep.contains("保持現有連線"))
    }

    @Test func ruleA_recentLocationSuccess_yieldsExistingSessionHealthy() {
        let snapshot = makeBaseSnapshot(activeDVT: false, recentLocationSuccess: true)
        let report = CellularBootstrapDiagnosisEngine.evaluate(
            snapshot: snapshot,
            probeA: nil,
            probeB: nil,
            probeC: nil
        )

        #expect(report.verdict == .EXISTING_SESSION_HEALTHY)
        #expect(report.confidence == .high)
    }

    // MARK: - Rule B & F: Probe A fails, Probe C succeeds on Prebuilt FFI

    @Test func ruleB_and_ruleF_defaultFailsAndRequiredSucceeds_prebuiltFFI_yieldsDiagnosticProbeOnlySuccess() {
        let snapshot = makeBaseSnapshot(activeDVT: false, recentLocationSuccess: false)

        let probeA = CellularPathProbeResult(
            probeType: .baseline,
            status: .failure,
            selectedInterfaceName: "pdp_ip0",
            elapsedMs: 250,
            posixErrno: 61,
            errorDescription: "Connection refused"
        )
        let probeB = CellularPathProbeResult(
            probeType: .cellularProhibited,
            status: .failure,
            posixErrno: 51,
            errorDescription: "Network is unreachable"
        )
        let probeC = CellularPathProbeResult(
            probeType: .requiredInterface,
            status: .success,
            selectedInterfaceName: "utun0",
            localEndpoint: "10.7.0.2:54321",
            remoteEndpoint: "10.7.0.1:49152",
            elapsedMs: 15
        )

        let report = CellularBootstrapDiagnosisEngine.evaluate(
            snapshot: snapshot,
            probeA: probeA,
            probeB: probeB,
            probeC: probeC
        )

        #expect(report.verdict == .DIAGNOSTIC_PROBE_ONLY_SUCCESS)
        #expect(report.confidence == .high)
        #expect(report.interpretation.contains("VPN-bound TCP connectivity is proven, but this does not prove that tunnel_create_rppairing uses the same interface."))
        #expect(report.recommendedNextStep.contains("TRUE_FFI_INTERFACE_BINDING"))
    }

    // MARK: - Rule C: Target or Peer Mismatch

    @Test func ruleC_configuredTargetMismatchesDerivedPeer_yieldsTargetOrPeerMismatch() {
        let vpnCandidate = VPNInterfaceCandidate(
            interface: NetworkInterfaceInfo(
                id: "utun0-5",
                name: "utun0",
                index: 5,
                nwInterfaceType: "tunnel/vpn",
                addresses: ["192.168.64.2"],
                destinationAddresses: ["192.168.64.1"],
                isPointToPoint: true,
                isUp: true
            ),
            confidence: .confident,
            detectedPeer: "192.168.64.1",
            reason: "P2P utun destination IP"
        )
        // Configured target is 10.7.0.1, but derived peer is 192.168.64.1
        let snapshot = makeBaseSnapshot(
            vpnCandidate: vpnCandidate,
            configuredTargetIP: "10.7.0.1"
        )

        let probeA = CellularPathProbeResult(
            probeType: .baseline,
            status: .failure,
            posixErrno: 60,
            errorDescription: "Operation timed out"
        )

        let report = CellularBootstrapDiagnosisEngine.evaluate(
            snapshot: snapshot,
            probeA: probeA,
            probeB: nil,
            probeC: nil
        )

        #expect(report.verdict == .TARGET_OR_PEER_MISMATCH)
        #expect(report.confidence == .high)
        #expect(report.interpretation.contains("10.7.0.1"))
        #expect(report.interpretation.contains("192.168.64.1"))
    }

    // MARK: - Rule D: All Probes Refused with VPN Available

    @Test func ruleD_allProbesRefusedOnVPNPath_yieldsRemoteListenerNotAccepting() {
        let snapshot = makeBaseSnapshot(activeDVT: false, recentLocationSuccess: false)

        let probeA = CellularPathProbeResult(
            probeType: .baseline,
            status: .failure,
            posixErrno: 61,
            errorDescription: "Connection refused"
        )
        let probeB = CellularPathProbeResult(
            probeType: .cellularProhibited,
            status: .failure,
            posixErrno: 61,
            errorDescription: "Connection refused"
        )
        let probeC = CellularPathProbeResult(
            probeType: .requiredInterface,
            status: .failure,
            posixErrno: 61,
            errorDescription: "Connection refused"
        )

        let report = CellularBootstrapDiagnosisEngine.evaluate(
            snapshot: snapshot,
            probeA: probeA,
            probeB: probeB,
            probeC: probeC
        )

        #expect(report.verdict == .REMOTE_LISTENER_NOT_ACCEPTING)
        #expect(report.confidence == .medium)
        #expect(report.interpretation.contains("49152 埠未開啟監聽"))
    }

    // MARK: - Rule E: Ambiguous VPN Interface

    @Test func ruleE_ambiguousVPN_yieldsVPNInterfaceAmbiguous() {
        let ambiguousCandidate = VPNInterfaceCandidate(
            interface: nil,
            confidence: .ambiguous,
            detectedPeer: nil,
            reason: "Multiple utun interfaces: utun0, utun1, utun2"
        )
        let snapshot = makeBaseSnapshot(vpnCandidate: ambiguousCandidate)

        let report = CellularBootstrapDiagnosisEngine.evaluate(
            snapshot: snapshot,
            probeA: nil,
            probeB: nil,
            probeC: nil
        )

        #expect(report.verdict == .VPN_INTERFACE_AMBIGUOUS)
        #expect(report.confidence == .low)
    }

    // MARK: - Rule G: FFI Transport Not Controllable

    @Test func ruleG_probesFailedAndPrebuiltFFI_yieldsFFITransportNotControllable() {
        let snapshot = makeBaseSnapshot(activeDVT: false, recentLocationSuccess: false)

        let probeA = CellularPathProbeResult(
            probeType: .baseline,
            status: .failure,
            posixErrno: 60,
            errorDescription: "Timeout"
        )
        let probeB = CellularPathProbeResult(
            probeType: .cellularProhibited,
            status: .failure,
            posixErrno: 51,
            errorDescription: "Network unreachable"
        )

        let report = CellularBootstrapDiagnosisEngine.evaluate(
            snapshot: snapshot,
            probeA: probeA,
            probeB: probeB,
            probeC: nil
        )

        #expect(report.verdict == .FFI_TRANSPORT_NOT_CONTROLLABLE)
        #expect(report.confidence == .medium)
        #expect(report.recommendedNextStep.contains("TRUE_FFI_INTERFACE_BINDING"))
    }

    // MARK: - Interface Derivation Logic

    @Test func vpnCandidateDerivation_identifiesSingleSubnet10_7() {
        let if1 = NetworkInterfaceInfo(
            id: "en0-1",
            name: "en0",
            index: 1,
            nwInterfaceType: "wifi/ethernet",
            addresses: ["192.168.1.50"]
        )
        let if2 = NetworkInterfaceInfo(
            id: "utun3-8",
            name: "utun3",
            index: 8,
            nwInterfaceType: "tunnel/vpn",
            addresses: ["10.7.0.2"],
            destinationAddresses: ["10.7.0.1"],
            isPointToPoint: true,
            isUp: true,
            isTunnelLike: true
        )

        let candidate = CellularBootstrapTransportProbe.deriveVPNCandidate(interfaces: [if1, if2])
        #expect(candidate.confidence == .confident)
        #expect(candidate.interface?.name == "utun3")
        #expect(candidate.detectedPeer == "10.7.0.1")
    }

    @Test func vpnCandidateDerivation_multipleAmbiguousTunnels_yieldsAmbiguous() {
        let if1 = NetworkInterfaceInfo(
            id: "utun0-2",
            name: "utun0",
            index: 2,
            nwInterfaceType: "tunnel/vpn",
            addresses: ["172.16.0.2"],
            isPointToPoint: true,
            isUp: true,
            isTunnelLike: true
        )
        let if2 = NetworkInterfaceInfo(
            id: "utun1-3",
            name: "utun1",
            index: 3,
            nwInterfaceType: "tunnel/vpn",
            addresses: ["192.168.200.2"],
            isPointToPoint: true,
            isUp: true,
            isTunnelLike: true
        )

        let candidate = CellularBootstrapTransportProbe.deriveVPNCandidate(interfaces: [if1, if2])
        #expect(candidate.confidence == .ambiguous)
        #expect(candidate.interface == nil)
    }

    // MARK: - Formatted Text Validation

    @Test func reportFormatting_containsAllRequiredHeadersAndNoProductionChange() {
        let snapshot = makeBaseSnapshot(activeDVT: true, recentLocationSuccess: true)
        let report = CellularBootstrapDiagnosisEngine.evaluate(
            snapshot: snapshot,
            probeA: nil,
            probeB: nil,
            probeC: nil,
            simulationModeLabel: "單點模擬中"
        )

        let text = report.formattedText
        #expect(text.contains("RouteLocation Cellular Bootstrap Diagnosis"))
        #expect(text.contains("=== SUMMARY ==="))
        #expect(text.contains("Verdict:\nEXISTING_SESSION_HEALTHY"))
        #expect(text.contains("Confidence:\nHIGH"))
        #expect(text.contains("Production Behavior Changed:\nNO"))
        #expect(text.contains("=== SESSION HEALTH ==="))
        #expect(text.contains("Simulation Mode:\n單點模擬中"))
        #expect(text.contains("Active DVT:\nYES"))
        #expect(text.contains("Recent Location Success:\nYES"))
        #expect(text.contains("=== NETWORK ==="))
        #expect(text.contains("Primary Transport:\ncellular"))
        #expect(text.contains("=== TARGET ==="))
        #expect(text.contains("Configured Target:\n10.7.0.1:49152"))
        #expect(text.contains("=== PROBE A — DEFAULT ==="))
        #expect(text.contains("=== PROBE B — CELLULAR PROHIBITED ==="))
        #expect(text.contains("=== PROBE C — REQUIRED VPN INTERFACE ==="))
        #expect(text.contains("=== PRODUCTION BOOTSTRAP ==="))
        #expect(text.contains("Owner:\nPREBUILT_FFI"))
        #expect(text.contains("Function:\ntunnel_create_rppairing"))
        #expect(text.contains("True Interface Binding Available:\nNO"))
        #expect(text.contains("=== RAW DECISION EVIDENCE ==="))
    }
}
