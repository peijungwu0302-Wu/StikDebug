import CryptoKit
import Foundation
import UIKit

public struct InstallationIdentityInfo: Equatable, Sendable {
    public let bundleIdentifier: String
    public let applicationIdentifier: String
    public var appIdentifier: String { applicationIdentifier }
    public let teamIdentifier: String
    public let version: String
    public let build: String
    public let pairingStatus: String
    public var pairingFileStatus: String { pairingStatus }
    public let pairingStorage: String
    public let containerIdentityHash: String
    public let provisioningProfileStatus: String
    public let signingExpirationDate: String?

    public init(
        bundleIdentifier: String,
        applicationIdentifier: String,
        teamIdentifier: String,
        version: String,
        build: String,
        pairingStatus: String,
        pairingStorage: String,
        containerIdentityHash: String,
        provisioningProfileStatus: String = "有效",
        signingExpirationDate: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationIdentifier = applicationIdentifier
        self.teamIdentifier = teamIdentifier
        self.version = version
        self.build = build
        self.pairingStatus = pairingStatus
        self.pairingStorage = pairingStorage
        self.containerIdentityHash = containerIdentityHash
        self.provisioningProfileStatus = provisioningProfileStatus
        self.signingExpirationDate = signingExpirationDate
    }
}

enum DiagnosticEventCategory: String, Codable, CaseIterable {
    case lifecycle
    case transport
    case dvtSession
    case bootstrap
    case locationCommand
    case userMarker
    case decision
    case error

    var displayName: String {
        switch self {
        case .lifecycle: return L10n.text("生命週期")
        case .transport: return L10n.text("網路傳輸")
        case .dvtSession: return L10n.text("DVT 工作階段")
        case .bootstrap: return L10n.text("Bootstrap")
        case .locationCommand: return L10n.text("定位指令")
        case .userMarker: return L10n.text("測試標記")
        case .decision: return L10n.text("決策記錄")
        case .error: return L10n.text("錯誤")
        }
    }
}

struct DiagnosticEvent: Identifiable, Codable {
    let id: UUID
    let runId: String
    let sessionId: String?
    let timestamp: Date
    let category: DiagnosticEventCategory
    let action: String
    let details: [String: String]

    init(
        id: UUID = UUID(),
        runId: String,
        sessionId: String? = nil,
        timestamp: Date = .now,
        category: DiagnosticEventCategory,
        action: String,
        details: [String: String] = [:]
    ) {
        self.id = id
        self.runId = runId
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.category = category
        self.action = action
        self.details = details
    }
}

struct DiagnosticTestRun: Identifiable, Codable {
    let id: String
    var name: String
    let createdAt: Date
    var updatedAt: Date
    let appVersion: String
    let buildNumber: String
    let osVersion: String
    var eventCount: Int
}

@MainActor
final class DeveloperDiagnosticsStore: ObservableObject {
    static let shared = DeveloperDiagnosticsStore()

    @Published private(set) var runs: [DiagnosticTestRun] = []
    @Published private(set) var activeRun: DiagnosticTestRun?
    @Published private(set) var recentEvents: [DiagnosticEvent] = []
    @Published var isDeveloperModeUnlocked: Bool {
        didSet {
            UserDefaults.standard.set(isDeveloperModeUnlocked, forKey: Self.devModeKey)
        }
    }

    private let fileQueue = DispatchQueue(label: "com.routelocation.diagnostics-io", qos: .utility)
    private static let devModeKey = "RouteLocation.developerModeUnlocked"
    private static let activeRunIdKey = "RouteLocation.activeRunId"
    private let maxStoredRuns = 10
    private let maxAgeDays: TimeInterval = 7 * 86400

