//
//  DirectCellularResearchService.swift
//  StikDebug
//
//  Created for RouteLocation v1.2.11 Direct Cellular Bootstrap Research Beta.
//

import Combine
import Foundation

enum BootstrapStateClassification: String, Codable, CaseIterable {
    case stateA = "A" // Cellular ON, No healthy DVT
    case stateB = "B" // Cellular OFF / primary not cellular, No healthy DVT
    case stateC = "C" // Cellular ON, Healthy DVT / recent location success
    case other = "OTHER"

    var title: String {
        switch self {
        case .stateA: return "State A: 行動網路開啟，無作用中 DVT"
        case .stateB: return "State B: 行動網路關閉／非行動網路，無作用中 DVT"
        case .stateC: return "State C: 行動網路開啟，作用中 DVT / 定位正常"
        case .other: return "State Other: 其他狀態"
        }
    }
}

struct DirectCellularResearchResult: Identifiable, Codable, Equatable {
    let id: String // runId
    let timestamp: Date
    let stateClassification: BootstrapStateClassification
    let transport: String
    let vpnObserved: Bool
    let utunTopologySummary: String
    let productionTarget: String
    let productionRPairingResult: String // "SUCCESS", "FAILED"
    let ffiCode: String?
    let posixErrno: String?
    let durationMs: Double
    let rsdResult: String
    let dvtResult: String
    let locationWriteResult: String
    let fallbackOccurred: Bool

    init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        stateClassification: BootstrapStateClassification,
        transport: String,
        vpnObserved: Bool,
        utunTopologySummary: String,
        productionTarget: String,
        productionRPairingResult: String,
        ffiCode: String? = nil,
        posixErrno: String? = nil,
        durationMs: Double,
        rsdResult: String,
        dvtResult: String,
        locationWriteResult: String,
        fallbackOccurred: Bool
    ) {
        self.id = id
        self.timestamp = timestamp
        self.stateClassification = stateClassification
        self.transport = transport
        self.vpnObserved = vpnObserved
        self.utunTopologySummary = utunTopologySummary
        self.productionTarget = productionTarget
        self.productionRPairingResult = productionRPairingResult
        self.ffiCode = ffiCode
        self.posixErrno = posixErrno
        self.durationMs = durationMs
        self.rsdResult = rsdResult
        self.dvtResult = dvtResult
        self.locationWriteResult = locationWriteResult
        self.fallbackOccurred = fallbackOccurred
    }
}

@MainActor
final class DirectCellularResearchService: ObservableObject {
    static let shared = DirectCellularResearchService()

