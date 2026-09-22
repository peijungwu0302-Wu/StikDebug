//
//  CellularBootstrapDiagnosisEngine.swift
//  StikDebug
//
//  Created for RouteLocation Cellular Bootstrap Transport Spike.
//

import Foundation

public enum DiagnosisVerdict: String, CaseIterable, Equatable {
    case EXISTING_SESSION_HEALTHY
    case PATH_OR_INTERFACE_SELECTION_PROBLEM
    case TARGET_OR_PEER_MISMATCH
    case REMOTE_LISTENER_NOT_ACCEPTING
    case VPN_INTERFACE_AMBIGUOUS
    case NO_LOCAL_VPN_PATH
    case FFI_TRANSPORT_NOT_CONTROLLABLE
    case DIAGNOSTIC_PROBE_ONLY_SUCCESS
    case NETWORK_OFFLINE
    case INSUFFICIENT_EVIDENCE

    public var localizedTitle: String {
        switch self {
        case .EXISTING_SESSION_HEALTHY:
            return L10n.text("既有定位工作階段正常 (現有 DVT / 定位可用)")
        case .PATH_OR_INTERFACE_SELECTION_PROBLEM:
            return L10n.text("路徑/介面選擇問題 (預設路徑失敗，指定 VPN 介面可連通)")
        case .TARGET_OR_PEER_MISMATCH:
            return L10n.text("目標與 Peer 不相符 (設定目標與實際 VPN Peer 衝突)")
        case .REMOTE_LISTENER_NOT_ACCEPTING:
            return L10n.text("遠端服務未監聽 (封包已達 VPN，但遠端拒絕連線)")
        case .VPN_INTERFACE_AMBIGUOUS:
            return L10n.text("VPN 介面模稜兩可 (存在多個或無法唯一識別之 utun 介面)")
        case .NO_LOCAL_VPN_PATH:
            return L10n.text("無本機 VPN 路徑 (未偵測到任何作用中的 VPN 介面)")
        case .FFI_TRANSPORT_NOT_CONTROLLABLE:
            return L10n.text("FFI 傳輸層不可控 (預編譯 FFI 內部直連 TCP，無法指定介面)")
        case .DIAGNOSTIC_PROBE_ONLY_SUCCESS:
            return L10n.text("僅診斷探測連通 (NWConnection 成功，但未證明 FFI 走同路徑)")
        case .NETWORK_OFFLINE:
            return L10n.text("網路完全離線 (無可用網路傳輸介面)")
        case .INSUFFICIENT_EVIDENCE:
            return L10n.text("診斷資訊不足 (尚未執行完整路徑探測)")
        }
    }
}

public enum DiagnosisConfidence: String, Equatable {
    case high = "HIGH"
    case medium = "MEDIUM"
    case low = "LOW"
}

public struct DiagnosisReport: Equatable {
    public let verdict: DiagnosisVerdict
    public let confidence: DiagnosisConfidence
    public let interpretation: String
    public let recommendedNextStep: String
    public let evidenceSummary: [String]
    public let rawEvidence: [String: String]
    public let formattedText: String

    public init(
        verdict: DiagnosisVerdict,
        confidence: DiagnosisConfidence,
        interpretation: String,
        recommendedNextStep: String,
        evidenceSummary: [String],
        rawEvidence: [String: String],
        formattedText: String
    ) {
        self.verdict = verdict
        self.confidence = confidence
        self.interpretation = interpretation
        self.recommendedNextStep = recommendedNextStep
        self.evidenceSummary = evidenceSummary
        self.rawEvidence = rawEvidence
        self.formattedText = formattedText
    }
}

public struct CellularBootstrapDiagnosisEngine {