    private var diagnosticsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("DeveloperDiagnostics", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var runsDirectory: URL {
        let dir = diagnosticsDirectory.appendingPathComponent("runs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private init() {
        self.isDeveloperModeUnlocked = UserDefaults.standard.bool(forKey: Self.devModeKey)
        self.loadRunsFromDisk()
        self.ensureActiveRun()
        self.pruneOldRuns()
    }

    func unlockDeveloperMode() {
        isDeveloperModeUnlocked = true
        record(category: .lifecycle, action: "DEVELOPER_MODE_UNLOCKED", details: [:])
    }

    func lockDeveloperMode() {
        isDeveloperModeUnlocked = false
        record(category: .lifecycle, action: "DEVELOPER_MODE_LOCKED", details: [:])
    }

    func startNewRun(name: String? = nil) {
        let runId = UUID().uuidString
        let date = Date()
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.10"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "6"
        let osVersion = UIDevice.current.systemVersion

        let runName = name ?? "Test Run \(ISO8601DateFormatter().string(from: date))"
        let newRun = DiagnosticTestRun(
            id: runId,
            name: runName,
            createdAt: date,
            updatedAt: date,
            appVersion: appVersion,
            buildNumber: buildNumber,
            osVersion: osVersion,
            eventCount: 0
        )

        activeRun = newRun
        runs.insert(newRun, at: 0)
        recentEvents.removeAll()
        UserDefaults.standard.set(runId, forKey: Self.activeRunIdKey)

        saveRunMetadata(newRun)
        pruneOldRuns()

        record(
            category: .lifecycle,
            action: "NEW_TEST_RUN_STARTED",
            details: ["runId": runId, "name": runName]
        )
    }

    func record(
        category: DiagnosticEventCategory,
        action: String,
        details: [String: String] = [:],
        sessionId: String? = nil
    ) {
        let currentRun = activeRun ?? ensureActiveRun()
        let event = DiagnosticEvent(
            runId: currentRun.id,
            sessionId: sessionId ?? LocationSessionCoordinator.shared.currentSessionId,
            timestamp: Date(),
            category: category,
            action: action,
            details: details
        )

        recentEvents.insert(event, at: 0)
        if recentEvents.count > 100 {
            recentEvents.removeLast()
        }

        if let index = runs.firstIndex(where: { $0.id == currentRun.id }) {
            runs[index].eventCount += 1
            runs[index].updatedAt = Date()
            activeRun = runs[index]
            saveRunMetadata(runs[index])
        }

        let runDir = runsDirectory.appendingPathComponent(currentRun.id, isDirectory: true)
        let eventsFile = runDir.appendingPathComponent("events.jsonl")

        fileQueue.async {
            do {
                if !FileManager.default.fileExists(atPath: runDir.path) {
                    try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
                }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(event)
                if let handle = try? FileHandle(forWritingTo: eventsFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.write("\n".data(using: .utf8)!)
                    handle.closeFile()
                } else {
                    var initialData = data
                    initialData.append("\n".data(using: .utf8)!)
                    try initialData.write(to: eventsFile, options: .atomic)
                }
            } catch {
                // Silently drop if write fails to preserve foreground operation
            }
        }
    }

    func addUserMarker(note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        record(
            category: .userMarker,
            action: "USER_TEST_MARKER",
            details: ["note": trimmed]
        )
    }

    func logDecision(action: String, reason: String, context: [String: String] = [:]) {
        var merged = context
        merged["decisionReason"] = reason
        record(
            category: .decision,
            action: action,
            details: merged
        )
    }

    func clearAllDiagnostics() {
        recentEvents.removeAll()
        runs.removeAll()
        activeRun = nil
        UserDefaults.standard.removeObject(forKey: Self.activeRunIdKey)

        fileQueue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.runsDirectory)
            try? FileManager.default.createDirectory(at: self.runsDirectory, withIntermediateDirectories: true)
        }
        ensureActiveRun()
    }

