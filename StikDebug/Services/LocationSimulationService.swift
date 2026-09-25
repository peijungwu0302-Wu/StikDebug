import Foundation

enum LocationSimulationError: LocalizedError, Equatable {
    case invalidCoordinate
    case invalidTargetAddress
    case pairingFileMissing
    case pairingFileInvalid
    case deviceTunnelUnavailable
    case rsdDiscoveryFailure(code: Int32)
    case dvtSessionFailure(code: Int32)
    case updateFailure(code: Int32)
    case clearFailure(code: Int32, stage: String? = nil, ffiCode: Int32? = nil, ffiSubCode: Int32? = nil, message: String? = nil)

    var errorDescription: String? {
        switch self {
        case .invalidCoordinate: return L10n.text("座標無效。")
        case .invalidTargetAddress: return L10n.text("LocalDevVPN 目標位址無效。")
        case .pairingFileMissing: return L10n.text("請先在「設定」匯入這台裝置的配對檔案，再模擬位置。")
        case .pairingFileInvalid: return L10n.text("配對檔案無效或已過期，請用 iLoader 重新匯出。")
        case .deviceTunnelUnavailable: return L10n.text("請連接 LocalDevVPN 後再試一次。")
        case .rsdDiscoveryFailure(let code): return L10n.format("無法連接 RSD 裝置服務（錯誤 %d）。", code)
        case .dvtSessionFailure(let code): return L10n.format("裝置定位工作階段失敗（錯誤 %d）。", code)
        case .updateFailure(let code): return L10n.format("更新模擬位置失敗（錯誤 %d）。", code)
        case .clearFailure(let code, let stage, let ffiCode, let ffiSubCode, let message):
            var details: [String] = ["代碼 \(code)"]
            if let stage { details.append("階段: \(stage)") }
            if let ffiCode { details.append("FFI: \(ffiCode)") }
            if let ffiSubCode { details.append("Sub: \(ffiSubCode)") }
            if let message, !message.isEmpty { details.append("訊息: \(message)") }
            return L10n.format("恢復真實位置失敗（%@）。", details.joined(separator: ", "))
        }
    }

    var isRetryable: Bool {
        switch self {
        case .invalidCoordinate, .invalidTargetAddress, .pairingFileMissing, .pairingFileInvalid:
            return false
        case .deviceTunnelUnavailable, .rsdDiscoveryFailure, .dvtSessionFailure, .updateFailure, .clearFailure:
            return true
        }
    }
}

protocol LocationSimulationSink: Sendable {
    func setCoordinate(_ coordinate: RouteCoordinate) async throws
    func clearSimulatedLocation() async throws
}

final class DeviceLocationSimulationService: LocationSimulationSink, @unchecked Sendable {
    static let shared = DeviceLocationSimulationService()

    func setCoordinate(_ coordinate: RouteCoordinate) async throws {
        guard coordinate.isValid else { throw LocationSimulationError.invalidCoordinate }
        let pairingURL = PairingFileStore.prepareURL()
        guard FileManager.default.fileExists(atPath: pairingURL.path) else { throw LocationSimulationError.pairingFileMissing }
        let transport = await MainActor.run { ConnectionMonitor.shared.currentTransport.rawValue }
        LogManager.shared.addDebugLog(
            "Location update attempt: transport=\(transport), target=\(DeviceConnectionContext.targetIPAddress)"
        )
        let code: Int32 = await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async {
                continuation.resume(returning: simulate_location(
                    DeviceConnectionContext.targetIPAddress,
                    coordinate.latitude,
                    coordinate.longitude,
                    pairingURL.path
                ))
            }
        }
        guard code == 0 else {
            let error = Self.error(for: code)
            await MainActor.run {
                LocationDataPathHealth.shared.recordFailure(error)
                BootstrapTraceStore.shared.recordEvent(.firstLocationWriteFailed, details: ["error": error.localizedDescription])
                if BootstrapTraceStore.shared.isTraceInProgress && !CellularAssistedBootstrapStateMachine.shared.state.isRunning {
                    BootstrapTraceStore.shared.finishTrace(outcome: "FAILED", failureStage: "FirstLocationWrite", failureReason: error.localizedDescription)
                }
            }
            LogManager.shared.addWarningLog("Location update failed at \(Self.stageName(for: code)) (code=\(code))")
            throw error
        }
        await MainActor.run {
            LocationDataPathHealth.shared.recordSuccess()
            BootstrapTraceStore.shared.recordEvent(.firstLocationWriteSuccess)
            if BootstrapTraceStore.shared.isTraceInProgress && !CellularAssistedBootstrapStateMachine.shared.state.isRunning {
                BootstrapTraceStore.shared.finishTrace(outcome: "SUCCESS")
            }
            TunnelManager.shared.locationDataPathReady()
        }
    }

    func clearSimulatedLocation() async throws {
        let pairingURL = PairingFileStore.prepareURL()
        let pairingPath = FileManager.default.fileExists(atPath: pairingURL.path) ? pairingURL.path : nil
        let targetIP = DeviceConnectionContext.targetIPAddress

        let outcome: LocationClearOutcome = await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async {
                continuation.resume(returning: clear_simulated_location(
                    deviceIP: targetIP,
                    pairingFile: pairingPath
                ))
            }
        }
        LogManager.shared.addDebugLog("clear_simulated_location completed: status=\(outcome.statusCode), stage=\(outcome.stage), reusedSession=\(outcome.reusedActiveSession), freshBootstrap=\(outcome.attemptedFreshBootstrap)")
        guard outcome.statusCode == 0 else {
            throw LocationSimulationError.clearFailure(
                code: outcome.statusCode,
                stage: outcome.stage,
                ffiCode: outcome.underlyingFfiCode,
                ffiSubCode: outcome.underlyingFfiSubCode,
                message: outcome.underlyingMessage
            )
        }
    }

    private static func error(for code: Int32) -> LocationSimulationError {
        switch code {
        case 1: return .invalidTargetAddress
        case 2: return .pairingFileInvalid
        case 3: return .deviceTunnelUnavailable
        case 9: return .rsdDiscoveryFailure(code: code)
        case 10: return .dvtSessionFailure(code: code)
        default: return .updateFailure(code: code)
        }
    }

    private static func stageName(for code: Int32) -> String {
        switch code {
        case 1: return "target-address"
        case 2: return "pairing"
        case 3: return "localdevvpn-tunnel"
        case 9: return "rsd-discovery"
        case 10: return "dvt-session"
        case 11: return "location-update"
        default: return "unknown"
        }
    }
}

typealias LocationSimulationService = DeviceLocationSimulationService