    public static func evaluate(
        snapshot: NetworkEnvironmentSnapshot,
        probeA: CellularPathProbeResult?,
        probeB: CellularPathProbeResult?,
        probeC: CellularPathProbeResult?,
        simulationModeLabel: String = "未模擬"
    ) -> DiagnosisReport {
        var raw: [String: String] = [:]
        var evidence: [String] = []

        raw["activeDVT"] = String(snapshot.activeDVTSession)
        raw["recentLocationSuccess"] = String(snapshot.recentLocationSuccess)
        raw["tunnelConnected"] = String(snapshot.tunnelConnected)
        raw["primaryTransport"] = snapshot.primaryTransport
        raw["isWifiAvailable"] = String(snapshot.isWifiAvailable)
        raw["isCellularAvailable"] = String(snapshot.isCellularAvailable)
        raw["isInternetSatisfied"] = String(snapshot.isInternetSatisfied)
        raw["vpnDetectedByNWPath"] = String(snapshot.vpnDetectedByNWPath)
        raw["vpnConfidence"] = snapshot.vpnCandidate.confidence.rawValue
        raw["vpnInterface"] = snapshot.vpnCandidate.interface?.name ?? "none"
        raw["configuredTarget"] = "\(snapshot.configuredTargetIP):\(snapshot.configuredTargetPort)"
        raw["detectedPeer"] = snapshot.detectedCandidatePeer ?? "none"

        if let pA = probeA {
            raw["probeA_status"] = pA.status.rawValue
            raw["probeA_errno"] = pA.posixErrno.map(String.init) ?? "none"
            raw["probeA_interface"] = pA.selectedInterfaceName ?? "none"
        } else {
            raw["probeA_status"] = "NOT_RUN"
        }

        if let pB = probeB {
            raw["probeB_status"] = pB.status.rawValue
            raw["probeB_errno"] = pB.posixErrno.map(String.init) ?? "none"
            raw["probeB_interface"] = pB.selectedInterfaceName ?? "none"
        } else {
            raw["probeB_status"] = "NOT_RUN"
        }

        if let pC = probeC {
            raw["probeC_status"] = pC.status.rawValue
            raw["probeC_errno"] = pC.posixErrno.map(String.init) ?? "none"
            raw["probeC_interface"] = pC.selectedInterfaceName ?? "none"
        } else {
            raw["probeC_status"] = "NOT_RUN"
        }

        // ==========================================
        // RULE EVALUATION
        // ==========================================

        // RULE A: Existing Session Healthy
        if snapshot.activeDVTSession || snapshot.recentLocationSuccess {
            let verdict = DiagnosisVerdict.EXISTING_SESSION_HEALTHY
            let confidence = DiagnosisConfidence.high
            let interpretation = "目前已有健康定位工作階段或近期成功之定位指令。現有 DVT 連線完全正常，絕不建議重建或中斷既有通道。"
            let nextStep = "保持現有連線；在行動數據開啟時直接繼續使用定位與路線模擬，不觸發多餘 Bootstrap。"
            evidence.append("Active DVT session: \(snapshot.activeDVTSession)")
            evidence.append("Recent location success: \(snapshot.recentLocationSuccess)")

            return buildReport(
                verdict: verdict,
                confidence: confidence,
                interpretation: interpretation,
                recommendedNextStep: nextStep,
                evidenceSummary: evidence,
                raw: raw,
                snapshot: snapshot,
                probeA: probeA,
                probeB: probeB,
                probeC: probeC,
                simulationModeLabel: simulationModeLabel
            )
        }

        // Offline Check
        if snapshot.primaryTransport == "offline" && !snapshot.isWifiAvailable && !snapshot.isCellularAvailable {
            let verdict = DiagnosisVerdict.NETWORK_OFFLINE
            let confidence = DiagnosisConfidence.high
            let interpretation = "裝置目前處於完全離線狀態，無任何可用之實體或虛擬網路介面。"
            let nextStep = "請先連線至 Wi-Fi 或開啟行動數據與 LocalDevVPN。"
            evidence.append("Network status: offline")

            return buildReport(
                verdict: verdict,
                confidence: confidence,
                interpretation: interpretation,
                recommendedNextStep: nextStep,
                evidenceSummary: evidence,
                raw: raw,
                snapshot: snapshot,
                probeA: probeA,
                probeB: probeB,
                probeC: probeC,
                simulationModeLabel: simulationModeLabel
            )
        }

        // RULE E: Ambiguous VPN Interface
        if snapshot.vpnCandidate.confidence == .ambiguous {
            let verdict = DiagnosisVerdict.VPN_INTERFACE_AMBIGUOUS
            let confidence = DiagnosisConfidence.low
            let interpretation = "系統偵測到多個或無法唯一識別的 utun / 穿透介面 (\(snapshot.vpnCandidate.reason))，無法確定何者為 LocalDevVPN。"
            let nextStep = "檢查是否有其他 VPN 軟體同時啟用，或重置 LocalDevVPN 建立單一通道。"
            evidence.append("Ambiguous VPN candidate: \(snapshot.vpnCandidate.reason)")

            return buildReport(
                verdict: verdict,
                confidence: confidence,
                interpretation: interpretation,
                recommendedNextStep: nextStep,
                evidenceSummary: evidence,
                raw: raw,
                snapshot: snapshot,
                probeA: probeA,
                probeB: probeB,
                probeC: probeC,
                simulationModeLabel: simulationModeLabel
            )
        }

        // No VPN Interface Path
        if snapshot.vpnCandidate.confidence == .none && !snapshot.vpnDetectedByNWPath {
            let verdict = DiagnosisVerdict.NO_LOCAL_VPN_PATH
            let confidence = DiagnosisConfidence.high
            let interpretation = "未偵測到任何本機 LocalDevVPN (utun) 介面，封包將被迫走預設實體路徑（Wi-Fi 或蜂巢行動網路）。"
            let nextStep = "請先啟動並確認 LocalDevVPN 處於已連線狀態。"
            evidence.append("No active utun interface discovered")

            return buildReport(
                verdict: verdict,
                confidence: confidence,
                interpretation: interpretation,
                recommendedNextStep: nextStep,
                evidenceSummary: evidence,
                raw: raw,
                snapshot: snapshot,
                probeA: probeA,
                probeB: probeB,
                probeC: probeC,
                simulationModeLabel: simulationModeLabel
            )
        }

        // RULE C: Target or Peer Mismatch
        if let peer = snapshot.detectedCandidatePeer, !peer.isEmpty, peer != snapshot.configuredTargetIP {
            if probeA?.status == .failure {
                let verdict = DiagnosisVerdict.TARGET_OR_PEER_MISMATCH
                let confidence = DiagnosisConfidence.high
                let interpretation = "設定之目標 IP (\(snapshot.configuredTargetIP)) 與從 VPN 介面推導之 Candidate Peer (\(peer)) 不相符，且預設目標連線失敗。"
                let nextStep = "於設定中將目標裝置 IP 變更為推導出之 Candidate Peer (\(peer)) 後再行嘗試。"
                evidence.append("Configured target: \(snapshot.configuredTargetIP) vs Derived peer: \(peer)")

                return buildReport(
                    verdict: verdict,
                    confidence: confidence,
                    interpretation: interpretation,
                    recommendedNextStep: nextStep,
                    evidenceSummary: evidence,
                    raw: raw,
                    snapshot: snapshot,
                    probeA: probeA,
                    probeB: probeB,
                    probeC: probeC,
                    simulationModeLabel: simulationModeLabel
                )
            }
        }

        // RULE B & F: Probe A fails AND Probe C (Required VPN Interface) succeeds
        if probeA?.status == .failure && probeC?.status == .success {
            // Rule F: Production DVT bootstrap is inside prebuilt libidevice_ffi.a without interface binding
            let verdict = DiagnosisVerdict.DIAGNOSTIC_PROBE_ONLY_SUCCESS
            let confidence = DiagnosisConfidence.high
            let interpretation = "VPN-bound TCP connectivity is proven, but this does not prove that tunnel_create_rppairing uses the same interface. (真正連線由預編譯之 libidevice_ffi.a 內部直接建立，Swift Network.framework 之策略無法介入原生 C/Rust socket)"
            let nextStep = "TRUE_FFI_INTERFACE_BINDING (需自編或擴充 libidevice_ffi 介面以支援指定綁定介面或傳入已綁定之 socket)"
            evidence.append("Probe A (default) failed; Probe C (required VPN) succeeded")
            evidence.append("Production bootstrap owner: PREBUILT_FFI (libidevice_ffi.a)")

            return buildReport(
                verdict: verdict,
                confidence: confidence,
                interpretation: interpretation,
                recommendedNextStep: nextStep,
                evidenceSummary: evidence,
                raw: raw,
                snapshot: snapshot,
                probeA: probeA,
                probeB: probeB,
                probeC: probeC,
                simulationModeLabel: simulationModeLabel
            )
        }

        // RULE D: All probes fail with ECONNREFUSED (errno 61)
        let isErrno61 = { (p: CellularPathProbeResult?) -> Bool in
            p?.posixErrno == 61 || p?.errorDescription?.contains("Connection refused") == true
        }
        if isErrno61(probeA) && (probeB == nil || isErrno61(probeB)) && (probeC == nil || isErrno61(probeC)) {
            let verdict = DiagnosisVerdict.REMOTE_LISTENER_NOT_ACCEPTING
            let confidence = DiagnosisConfidence.medium
            let interpretation = "所有探測均回傳 Connection refused (errno 61)。封包已能藉由 VPN 路徑抵達目標，但目標主機之 49152 埠未開啟監聽或遠端配對服務未就緒。"
            let nextStep = "確認遠端 Mac / 輔助主機上的 RemotePairing / Developer Mode 守護行程是否運作，並檢查防火牆。"
            evidence.append("All probes returned ECONNREFUSED 61")

            return buildReport(
                verdict: verdict,
                confidence: confidence,
                interpretation: interpretation,
                recommendedNextStep: nextStep,
                evidenceSummary: evidence,
                raw: raw,
                snapshot: snapshot,
                probeA: probeA,
                probeB: probeB,
                probeC: probeC,
                simulationModeLabel: simulationModeLabel
            )
        }

        // RULE G: FFI Transport Not Controllable (Probes failed or prebuilt limitation)
        if probeA?.status == .failure && probeB?.status == .failure {
            let verdict = DiagnosisVerdict.FFI_TRANSPORT_NOT_CONTROLLABLE
            let confidence = DiagnosisConfidence.medium
            let interpretation = "預設路徑與禁止行動網路探測均失敗，且實際 DVT bootstrap 由預編譯 libidevice_ffi.a 擁有，無法自 Swift 層強制綁定 utun 介面。"
            let nextStep = "TRUE_FFI_INTERFACE_BINDING (需評估重建 libidevice_ffi 並提供 socket 介面綁定 ABI)"
            evidence.append("Probe A and B both failed")

            return buildReport(
                verdict: verdict,
                confidence: confidence,
                interpretation: interpretation,
                recommendedNextStep: nextStep,
                evidenceSummary: evidence,
                raw: raw,
                snapshot: snapshot,
                probeA: probeA,
                probeB: probeB,
                probeC: probeC,
                simulationModeLabel: simulationModeLabel
            )
        }

        // Fallback: Insufficient Evidence
        let verdict = DiagnosisVerdict.INSUFFICIENT_EVIDENCE
        let confidence = DiagnosisConfidence.low
        let interpretation = "尚未執行足夠的網路路徑探測，無法做出明確診斷。"
        let nextStep = "請在下方點擊「執行路徑診斷探測」以執行 Probe A / B / C。"
        evidence.append("Probes not run or inconclusive")

        return buildReport(
            verdict: verdict,
            confidence: confidence,
            interpretation: interpretation,
            recommendedNextStep: nextStep,
            evidenceSummary: evidence,
            raw: raw,
            snapshot: snapshot,
            probeA: probeA,
            probeB: probeB,
            probeC: probeC,
            simulationModeLabel: simulationModeLabel
        )
    }

