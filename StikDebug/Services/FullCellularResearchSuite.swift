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
    let networkSnapshot: NetworkEnvironmentSnapshot
    let utunInterfaces: [UtunInterfaceEntry]
    let bonjourServices: [RemotePairingDiscoveredService]
    let pathProbes: [CellularPathProbeResult]
    let tcpMatrix: [EndpointMatrixProbeResult]
    let bonjourSummary: String
    let endpointMode: String
    let effectiveProductionEndpoint: String
    let tcpMatrixSummary: String
    let pathProbeSummary: String
    let trialConfigured: FullCellularFFITrial? = nil
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
            "Configured endpoint FFI: \(trialConfigured?.stage ?? "SKIPPED") / \(trialConfigured?.message ?? "READY")",
            "10.7.0.1 FFI: \(trialLocalDevVPN.stage) / \(trialLocalDevVPN.message ?? "READY")",
            "127.0.0.1 FFI: \(trialLoopback.stage) / \(trialLoopback.message ?? "READY")",
            "Existing production session: \(productionSessionHealth)",
            "Production behavior modified: \(productionBehaviorModified ? "YES" : "NO")",
            "Location write occurred: \(locationWriteOccurred ? "YES" : "NO")"
        ]
        var details = lines
        details.append("")
        details.append("UTUN interfaces:")
        if utunInterfaces.isEmpty {
            details.append("  (none)")
        } else {
            for entry in utunInterfaces {
                details.append("  \(entry.interfaceName) family=\(entry.addressFamily) flags=\(entry.ifaFlags) p2p=\(entry.isPointToPoint) up=\(entry.isUp) running=\(entry.isRunning) address=\(entry.observedInterfaceAddress ?? "-") local=\(entry.observedP2PLocalAddress ?? "-") dst=\(entry.observedP2PDestination ?? "-") netmask=\(entry.observedNetmask ?? "-")")
            }
        }
        details.append("Path probes:")
        for probe in pathProbes {
            details.append("  \(probe.probeType.rawValue) target=\(probe.targetIP):\(probe.targetPort) policy=\(probe.interfacePolicy.rawValue) requested=\(probe.requestedInterfaceName ?? "-") requiredApplied=\(probe.requiredInterfaceApplied) status=\(probe.status.rawValue) local=\(probe.localEndpoint ?? "-") remote=\(probe.remoteEndpoint ?? "-") elapsedMs=\(probe.elapsedMs) nw=\(probe.nwErrorDomain ?? "-")/\(probe.nwErrorCode.map { String($0) } ?? "-") errno=\(probe.posixErrno.map { String($0) } ?? "-") error=\(probe.errorDescription ?? "-")")
        }
        details.append("TCP endpoint matrix:")
        for item in tcpMatrix {
            details.append("  target=\(item.target) policy=\(item.policy.rawValue) status=\(item.status.rawValue) local=\(item.localEndpoint ?? "-") remote=\(item.remoteEndpoint ?? "-") elapsedMs=\(item.elapsedMs) nw=\(item.nwErrorDomain ?? "-")/\(item.nwErrorCode.map { String($0) } ?? "-") errno=\(item.posixErrno.map { String($0) } ?? "-") error=\(item.errorDescription ?? "-")")
        }
        details.append("Bonjour services:")
        if bonjourServices.isEmpty {
            details.append("  (none)")
        } else {
            for service in bonjourServices {
                details.append("  \(service.serviceName) type=\(service.serviceType) domain=\(service.domain) port=\(service.port.map { String($0) } ?? "-") addresses=\(service.resolvedAddresses.joined(separator: ",")) interface=\(service.interfaceName ?? "-")")
            }
        }
        return details.joined(separator: "\n")
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
        // A prepared LocationSimulation handle is valid production-session
        // evidence even when no location write has happened yet. Read it on
        // the owner queue so the research report does not race FFI state.
        let preparedSession = LocationSimulationCommandQueue.shared.sync {
            location_simulation_session_snapshot().isPrepared
        }
        let previousSession = snapshot.activeDVTSession || snapshot.recentLocationSuccess || preparedSession

        // Discovery is deliberately bounded by the existing five-second browser timeout.
        BonjourRemotePairingDiscovery.shared.startDiscovery()
        try? await Task.sleep(for: .seconds(5.2))
        BonjourRemotePairingDiscovery.shared.stopDiscovery()

        await probe.runAllProbes()
        let matrix = await probe.runEndpointMatrixProbes()
        let pairingPath = PairingFileStore.prepareURL().path
        let effectiveAddress = BootstrapEndpointStrategy.resolvedAddress(
            transport: ConnectionMonitor.shared.currentTransport
        ) ?? DeviceConnectionContext.targetIPAddress
        let localDevVPNTrial = await runTrial(address: BootstrapEndpointStrategy.localDevVPNAddress, pairingPath: pairingPath)
        let configuredTrial = effectiveAddress == BootstrapEndpointStrategy.localDevVPNAddress
            ? localDevVPNTrial
            : await runTrial(address: effectiveAddress, pairingPath: pairingPath)
        let loopbackTrial = effectiveAddress == BootstrapEndpointStrategy.loopbackAddress
            ? configuredTrial
            : await runTrial(address: BootstrapEndpointStrategy.loopbackAddress, pairingPath: pairingPath)
        let finalSnapshot = probe.latestSnapshot ?? snapshot

        let detailedPathProbes = [probe.probeAResult, probe.probeBResult, probe.probeCResult, probe.candidatePeerProbeResult].compactMap { $0 }
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
            networkSnapshot: finalSnapshot,
            utunInterfaces: topology.interfaces,
            bonjourServices: BonjourRemotePairingDiscovery.shared.discoveredServices,
            pathProbes: detailedPathProbes,
            tcpMatrix: matrix,
            bonjourSummary: BonjourRemotePairingDiscovery.shared.summaryForTrace(),
            endpointMode: BootstrapEndpointStrategy.storedMode().rawValue,
            effectiveProductionEndpoint: "\(BootstrapEndpointStrategy.resolvedAddress(transport: ConnectionMonitor.shared.currentTransport) ?? DeviceConnectionContext.targetIPAddress):49152",
            tcpMatrixSummary: matrix.map { "\($0.target) \($0.policy.rawValue)=\($0.status.rawValue)" }.joined(separator: "; "),
            pathProbeSummary: detailedPathProbes.map { "\($0.probeType.rawValue)=\($0.status.rawValue)" }.joined(separator: "; "),
            trialConfigured: FullCellularFFITrial(configuredTrial),
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
