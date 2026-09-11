import Foundation

enum LocationSimulationError: LocalizedError, Equatable {
    case invalidCoordinate
    case invalidTargetAddress
    case pairingFileMissing
    case pairingFileInvalid
    case deviceTunnelUnavailable
    case dvtSessionFailure(code: Int32)
    case updateFailure(code: Int32)
    case clearFailure(code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidCoordinate: return L10n.text("座標無效。")
        case .invalidTargetAddress: return L10n.text("LocalDevVPN 目標位址無效。")
        case .pairingFileMissing: return L10n.text("請先在「設定」匯入這台裝置的配對檔案，再模擬位置。")
        case .pairingFileInvalid: return L10n.text("配對檔案無效或已過期，請用 iLoader 重新匯出。")
        case .deviceTunnelUnavailable: return L10n.text("請連接 LocalDevVPN 後再試一次。")
        case .dvtSessionFailure(let code): return L10n.format("裝置定位工作階段失敗（錯誤 %d）。", code)
        case .updateFailure(let code): return L10n.format("更新模擬位置失敗（錯誤 %d）。", code)
        case .clearFailure(let code): return L10n.format("恢復真實位置失敗（錯誤 %d）。", code)
        }
    }
}

protocol LocationSimulationSink: Sendable {
    func setCoordinate(_ coordinate: RouteCoordinate) async throws
    func clearSimulatedLocation() async throws
}

final class DeviceLocationSimulationService: LocationSimulationSink, @unchecked Sendable {
    func setCoordinate(_ coordinate: RouteCoordinate) async throws {
        guard coordinate.isValid else { throw LocationSimulationError.invalidCoordinate }
        let pairingURL = PairingFileStore.prepareURL()
        guard FileManager.default.fileExists(atPath: pairingURL.path) else { throw LocationSimulationError.pairingFileMissing }
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
        guard code == 0 else { throw Self.error(for: code) }
    }

    func clearSimulatedLocation() async throws {
        let code: Int32 = await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async { continuation.resume(returning: clear_simulated_location()) }
        }
        guard code == 0 else { throw LocationSimulationError.clearFailure(code: code) }
    }

    private static func error(for code: Int32) -> LocationSimulationError {
        switch code {
        case 1: return .invalidTargetAddress
        case 2: return .pairingFileInvalid
        case 3, 9: return .deviceTunnelUnavailable
        case 10: return .dvtSessionFailure(code: code)
        default: return .updateFailure(code: code)
        }
    }
}
