import Combine
import Foundation
import Network

enum BootstrapTraceEventType: String, Codable, CaseIterable {
    case userRequest = "USER_REQUEST"
    case networkSnapshot = "NETWORK_SNAPSHOT"
    case interfaceSnapshot = "INTERFACE_SNAPSHOT"
    case peerDiscoveryStarted = "PEER_DISCOVERY_STARTED"
    case peerDiscoveryCompleted = "PEER_DISCOVERY_COMPLETED"
    case dataOffRequested = "DATA_OFF_REQUESTED"
    case dataOffCallbackReceived = "DATA_OFF_CALLBACK_RECEIVED"
    case cellularOffConfirmed = "CELLULAR_OFF_CONFIRMED"
    case stabilizationAfterOffStart = "STABILIZATION_AFTER_OFF_START"
    case stabilizationAfterOffEnd = "STABILIZATION_AFTER_OFF_END"
    case rpairingStart = "RPAIRING_START"
    case rpairingSuccess = "RPAIRING_SUCCESS"
    case rpairingFailed = "RPAIRING_FAILED"
    case rsdReady = "RSD_READY"
    case dvtReady = "DVT_READY"
    case firstLocationWriteSuccess = "FIRST_LOCATION_WRITE_SUCCESS"
    case firstLocationWriteFailed = "FIRST_LOCATION_WRITE_FAILED"
    case stabilizationBeforeDataOnStart = "STABILIZATION_BEFORE_DATA_ON_START"
    case stabilizationBeforeDataOnEnd = "STABILIZATION_BEFORE_DATA_ON_END"
    case dataOnRequested = "DATA_ON_REQUESTED"
    case dataOnCallbackReceived = "DATA_ON_CALLBACK_RECEIVED"
    case cellularOnConfirmed = "CELLULAR_ON_CONFIRMED"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case recoveryDataOnStarted = "RECOVERY_DATA_ON_STARTED"
    case recoveryDataOnCompleted = "RECOVERY_DATA_ON_COMPLETED"
    case additionalStabilizationStart = "ADDITIONAL_STABILIZATION_START"
    case additionalStabilizationEnd = "ADDITIONAL_STABILIZATION_END"
    case researchDirectStart = "RESEARCH_DIRECT_START"
    case researchDirectResult = "RESEARCH_DIRECT_RESULT"
    case fallbackToAssisted = "FALLBACK_TO_ASSISTED"
    case utunTopology = "UTUN_TOPOLOGY"
    case cellularRestoreObserved = "CELLULAR_RESTORE_OBSERVED"

    var label: String {
        switch self {
        case .userRequest: return "使用者發起請求"
        case .networkSnapshot: return "網路狀態快照"
        case .interfaceSnapshot: return "介面狀態快照"
        case .peerDiscoveryStarted: return "Peer 探索開始"
        case .peerDiscoveryCompleted: return "Peer 探索完成"
        case .dataOffRequested: return "發送 DataOff 捷徑請求"
        case .dataOffCallbackReceived: return "收到 DataOff 回呼"
        case .cellularOffConfirmed: return "確認行動網路中斷 (Settled)"
        case .stabilizationAfterOffStart: return "Cellular 關閉後穩定等待開始"
        case .stabilizationAfterOffEnd: return "Cellular 關閉後穩定等待結束"
        case .additionalStabilizationStart: return "額外穩定等待開始"
        case .additionalStabilizationEnd: return "額外穩定等待結束"
        case .researchDirectStart: return "直接連線研究測試開始"
        case .researchDirectResult: return "直接連線研究測試結果"
        case .fallbackToAssisted: return "降級切換至輔助啟動 (Fallback)"
        case .utunTopology: return "utun 介面拓撲快照"
        case .cellularRestoreObserved: return "觀察到行動網路已恢復"
        case .rpairingStart: return "RPairing 通道建立開始"
        case .rpairingSuccess: return "RPairing 通道建立成功"
        case .rpairingFailed: return "RPairing 通道建立失敗"
        case .rsdReady: return "RSD 服務連線就緒"
        case .dvtReady: return "DVT 工作階段就緒"
        case .firstLocationWriteSuccess: return "首次定位寫入成功"
        case .firstLocationWriteFailed: return "首次定位寫入失敗"
        case .stabilizationBeforeDataOnStart: return "恢復 Cellular 前穩定等待開始"
        case .stabilizationBeforeDataOnEnd: return "恢復 Cellular 前穩定等待結束"
        case .dataOnRequested: return "發送 DataOn 捷徑請求"
        case .dataOnCallbackReceived: return "收到 DataOn 回呼"
        case .cellularOnConfirmed: return "確認行動網路已恢復"
        case .completed: return "整體 Bootstrap 完成"
        case .failed: return "整體 Bootstrap 失敗"
        case .recoveryDataOnStarted: return "開始自動恢復行動網路 (Rollback)"
        case .recoveryDataOnCompleted: return "完成自動恢復行動網路 (Rollback)"
        }
    }
}