    func exportSafeReport(for runId: String? = nil) -> URL? {
        guard let targetRun = (runId != nil ? runs.first(where: { $0.id == runId }) : activeRun) else {
            return nil
        }
        fileQueue.sync {}
        var events = loadEventsFromDisk(for: targetRun.id)
        if events.isEmpty && targetRun.id == activeRun?.id {
            events = recentEvents.filter { $0.runId == targetRun.id }.reversed()
        }
        let sanitizedEvents = events.map { event -> [String: Any] in
            var dict: [String: Any] = [
                "id": event.id.uuidString,
                "timestamp": ISO8601DateFormatter().string(from: event.timestamp),
                "category": event.category.rawValue,
                "action": event.action
            ]
            if let sid = event.sessionId {
                dict["sessionId"] = String(sid.prefix(8))
            }
            var safeDetails: [String: String] = [:]
            for (k, v) in event.details {
                let lowerKey = k.lowercased()
                let lowerVal = v.lowercased()
                if lowerKey.contains("pair") || lowerKey.contains("secret") || lowerKey.contains("key") {
                    safeDetails[k] = "[REDACTED_CREDENTIAL]"
                } else if lowerKey.contains("lat") || lowerKey.contains("lon") || lowerKey.contains("coord") {
                    safeDetails[k] = "[REDACTED_COORDINATE]"
                } else if lowerKey.contains("query") || lowerKey.contains("search") {
                    safeDetails[k] = "[REDACTED_SEARCH]"
                } else if lowerKey.contains("routename") {
                    safeDetails[k] = "[REDACTED_NAME]"
                } else if lowerVal.contains("/var/mobile") || lowerVal.contains("containers/data") || lowerKey.contains("containerpath") {
                    safeDetails[k] = "[REDACTED_CONTAINER_PATH]"
                } else {
                    safeDetails[k] = v
                }
            }
            dict["details"] = safeDetails
            return dict
        }

        let reportDict: [String: Any] = [
            "reportType": "RouteLocation_Sanitized_Developer_Diagnostics",
            "formatVersion": "1.2.7",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "run": [
                "id": targetRun.id,
                "name": targetRun.name,
                "createdAt": ISO8601DateFormatter().string(from: targetRun.createdAt),
                "appVersion": targetRun.appVersion,
                "buildNumber": targetRun.buildNumber,
                "osVersion": targetRun.osVersion,
                "eventCount": sanitizedEvents.count
            ],
            "events": sanitizedEvents
        ]

        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("DiagnosticsExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let fileURL = exportDir.appendingPathComponent("RouteLocation_SafeReport_\(targetRun.id.prefix(8)).json")

        do {
            let data = try JSONSerialization.data(withJSONObject: reportDict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    func exportFullLogs(for runId: String? = nil) -> URL? {
        guard let targetRun = (runId != nil ? runs.first(where: { $0.id == runId }) : activeRun) else {
            return nil
        }
        fileQueue.sync {}
        let runDir = runsDirectory.appendingPathComponent(targetRun.id, isDirectory: true)
        let eventsFile = runDir.appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: eventsFile.path) else { return nil }

        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("DiagnosticsExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let destinationURL = exportDir.appendingPathComponent("RouteLocation_FullLog_\(targetRun.id.prefix(8)).jsonl")

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: eventsFile, to: destinationURL)
            return destinationURL
        } catch {
            return nil
        }
    }

    func loadEventsFromDisk(for runId: String) -> [DiagnosticEvent] {
        let runDir = runsDirectory.appendingPathComponent(runId, isDirectory: true)
        let eventsFile = runDir.appendingPathComponent("events.jsonl")
        guard let data = try? Data(contentsOf: eventsFile),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var list: [DiagnosticEvent] = []
        for line in content.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let event = try? decoder.decode(DiagnosticEvent.self, from: lineData) else {
                continue
            }
            list.append(event)
        }
        return list
    }

    public var installationIdentity: InstallationIdentityInfo {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.routelocation.app"
        let teamId = SigningStatusService.shared.profileInfo?.teamIdentifier.first ?? "APPLE_DEV"
        let redactedTeam = teamId.count > 3 ? "\(teamId.prefix(3))•••••••" : "••••••••••"
        let redactedAppId = "\(redactedTeam).\(bundleId)"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.10"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "6"
        let pairingPresent = FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path)

        let profileInfo = SigningStatusService.shared.profileInfo
        let profileStatus = profileInfo != nil ? "已讀取" : "無嵌入描述檔"
        let expDate = SigningStatusService.shared.remainingFormatted

        return InstallationIdentityInfo(
            bundleIdentifier: bundleId,
            applicationIdentifier: redactedAppId,
            teamIdentifier: redactedTeam,
            version: version,
            build: build,
            pairingStatus: pairingPresent ? "已存在" : "尚未設定",
            pairingStorage: PairingFileStore.canonicalRelativePath,
            containerIdentityHash: containerIdentityHash,
            provisioningProfileStatus: profileStatus,
            signingExpirationDate: expDate
        )
    }

