import Combine
import Foundation
import Network

@MainActor
final class LocationSessionCoordinator: ObservableObject {
    static let shared = LocationSessionCoordinator()

    @Published private(set) var sessionState: LocationSessionState = .noSession
    @Published private(set) var currentSessionId: String?
    @Published private(set) var transportHistory: [TransportHistoryEntry] = []
    @Published private(set) var consecutiveFailures: Int = 0
    @Published private(set) var lastPrewarmTimestamp: Date?
    @Published private(set) var isPrewarming: Bool = false

    private var cancellables: Set<AnyCancellable> = []
    private let maxHistoryCount = 20

    var activeSessionAvailable: Bool {
        if case .activeHealthy = sessionState { return true }
        if case .activeDegraded = sessionState { return true }
        return false
    }

    private init() {
        // Observe ConnectionMonitor transport updates
        ConnectionMonitor.shared.$currentTransport
            .receive(on: DispatchQueue.main)
            .sink { [weak self] current in
                guard let self else { return }
                self.observeTransportChange(to: current)
            }
            .store(in: &cancellables)

        // VPN readiness may arrive after the initial NWPath callback. Retry
        // the quiet Wi-Fi warm-up when LocalDevVPN becomes visible rather than
        // treating the first offline/unsatisfied sample as final.
        ConnectionMonitor.shared.$usesVPNInterface
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.prewarmIfAppropriate() }
            .store(in: &cancellables)
        ConnectionMonitor.shared.$currentTransport
            .removeDuplicates()
            .filter { $0 == .wifi }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.prewarmIfAppropriate() }
            .store(in: &cancellables)

        // Observe DataPathHealth
        LocationDataPathHealth.shared.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (status: LocationUpdateHealth) in
                guard let self else { return }
                if status == .healthy, let sid = self.currentSessionId {
                    if case .activeHealthy = self.sessionState { } else {
                        self.sessionState = .activeHealthy(sessionId: sid)
                        self.consecutiveFailures = 0
                    }
                }
            }
            .store(in: &cancellables)
    }

    @discardableResult
    func startNewSession() -> String {
        let newId = UUID().uuidString
        currentSessionId = newId
        consecutiveFailures = 0
        sessionState = .activeHealthy(sessionId: newId)

        DeveloperDiagnosticsStore.shared.record(
            category: .dvtSession,
            action: "SESSION_STARTED",
            details: ["sessionId": newId],
            sessionId: newId
        )

        return newId
    }

    func markSessionHealthy() {
        let sid = currentSessionId ?? startNewSession()
        consecutiveFailures = 0
        sessionState = .activeHealthy(sessionId: sid)
    }

    func markSessionDegraded(error: Error) {
        let sid = currentSessionId ?? startNewSession()
        consecutiveFailures += 1
        sessionState = .activeDegraded(sessionId: sid, failureCount: consecutiveFailures)

        DeveloperDiagnosticsStore.shared.record(
            category: .dvtSession,
            action: "SESSION_DEGRADED",
            details: [
                "sessionId": sid,
                "consecutiveFailures": String(consecutiveFailures),
                "error": error.localizedDescription
            ],
            sessionId: sid
        )
    }

    func markSessionRecovering(attempt: Int) {
        let sid = currentSessionId ?? startNewSession()
        sessionState = .recovering(sessionId: sid, attempt: attempt)

        DeveloperDiagnosticsStore.shared.record(
            category: .dvtSession,
            action: "SESSION_RECOVERING",
            details: ["sessionId": sid, "attempt": String(attempt)],
            sessionId: sid
        )
    }

    func markRestoringRealLocation() {
        sessionState = .restoringRealLocation
        DeveloperDiagnosticsStore.shared.record(
            category: .lifecycle,
            action: "RESTORING_REAL_LOCATION_STAGE",
            details: [:]
        )
    }

    func endSession() {
        let oldSid = currentSessionId
        currentSessionId = nil
        consecutiveFailures = 0
        sessionState = .noSession

        if let oldSid {
            DeveloperDiagnosticsStore.shared.record(
                category: .dvtSession,
                action: "SESSION_ENDED",
                details: ["sessionId": oldSid],
                sessionId: oldSid
            )
        }
    }

    func prewarmIfAppropriate() {
        let pairingPresent = FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path)
        guard pairingPresent else {
            DeveloperDiagnosticsStore.shared.logDecision(
                action: "PREWARM_DECISION",
                reason: "Pairing file is missing, skipping pre-warm",
                context: ["pairingPresent": "false"]
            )
            return
        }

        let preparedSession = LocationSimulationCommandQueue.shared.sync {
            location_simulation_session_snapshot().isPrepared
        }
        if activeSessionAvailable || isPrewarming || preparedSession {
            DeveloperDiagnosticsStore.shared.logDecision(
                action: "PREWARM_DECISION",
                reason: "Session already active or pre-warm currently in progress",
                context: [
                    "activeSessionAvailable": String(activeSessionAvailable),
                    "isPrewarming": String(isPrewarming),
                    "preparedSession": String(preparedSession)
                ]
            )
            return
        }

        let monitor = ConnectionMonitor.shared
        guard monitor.currentTransport == .wifi, monitor.isWifiAvailable, monitor.usesVPNInterface else {
            DeveloperDiagnosticsStore.shared.logDecision(
                action: "PREWARM_DECISION",
                reason: "Automatic warm-up requires Wi-Fi and LocalDevVPN; skipping cellular/offline launch",
                context: ["transport": monitor.currentTransport.rawValue, "vpn": String(monitor.usesVPNInterface)]
            )
            return
        }

        isPrewarming = true
        lastPrewarmTimestamp = Date()
        sessionState = .preparing(stage: L10n.text("自動預熱準備中"))

        DeveloperDiagnosticsStore.shared.logDecision(
            action: "START_PREWARM",
            reason: "App launched/foregrounded with pairing file present and network available",
            context: ["transport": monitor.currentTransport.rawValue]
        )

        Task {
            let pairingPath = PairingFileStore.prepareURL().path
            let target = BootstrapEndpointStrategy.localDevVPNAddress
            let result = await withCheckedContinuation { continuation in
                LocationSimulationCommandQueue.shared.async {
                    continuation.resume(returning: prepare_location_simulation_session(target, pairingPath))
                }
            }
            await MainActor.run {
                self.isPrewarming = false
                if result.isSuccess {
                    self.sessionState = .activeHealthy(sessionId: self.currentSessionId ?? self.startNewSession())
                    DeveloperDiagnosticsStore.shared.record(category: .dvtSession, action: "WARM_SESSION_READY", details: ["target": target])
                } else if case .preparing = self.sessionState {
                    self.sessionState = .noSession
                    LogManager.shared.addDebugLog("Location warm-up skipped after \(result.stage.rawValue): \(result.message ?? "unknown")")
                }
            }
        }
    }

    private func observeTransportChange(to current: NetworkTransport) {
        let monitor = ConnectionMonitor.shared
        let previous = monitor.previousTransport

        let entry = TransportHistoryEntry(
            timestamp: Date(),
            transport: current.rawValue,
            previousTransport: previous.rawValue,
            isSatisfied: monitor.internetReachable,
            isExpensive: monitor.pathIsExpensive,
            usesVPN: monitor.usesVPNInterface,
            action: activeSessionAvailable ? "SKIP_RECOVERY" : "OBSERVED",
            reason: activeSessionAvailable ? "Active DVT session healthy during handoff" : nil
        )

        transportHistory.insert(entry, at: 0)
        if transportHistory.count > maxHistoryCount {
            transportHistory.removeLast()
        }

        DeveloperDiagnosticsStore.shared.record(
            category: .transport,
            action: "TRANSPORT_HANDOFF",
            details: [
                "from": previous.rawValue,
                "to": current.rawValue,
                "vpn": String(monitor.usesVPNInterface),
                "activeSession": String(activeSessionAvailable)
            ]
        )

        if activeSessionAvailable {
            DeveloperDiagnosticsStore.shared.logDecision(
                action: "SKIP_RECOVERY",
                reason: "Location data path and DVT session are healthy during transport handoff",
                context: [
                    "fromTransport": previous.rawValue,
                    "toTransport": current.rawValue
                ]
            )
        }
    }
}