struct BootstrapTraceEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let elapsedMs: Double
    let type: BootstrapTraceEventType
    let details: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        elapsedMs: Double,
        type: BootstrapTraceEventType,
        details: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.elapsedMs = elapsedMs
        self.type = type
        self.details = details
    }
}

struct BootstrapTraceRecord: Identifiable, Codable, Equatable {
    let id: String
    let txId: String
    let mode: String // "AssistedBeta", "Manual", "Direct"
    let startedAt: Date
    var completedAt: Date?
    var overallDurationMs: Double?
    var outcome: String // "SUCCESS", "FAILED", "ROLLBACK", "CANCELLED", "IN_PROGRESS"
    var failureStage: String?
    var failureReason: String?
    var targetAddress: String
    var initialTransport: String
    var initialWifiAvailable: Bool
    var initialCellularAvailable: Bool
    var initialUsesVPN: Bool
    var observedState: String?
    var utunTopologySummary: String?
    var events: [BootstrapTraceEvent]

    var rpairingDurationMs: Double? {
        guard let start = events.first(where: { $0.type == .rpairingStart }),
              let end = events.first(where: { $0.type == .rpairingSuccess || $0.type == .rpairingFailed }) else {
            return nil
        }
        return end.elapsedMs - start.elapsedMs
    }

    var rpairingFfiCode: String? {
        events.first(where: { $0.type == .rpairingFailed })?.details["ffiCode"]
    }

    var rpairingPosixErrno: String? {
        events.first(where: { $0.type == .rpairingFailed })?.details["posixErrno"] ?? events.first(where: { $0.type == .rpairingFailed })?.details["errno"]
    }

    var rpairingErrno: String? {
        rpairingPosixErrno ?? rpairingFfiCode
    }

    var dataOffDurationMs: Double? {
        guard let start = events.first(where: { $0.type == .dataOffRequested }),
              let end = events.first(where: { $0.type == .cellularOffConfirmed || $0.type == .dataOffCallbackReceived }) else {
            return nil
        }
        return end.elapsedMs - start.elapsedMs
    }

    var dataOnDurationMs: Double? {
        guard let start = events.first(where: { $0.type == .dataOnRequested }),
              let end = events.first(where: { $0.type == .cellularOnConfirmed || $0.type == .dataOnCallbackReceived }) else {
            return nil
        }
        return end.elapsedMs - start.elapsedMs
    }

    var firstLocationWriteDurationMs: Double? {
        guard let start = events.first(where: { $0.type == .dvtReady }),
              let end = events.first(where: { $0.type == .firstLocationWriteSuccess || $0.type == .firstLocationWriteFailed }) else {
            return nil
        }
        return end.elapsedMs - start.elapsedMs
    }

