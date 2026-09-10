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
        case .invalidCoordinate: return "The coordinate is invalid."
        case .invalidTargetAddress: return "The LocalDevVPN target address is invalid."
        case .pairingFileMissing: return "Import a pairing file before simulating location."
        case .pairingFileInvalid: return "The pairing file is invalid or expired."
        case .deviceTunnelUnavailable: return "Connect LocalDevVPN and retry."
        case .dvtSessionFailure(let code): return "The device location session failed (error \(code))."
        case .updateFailure(let code): return "The location update failed (error \(code))."
        case .clearFailure(let code): return "Returning to the real location failed (error \(code))."
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