    public var containerIdentityHash: String {
        let home = NSHomeDirectory()
        let digest = SHA256.hash(data: Data(home.utf8))
        let hex = digest.map { String(format: "%02X", $0) }.joined()
        let part1 = hex.prefix(4)
        let part2 = hex.dropFirst(4).prefix(4)
        return "\(part1)-\(part2)"
    }

    @discardableResult
    private func ensureActiveRun() -> DiagnosticTestRun {
        if let current = activeRun { return current }
        if let savedId = UserDefaults.standard.string(forKey: Self.activeRunIdKey),
           let match = runs.first(where: { $0.id == savedId }) {
            activeRun = match
            recentEvents = Array(loadEventsFromDisk(for: match.id).reversed().prefix(100))
            return match
        }
        if let first = runs.first {
            activeRun = first
            UserDefaults.standard.set(first.id, forKey: Self.activeRunIdKey)
            recentEvents = Array(loadEventsFromDisk(for: first.id).reversed().prefix(100))
            return first
        }

        startNewRun(name: "Default Test Run")
        return activeRun!
    }

    private func loadRunsFromDisk() {
        guard let subdirs = try? FileManager.default.contentsOfDirectory(at: runsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }

        var loaded: [DiagnosticTestRun] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for dir in subdirs {
            let metaFile = dir.appendingPathComponent("run.json")
            if let data = try? Data(contentsOf: metaFile),
               let run = try? decoder.decode(DiagnosticTestRun.self, from: data) {
                loaded.append(run)
            }
        }

        loaded.sort { $0.updatedAt > $1.updatedAt }
        runs = loaded
    }

    private func saveRunMetadata(_ run: DiagnosticTestRun) {
        let runDir = runsDirectory.appendingPathComponent(run.id, isDirectory: true)
        let metaFile = runDir.appendingPathComponent("run.json")

        fileQueue.async {
            do {
                if !FileManager.default.fileExists(atPath: runDir.path) {
                    try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
                }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = .prettyPrinted
                let data = try encoder.encode(run)
                try data.write(to: metaFile, options: .atomic)
            } catch {
                // Ignore background save errors
            }
        }
    }

    private func pruneOldRuns() {
        fileQueue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            var currentRuns = self.runs

            // 1. Filter out runs older than maxAgeDays
            currentRuns.removeAll { run in
                if now.timeIntervalSince(run.updatedAt) > self.maxAgeDays {
                    let dir = self.runsDirectory.appendingPathComponent(run.id)
                    try? FileManager.default.removeItem(at: dir)
                    return true
                }
                return false
            }

            // 2. Limit to maxStoredRuns
            if currentRuns.count > self.maxStoredRuns {
                let toRemove = currentRuns.suffix(from: self.maxStoredRuns)
                for run in toRemove {
                    let dir = self.runsDirectory.appendingPathComponent(run.id)
                    try? FileManager.default.removeItem(at: dir)
                }
                currentRuns = Array(currentRuns.prefix(self.maxStoredRuns))
            }

            Task { @MainActor in
                self.runs = currentRuns
            }
        }
    }
}