    func sanitizedCopyForExport() -> BootstrapTraceRecord {
        let store = BootstrapTraceStore.shared
        let cleanEvents = events.map { ev in
            BootstrapTraceEvent(
                id: ev.id,
                timestamp: ev.timestamp,
                elapsedMs: ev.elapsedMs,
                type: ev.type,
                details: store.sanitizeDetails(ev.details)
            )
        }
        return BootstrapTraceRecord(
            id: id,
            txId: txId,
            mode: mode,
            startedAt: startedAt,
            completedAt: completedAt,
            overallDurationMs: overallDurationMs,
            outcome: outcome,
            failureStage: failureStage,
            failureReason: failureReason.map { store.sanitizeString($0) },
            targetAddress: store.sanitizeString(targetAddress),
            initialTransport: initialTransport,
            initialWifiAvailable: initialWifiAvailable,
            initialCellularAvailable: initialCellularAvailable,
            initialUsesVPN: initialUsesVPN,
            observedState: observedState,
            utunTopologySummary: utunTopologySummary.map { store.sanitizeString($0) },
            events: cleanEvents
        )
    }
}

@MainActor
final class BootstrapTraceStore: ObservableObject {
    static let shared = BootstrapTraceStore()

    @Published private(set) var latestTrace: BootstrapTraceRecord?
    @Published private(set) var previousTrace: BootstrapTraceRecord?
    @Published private(set) var history: [BootstrapTraceRecord] = []

    private var activeTrace: BootstrapTraceRecord?
    private var startUptime: TimeInterval = 0

    var isTraceInProgress: Bool {
        activeTrace != nil && activeTrace?.outcome == "IN_PROGRESS"
    }

    private init() {}

    func beginProductionTraceIfNeeded(mode: String, targetAddress: String = "\(DeviceConnectionContext.targetIPAddress):49152") {
        if let active = activeTrace, active.outcome == "IN_PROGRESS" {
            return
        }
        startTrace(txId: UUID().uuidString, mode: mode, targetAddress: targetAddress)
    }

    func startTrace(txId: String, mode: String, targetAddress: String = "\(DeviceConnectionContext.targetIPAddress):49152") {
        if let active = activeTrace, active.outcome == "IN_PROGRESS" {
            finishTrace(
                outcome: "SUPERSEDED",
                failureStage: "Lifecycle",
                failureReason: "Trace superseded by new trace \(txId)"
            )
        }

        let monitor = ConnectionMonitor.shared
        startUptime = ProcessInfo.processInfo.systemUptime

        var record = BootstrapTraceRecord(
            id: UUID().uuidString,
            txId: txId,
            mode: mode,
            startedAt: Date(),
            completedAt: nil,
            overallDurationMs: nil,
            outcome: "IN_PROGRESS",
            failureStage: nil,
            failureReason: nil,
            targetAddress: targetAddress,
            initialTransport: monitor.currentTransport.rawValue,
            initialWifiAvailable: monitor.isWifiAvailable,
            initialCellularAvailable: monitor.isCellularAvailable,
            initialUsesVPN: monitor.usesVPNInterface,
            observedState: DirectCellularResearchService.classifyCurrentState().rawValue,
            utunTopologySummary: nil,
            events: []
        )

        let initialEvent = BootstrapTraceEvent(
            elapsedMs: 0,
            type: .userRequest,
            details: [
                "mode": mode,
                "txId": txId,
                "target": targetAddress,
                "observedState": record.observedState ?? "none"
            ]
        )
        record.events.append(initialEvent)

        let netEvent = BootstrapTraceEvent(
            elapsedMs: currentElapsedMs(),
            type: .networkSnapshot,
            details: [
                "transport": monitor.currentTransport.rawValue,
                "wifiAvailable": String(monitor.isWifiAvailable),
                "cellularAvailable": String(monitor.isCellularAvailable),
                "usesVPN": String(monitor.usesVPNInterface),
                "isExpensive": String(monitor.pathIsExpensive),
                "internetReachable": String(monitor.internetReachable),
                "configuredTarget": targetAddress,
                "observedState": record.observedState ?? "none"
            ]
        )
        record.events.append(netEvent)

        let utunReport = UtunTopologyCollector.collectTopology()
        record.utunTopologySummary = utunReport.summary
        let utunEvent = BootstrapTraceEvent(
            elapsedMs: currentElapsedMs(),
            type: .utunTopology,
            details: [
                "summary": utunReport.summary,
                "interfaceCount": String(utunReport.interfaces.count),
                "hasP2P": String(utunReport.hasPointToPointUtun),
                "observedState": record.observedState ?? "none"
            ]
        )
        record.events.append(utunEvent)

        let ifaces = CellularBootstrapTransportProbe.querySystemInterfaces()
        let vpnCandidate = CellularBootstrapTransportProbe.deriveVPNCandidate(interfaces: ifaces)
        let candidateName = vpnCandidate.interface?.name ?? "none"
        let candidateLocalIP = vpnCandidate.interface?.addresses.first ?? "none"
        let p2pDst = vpnCandidate.interface?.destinationAddresses.first ?? (ifaces.first(where: { $0.destinationAddresses.contains("10.7.1.1") }) != nil ? "10.7.1.1" : "none")
        let bonjourSummary = BonjourRemotePairingDiscovery.shared.summaryForTrace()

        let ifaceEvent = BootstrapTraceEvent(
            elapsedMs: currentElapsedMs(),
            type: .interfaceSnapshot,
            details: [
                "configuredTarget": targetAddress,
                "vpnCandidateInterface": candidateName,
                "localIP": candidateLocalIP,
                "p2pDstAddr": p2pDst,
                "bonjourSummary": bonjourSummary,
                "interfaceCount": String(ifaces.count)
            ]
        )
        record.events.append(ifaceEvent)

        activeTrace = record
        latestTrace = record
    }