    private static func buildReport(
        verdict: DiagnosisVerdict,
        confidence: DiagnosisConfidence,
        interpretation: String,
        recommendedNextStep: String,
        evidenceSummary: [String],
        raw: [String: String],
        snapshot: NetworkEnvironmentSnapshot,
        probeA: CellularPathProbeResult?,
        probeB: CellularPathProbeResult?,
        probeC: CellularPathProbeResult?,
        simulationModeLabel: String
    ) -> DiagnosisReport {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestampStr = formatter.string(from: Date())

        func formatProbe(_ p: CellularPathProbeResult?) -> String {
            guard let p = p else {
                return """
                Result:
                NOT RUN

                Interface:
                -

                Local Endpoint:
                -

                Remote Endpoint:
                -

                Elapsed:
                0 ms

                NWError:
                -

                POSIX errno:
                -
                """
            }
            return """
            Result:
            \(p.status.rawValue)

            Interface:
            \(p.selectedInterfaceName ?? "-")

            Local Endpoint:
            \(p.localEndpoint ?? "-")

            Remote Endpoint:
            \(p.remoteEndpoint ?? "-")

            Elapsed:
            \(p.elapsedMs) ms

            NWError:
            \(p.nwErrorDomain != nil ? "\(p.nwErrorDomain!):\(p.nwErrorCode ?? 0)" : "-")

            POSIX errno:
            \(p.posixErrno.map(String.init) ?? "-")
            """
        }

        let targetMatchesCandidate: String
        if let detected = snapshot.detectedCandidatePeer {
            targetMatchesCandidate = (detected == snapshot.configuredTargetIP) ? "YES" : "NO"
        } else {
            targetMatchesCandidate = "UNKNOWN"
        }

        let rawLines = raw.keys.sorted().map { "\($0)=\(raw[$0] ?? "")" }.joined(separator: "\n")

        let text = """
        RouteLocation Cellular Bootstrap Diagnosis
        Timestamp: \(timestampStr)

        === SUMMARY ===

        Verdict:
        \(verdict.rawValue)

        Confidence:
        \(confidence.rawValue)

        Interpretation:
        \(interpretation)

        Recommended Next Step:
        \(recommendedNextStep)

        Production Behavior Changed:
        NO


        === SESSION HEALTH ===

        Simulation Mode:
        \(simulationModeLabel)

        Active DVT:
        \(snapshot.activeDVTSession ? "YES" : "NO")

        Recent Location Success:
        \(snapshot.recentLocationSuccess ? "YES" : "NO")

        TunnelManager Connected:
        \(snapshot.tunnelConnected ? "YES" : "NO")


        === NETWORK ===

        Primary Transport:
        \(snapshot.primaryTransport)

        Wi-Fi:
        \(snapshot.isWifiAvailable ? "Available" : "Not Available")

        Cellular:
        \(snapshot.isCellularAvailable ? "Available" : "Not Available")

        NWPath:
        \(snapshot.isInternetSatisfied ? "Satisfied" : "Unsatisfied")

        VPN Detected:
        \(snapshot.vpnDetectedByNWPath ? "YES" : "NO")

        VPN Candidate:
        \(snapshot.vpnCandidate.interface?.name ?? "None")

        VPN Confidence:
        \(snapshot.vpnCandidate.confidence.rawValue)


        === TARGET ===

        Configured Target:
        \(snapshot.configuredTargetIP):\(snapshot.configuredTargetPort)

        Detected Candidate Peer:
        \(snapshot.detectedCandidatePeer ?? "unavailable")

        Target Matches Candidate:
        \(targetMatchesCandidate)


        === PROBE A — DEFAULT ===

        \(formatProbe(probeA))


        === PROBE B — CELLULAR PROHIBITED ===

        \(formatProbe(probeB))


        === PROBE C — REQUIRED VPN INTERFACE ===

        \(formatProbe(probeC))


        === PRODUCTION BOOTSTRAP ===

        Owner:
        PREBUILT_FFI

        Function:
        tunnel_create_rppairing

        True Interface Binding Available:
        NO


        === RAW DECISION EVIDENCE ===

        \(rawLines)
        """

        return DiagnosisReport(
            verdict: verdict,
            confidence: confidence,
            interpretation: interpretation,
            recommendedNextStep: recommendedNextStep,
            evidenceSummary: evidenceSummary,
            rawEvidence: raw,
            formattedText: text
        )
    }
}