    @Published var isBetaEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isBetaEnabled, forKey: Self.betaKey)
        }
    }

    @Published private(set) var lastResult: DirectCellularResearchResult?
    @Published private(set) var isAttemptInProgress: Bool = false

    private static let betaKey = "RouteLocation.directCellularResearchBetaEnabled"

    private init() {
        self.isBetaEnabled = UserDefaults.standard.bool(forKey: Self.betaKey)
    }

    // MARK: - State Classification

    static func classifyCurrentState() -> BootstrapStateClassification {
        let monitor = ConnectionMonitor.shared
        let isHealthy = monitor.activeDVTSessionAvailable || LocationDataPathHealth.shared.hasRecentSuccess
        let isCellular = monitor.currentTransport == .cellular || monitor.isCellularAvailable

        if isCellular && isHealthy {
            return .stateC
        } else if isCellular && !isHealthy {
            return .stateA
        } else if !isCellular && !isHealthy {
            return .stateB
        } else {
            return .other
        }
    }

    // MARK: - Research Direct Attempt

    func performResearchDirectAttempt(
        targetCoordinate: RouteCoordinate?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !isAttemptInProgress else {
            completion(.failure(NSError(domain: "RouteLocation.ResearchBeta", code: -201, userInfo: [NSLocalizedDescriptionKey: "研究測試進行中"])))
            return
        }

        isAttemptInProgress = true
        let runId = UUID().uuidString
        let startTime = ProcessInfo.processInfo.systemUptime
        let monitor = ConnectionMonitor.shared
        let stateClass = Self.classifyCurrentState()
        let topo = UtunTopologyCollector.collectTopology()
        let targetAddr = "\(DeviceConnectionContext.targetIPAddress):49152"

        BootstrapTraceStore.shared.startTrace(txId: "rs-\(runId.prefix(8))", mode: "ResearchBeta", targetAddress: targetAddr)
        BootstrapTraceStore.shared.recordEvent(
            .researchDirectStart,
            details: [
                "runId": runId,
                "state": stateClass.rawValue,
                "target": targetAddr
            ]
        )

        LogManager.shared.addInfoLog("DirectCellularResearchService: Starting isolated research attempt on \(targetAddr) (State: \(stateClass.rawValue)).")

        #if DEBUG
        if let mock = testMockDirectAttempt {
            mock(targetCoordinate) { [weak self] success, err in
                guard let self else { return }
                self.isAttemptInProgress = false
                let elapsed = (ProcessInfo.processInfo.systemUptime - startTime) * 1000.0
                let res = DirectCellularResearchResult(
                    id: runId,
                    stateClassification: stateClass,
                    transport: monitor.currentTransport.rawValue,
                    vpnObserved: monitor.usesVPNInterface,
                    utunTopologySummary: topo.summary,
                    productionTarget: targetAddr,
                    productionRPairingResult: success ? "SUCCESS" : "FAILED",
                    ffiCode: err != nil ? String((err as? NSError)?.code ?? 61) : nil,
                    posixErrno: err != nil ? String((err as? NSError)?.code ?? 61) : nil,
                    durationMs: elapsed,
                    rsdResult: success ? "READY" : "NOT_RUN",
                    dvtResult: success ? "READY" : "NOT_RUN",
                    locationWriteResult: success ? "SUCCESS" : "NOT_RUN",
                    fallbackOccurred: !success
                )
                self.lastResult = res
                BootstrapTraceStore.shared.recordEvent(
                    .researchDirectResult,
                    details: ["outcome": success ? "SUCCESS" : "FAILED", "durationMs": String(format: "%.1f", elapsed)]
                )
                if success {
                    completion(.success(()))
                } else {
                    completion(.failure(err ?? NSError(domain: "RouteLocation.ResearchBeta", code: -202, userInfo: [NSLocalizedDescriptionKey: "直接連線測試失敗"])))
                }
            }
            return
        }
        #endif

        // Trigger production TunnelManager directly without DataOff
        TunnelManager.shared.start(showErrorUI: false)

        Task { [weak self] in
            guard let self else { return }
            let connected = await self.waitForTunnelConnected(timeoutSeconds: 8.0)
            let elapsed = (ProcessInfo.processInfo.systemUptime - startTime) * 1000.0
            self.isAttemptInProgress = false

            if connected {
                LogManager.shared.addInfoLog("DirectCellularResearchService: Tunnel successfully connected directly under cellular!")
                let res = DirectCellularResearchResult(
                    id: runId,
                    stateClassification: stateClass,
                    transport: monitor.currentTransport.rawValue,
                    vpnObserved: monitor.usesVPNInterface,
                    utunTopologySummary: topo.summary,
                    productionTarget: targetAddr,
                    productionRPairingResult: "SUCCESS",
                    ffiCode: nil,
                    posixErrno: nil,
                    durationMs: elapsed,
                    rsdResult: "READY",
                    dvtResult: "READY",
                    locationWriteResult: "PENDING",
                    fallbackOccurred: false
                )
                self.lastResult = res
                BootstrapTraceStore.shared.recordEvent(
                    .researchDirectResult,
                    details: ["outcome": "SUCCESS", "durationMs": String(format: "%.1f", elapsed)]
                )
                completion(.success(()))
            } else {
                let errReason = TunnelManager.shared.lastErrorMessage ?? "直接連線逾時或失敗"
                LogManager.shared.addWarningLog("DirectCellularResearchService: Direct connection attempt failed: \(errReason)")
                let res = DirectCellularResearchResult(
                    id: runId,
                    stateClassification: stateClass,
                    transport: monitor.currentTransport.rawValue,
                    vpnObserved: monitor.usesVPNInterface,
                    utunTopologySummary: topo.summary,
                    productionTarget: targetAddr,
                    productionRPairingResult: "FAILED",
                    ffiCode: nil,
                    posixErrno: nil,
                    durationMs: elapsed,
                    rsdResult: "FAILED",
                    dvtResult: "FAILED",
                    locationWriteResult: "NOT_RUN",
                    fallbackOccurred: true
                )
                self.lastResult = res
                BootstrapTraceStore.shared.recordEvent(
                    .researchDirectResult,
                    details: ["outcome": "FAILED", "reason": errReason, "durationMs": String(format: "%.1f", elapsed)]
                )
                completion(.failure(NSError(domain: "RouteLocation.ResearchBeta", code: -203, userInfo: [NSLocalizedDescriptionKey: errReason])))
            }
        }
    }

    private func waitForTunnelConnected(timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if TunnelManager.shared.isConnected { return true }
            if !TunnelManager.shared.isStarting && TunnelManager.shared.stage == .error { return false }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return TunnelManager.shared.isConnected
    }

    #if DEBUG
    var testMockDirectAttempt: ((RouteCoordinate?, @escaping (Bool, Error?) -> Void) -> Void)?

    func resetForTesting() {
        isBetaEnabled = false
        lastResult = nil
        isAttemptInProgress = false
        testMockDirectAttempt = nil
    }
    #endif
}