    func recordEvent(_ type: BootstrapTraceEventType, details: [String: String] = [:]) {
        guard var record = activeTrace else { return }
        let sanitizedDetails = sanitizeDetails(details)
        let event = BootstrapTraceEvent(
            elapsedMs: currentElapsedMs(),
            type: type,
            details: sanitizedDetails
        )
        record.events.append(event)
        activeTrace = record
        latestTrace = record
    }

    func finishTrace(outcome: String, failureStage: String? = nil, failureReason: String? = nil) {
        guard var record = activeTrace else { return }
        let now = Date()
        let elapsed = currentElapsedMs()
        record.completedAt = now
        record.overallDurationMs = elapsed
        record.outcome = outcome
        record.failureStage = failureStage
        record.failureReason = failureReason

        let finalType: BootstrapTraceEventType = (outcome == "SUCCESS" || outcome == "RESEARCH_DIRECT_TUNNEL_SUCCESS") ? .completed : .failed
        var details: [String: String] = ["outcome": outcome, "durationMs": String(format: "%.1f", elapsed)]
        if let failureStage { details["failureStage"] = failureStage }
        if let failureReason { details["failureReason"] = sanitizeString(failureReason) }

        let finalEvent = BootstrapTraceEvent(
            elapsedMs: elapsed,
            type: finalType,
            details: details
        )
        record.events.append(finalEvent)

        activeTrace = nil
        promoteTrace(record)
    }

    private func promoteTrace(_ record: BootstrapTraceRecord) {
        if let currentLatest = latestTrace, currentLatest.id != record.id {
            previousTrace = currentLatest
        } else if let prev = history.first {
            previousTrace = prev
        }
        latestTrace = record
        history.insert(record, at: 0)
        if history.count > 10 {
            history.removeLast()
        }
    }

    private func currentElapsedMs() -> Double {
        guard startUptime > 0 else { return 0 }
        let current = ProcessInfo.processInfo.systemUptime
        return max(0, (current - startUptime) * 1000.0)
    }

    // MARK: - Comparison Formatter

