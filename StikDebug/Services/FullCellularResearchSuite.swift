import Foundation
import Combine

struct FullCellularFFITrial: Codable, Equatable, Sendable {
    let target: String
    let stage: String
    let statusCode: Int32
    let ffiCode: Int32?
    let ffiSubCode: Int32?
    let message: String?
    let durationMs: Double

    init(_ result: LocationSimulationPreparationResult) {
        target = result.target
        stage = result.stage.rawValue
        statusCode = result.statusCode
        ffiCode = result.ffiCode
        ffiSubCode = result.ffiSubCode
        message = result.message
        durationMs = result.durationMs
    }
}

/// A completed research run is a value object. TXT and JSON exports always use
/// this same immutable instance, never live probe state.
struct FullCellularResearchReport: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    let completedAt: Date
    let appVersion: String
    let build: String
    let transport: String
    let wifiObservation: String
    let cellularObservation: String
    let vpnObservation: String
    let vpnCandidate: String
    let pathStatus: String
    let utunSummary: String
    let bonjourSummary: String
    let endpointMode: String
    let effectiveProductionEndpoint: String
    let tcpMatrixSummary: String
    let pathProbeSummary: String
    let trialLocalDevVPN: FullCellularFFITrial
    let trialLoopback: FullCellularFFITrial
    let productionSessionHealth: String
    let productionBehaviorModified: Bool
    let locationWriteOccurred: Bool

    var jsonData: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }

    var text: String {
        let lines = [
            "RouteLocation Full Cellular Research Suite",
            "Run ID: \(id.uuidString)",
            "Started: \(startedAt.ISO8601Format())",
            "Completed: \(completedAt.ISO8601Format())",
            "App: \(appVersion) (\(build))",
            "Transport: \(transport)",
            "Wi-Fi: \(wifiObservation)",
            "Cellular: \(cellularObservation)",
            "VPN: \(vpnObservation)",
            "VPN candidate: \(vpnCandidate)",
            "NWPath: \(pathStatus)",
            "utun: \(utunSummary)",
            "Bonjour: \(bonjourSummary)",
            "Endpoint mode: \(endpointMode)",
            "Effective production endpoint: \(effectiveProductionEndpoint)",
            "Path probes: \(pathProbeSummary)",
            "TCP matrix: \(tcpMatrixSummary)",
            "10.7.0.1 FFI: \(trialLocalDevVPN.stage) / \(trialLocalDevVPN.message ?? "READY")",
            "127.0.0.1 FFI: \(trialLoopback.stage) / \(trialLoopback.message ?? "READY")",
            "Existing production session: \(productionSessionHealth)",
            "Production behavior modified: \(productionBehaviorModified ? "YES" : "NO")",
            "Location write occurred: \(locationWriteOccurred ? "YES" : "NO")"
        ]
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class FullCellularResearchSuite: ObservableObject {
    static let shared = FullCellularResearchSuite()

    @Published private(set) var isRunning = false
    @Published private(set) var latestReport: FullCellularResearchReport?

    private init() {}

    func run() async -> FullCellularResearchReport? {
        guard !isRunning else { return latestReport }
        isRunning = true
        defer { isRunning = false }
        let started = Date()
        let probe = CellularBootstrapTransportProbe.shared
        let snapshot = probe.captureSnapshot()
        let topology = UtunTopologyCollector.collectTopology()
        let previousSession = snapshot.activeDVTSession || snapshot.recentLocationSuccess

        // Discovery is deliberately bounded by the existing five-second browser timeout.
        BonjourRemotePairingDiscovery.shared.startDiscovery()
        try? await Task.sleep(for: .seconds(5.2))
        BonjourRemotePairingDiscovery.shared.stopDiscovery()

        await probe.runAllProbes()
        let matrix = await probe.runEndpointMatrixProbes()
        let pairingPath = PairingFileStore.prepareURL().path
        let localDevVPNTrial = await runTrial(address: BootstrapEndpointStrategy.localDevVPNAddress, pairingPath: pairingPath)
        let loopbackTrial = await runTrial(address: BootstrapEndpointStrategy.loopbackAddress, pairingPath: pairingPath)
        let finalSnapshot = probe.latestSnapshot ?? snapshot

        let report = FullCellularResearchReport(
            id: UUID(), startedAt: started, completedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            transport: finalSnapshot.primaryTransport,
            wifiObservation: finalSnapshot.isWifiAvailable ? "available" : "off/unavailable",
            cellularObservation: finalSnapshot.isCellularAvailable ? "available" : "off/unavailable",
            vpnObservation: finalSnapshot.vpnDetectedByNWPath ? "detected" : "not detected",
            vpnCandidate: finalSnapshot.vpnCandidate.interface?.name ?? "none",
            pathStatus: finalSnapshot.isInternetSatisfied ? "satisfied" : "not satisfied",
            utunSummary: topology.summary,
            bonjourSummary: BonjourRemotePairingDiscovery.shared.summaryForTrace(),
            endpointMode: BootstrapEndpointStrategy.storedMode().rawValue,
            effectiveProductionEndpoint: "\(BootstrapEndpointStrategy.resolvedAddress(transport: ConnectionMonitor.shared.currentTransport) ?? DeviceConnectionContext.targetIPAddress):49152",
            tcpMatrixSummary: matrix.map { "\($0.target) \($0.policy.rawValue)=\($0.status.rawValue)" }.joined(separator: "; "),
            pathProbeSummary: [probe.probeAResult, probe.probeBResult, probe.probeCResult, probe.candidatePeerProbeResult].compactMap { $0 }.map { "\($0.probeType.rawValue)=\($0.status.rawValue)" }.joined(separator: "; "),
            trialLocalDevVPN: FullCellularFFITrial(localDevVPNTrial),
            trialLoopback: FullCellularFFITrial(loopbackTrial),
            productionSessionHealth: previousSession ? "healthy/recent success" : "no active session",
            productionBehaviorModified: false,
            locationWriteOccurred: false
        )
        latestReport = report
        return report
    }

    private func runTrial(address: String, pairingPath: String) async -> LocationSimulationPreparationResult {
        await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async {
                continuation.resume(returning: probe_location_simulation_session(address, pairingPath))
            }
        }
    }
}