    func generateComparisonText() -> String {
        guard let latest = latestTrace else {
            return "尚無 Bootstrap 執行記錄。"
        }
        guard let prev = previousTrace else {
            return """
            【最新執行記錄】
            \(formatTraceSummary(latest))

            （尚無先前記錄可供比對）
            """
        }

        var lines: [String] = []
        lines.append("=== RouteLocation Bootstrap 比對報告 ===")
        lines.append("先前記錄 [\(prev.outcome)] vs 最新記錄 [\(latest.outcome)]")
        lines.append("")
        lines.append(String(format: "%-18@ %-16@ %-16@", "項目", "先前記錄", "最新記錄"))
        lines.append("--------------------------------------------------")
        lines.append(String(format: "%-18@ %-16@ %-16@", "模式", prev.mode, latest.mode))
        lines.append(String(format: "%-18@ %-16@ %-16@", "結果", prev.outcome, latest.outcome))
        lines.append(String(format: "%-18@ %-16@ %-16@", "初始傳輸", prev.initialTransport, latest.initialTransport))
        lines.append(String(format: "%-18@ %-16@ %-16@", "VPN 介面", prev.initialUsesVPN ? "YES" : "NO", latest.initialUsesVPN ? "YES" : "NO"))

        let prevRpp = prev.rpairingDurationMs.map { String(format: "%.0f ms", $0) } ?? "N/A"
        let latestRpp = latest.rpairingDurationMs.map { String(format: "%.0f ms", $0) } ?? "N/A"
        lines.append(String(format: "%-18@ %-16@ %-16@", "RPairing 耗時", prevRpp, latestRpp))

        let prevFfi = prev.rpairingFfiCode ?? "無"
        let latestFfi = latest.rpairingFfiCode ?? "無"
        lines.append(String(format: "%-18@ %-16@ %-16@", "RPairing FFI Code", prevFfi, latestFfi))

        let prevErrno = prev.rpairingPosixErrno ?? prev.rpairingErrno ?? "無"
        let latestErrno = latest.rpairingPosixErrno ?? latest.rpairingErrno ?? "無"
        lines.append(String(format: "%-18@ %-16@ %-16@", "RPairing POSIX Errno", prevErrno, latestErrno))

        let prevTotal = prev.overallDurationMs.map { String(format: "%.0f ms", $0) } ?? "N/A"
        let latestTotal = latest.overallDurationMs.map { String(format: "%.0f ms", $0) } ?? "N/A"
        lines.append(String(format: "%-18@ %-16@ %-16@", "總耗時", prevTotal, latestTotal))

        if let stage = latest.failureStage {
            lines.append("最新失敗階段: \(stage)")
        }
        if let reason = latest.failureReason {
            lines.append("最新失敗原因: \(reason)")
        }

        return lines.joined(separator: "\n")
    }

    func formatTraceSummary(_ trace: BootstrapTraceRecord) -> String {
        var lines: [String] = []
        lines.append("記錄 ID: \(trace.id.prefix(8)) | 交易: \(trace.txId.prefix(8))")
        lines.append("模式: \(trace.mode) | 結果: \(trace.outcome)")
        lines.append("目標: \(trace.targetAddress)")
        lines.append("初始傳輸: \(trace.initialTransport) (Wi-Fi: \(trace.initialWifiAvailable), Cell: \(trace.initialCellularAvailable), VPN: \(trace.initialUsesVPN))")
        if let total = trace.overallDurationMs {
            lines.append("總耗時: \(String(format: "%.1f", total)) ms")
        }
        if let rpp = trace.rpairingDurationMs {
            lines.append("RPairing 耗時: \(String(format: "%.1f", rpp)) ms")
        }
        if let ffi = trace.rpairingFfiCode {
            lines.append("RPairing FFI Code: \(ffi)")
        }
        if let errno = trace.rpairingPosixErrno {
            lines.append("RPairing POSIX Errno: \(errno)")
        } else if let errno = trace.rpairingErrno {
            lines.append("RPairing Errno: \(errno)")
        }
        if let stage = trace.failureStage {
            lines.append("失敗階段: \(stage)")
        }
        if let reason = trace.failureReason {
            lines.append("失敗原因: \(reason)")
        }
        lines.append("事件數: \(trace.events.count)")
        for ev in trace.events {
            lines.append(String(format: "  +%.0fms [%@] %@", ev.elapsedMs, ev.type.rawValue, ev.details.description))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Privacy & Redaction

    nonisolated func sanitizeDetails(_ details: [String: String]) -> [String: String] {
        var clean: [String: String] = [:]
        for (k, v) in details {
            clean[k] = sanitizeString(v)
        }
        return clean
    }

    nonisolated func sanitizeString(_ input: String) -> String {
        var text = input

        // 1. Redact cryptographic keys and certificates
        if text.contains("BEGIN RSA PRIVATE KEY") || text.contains("BEGIN PRIVATE KEY") || text.contains("BEGIN EC PRIVATE KEY") {
            return "[REDACTED_PRIVATE_KEY]"
        }
        if text.contains("BEGIN CERTIFICATE") {
            return "[REDACTED_CERTIFICATE]"
        }

        // 2. Redact file system paths
        if text.contains("/var/mobile/") || text.contains("/private/var/") || text.contains("/Users/") {
            text = text.replacingOccurrences(of: #"/var/mobile/Containers/[A-Za-z0-9/\-_.]+"#, with: "[REDACTED_CONTAINER_PATH]", options: .regularExpression)
            text = text.replacingOccurrences(of: #"/private/var/[A-Za-z0-9/\-_.]+"#, with: "[REDACTED_SYSTEM_PATH]", options: .regularExpression)
            text = text.replacingOccurrences(of: #"/Users/[A-Za-z0-9/\-_.]+"#, with: "[REDACTED_USER_PATH]", options: .regularExpression)
        }

        // 3. Redact explicit coordinates and coordinate pairs (lat / lon / pairs / floating numbers)
        text = text.replacingOccurrences(
            of: #"\b(lat|latitude)\s*[:=]\s*-?\d+\.\d+"#,
            with: "lat: [REDACTED_COORDINATE]",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: #"\b(lon|lng|longitude)\s*[:=]\s*-?\d+\.\d+"#,
            with: "lon: [REDACTED_COORDINATE]",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: #"\b(-?\d{1,3}\.\d{3,})\s*,\s*(-?\d{1,3}\.\d{3,})\b"#,
            with: "[REDACTED_COORDINATE],[REDACTED_COORDINATE]",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\b(-?\d{1,3}\.\d{4,})\b"#,
            with: "[REDACTED_COORDINATE]",
            options: .regularExpression
        )

        // 4. Redact UDIDs and serial fixtures
        text = text.replacingOccurrences(
            of: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{16}\b"#,
            with: "[REDACTED_UDID]",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\b[0-9a-fA-F]{40}\b"#,
            with: "[REDACTED_UDID]",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?i)\b(udid|serial|token|secret)\s*[:=]\s*[^\s,;]+"#,
            with: "$1: [REDACTED_CREDENTIAL]",
            options: .regularExpression
        )

        // 5. Redact Public IP addresses (protecting private 10.x.x.x, 127.0.0.1, 0.0.0.0, 192.168.x.x, 172.16-31.x.x)
        if let regex = try? NSRegularExpression(pattern: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#) {
            let nsStr = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsStr.length))
            for match in matches.reversed() {
                let ip = nsStr.substring(with: match.range)
                let isPrivate = ip.hasPrefix("10.") || ip == "127.0.0.1" || ip == "0.0.0.0" || ip.hasPrefix("192.168.") || ip.hasPrefix("172.")
                if !isPrivate {
                    text = (text as NSString).replacingCharacters(in: match.range, with: "[REDACTED_PUBLIC_IP]")
                }
            }
        }

        return text
    }

    // MARK: - Export File Generation

    func exportSafeTXTURL(trace: BootstrapTraceRecord? = nil) -> URL? {
        let rawTrace = trace ?? latestTrace
        let targetTrace = rawTrace?.sanitizedCopyForExport()
        let text: String
        if let targetTrace {
            text = formatTraceSummary(targetTrace)
        } else {
            text = generateComparisonText()
        }

        let dateStr = fileDateString()
        let filename = "RouteLocation-Diagnostic-\(dateStr).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    func exportSafeJSONURL(trace: BootstrapTraceRecord? = nil) -> URL? {
        let rawTrace = trace ?? latestTrace
        guard let targetTrace = rawTrace?.sanitizedCopyForExport() else { return nil }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(targetTrace)
            let dateStr = fileDateString()
            let filename = "RouteLocation-Diagnostic-\(dateStr).json"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func fileDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    #if DEBUG
    func resetForTesting() {
        activeTrace = nil
        latestTrace = nil
        previousTrace = nil
        history.removeAll()
        startUptime = 0
    }
    #endif
}
