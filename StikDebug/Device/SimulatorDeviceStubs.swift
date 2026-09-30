#if targetEnvironment(simulator)
import Foundation

/// The bundled idevice archive is built for physical iOS devices. These stubs
/// keep simulator-hosted route tests independent from hardware communication;
/// the physical-device target continues to compile and link the real bridge.
final class JITEnableContext {
    static let shared = JITEnableContext()

    private init() {}

    func startTunnel(targetIPAddress: String? = nil) throws {
        throw simulatorUnavailableError()
    }

    func checkTunnelHealth() throws {
        throw simulatorUnavailableError()
    }

    func getMountedDeviceCount() throws -> Int {
        throw simulatorUnavailableError()
    }

    func mountPersonalDDI(withImagePath imagePath: String, trustcachePath: String, manifestPath: String) throws {
        throw simulatorUnavailableError()
    }

    private func simulatorUnavailableError() -> NSError {
        NSError(
            domain: "RouteLocation.SimulatorDeviceBridge",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Device communication is unavailable in the iOS Simulator."]
        )
    }
}

enum LocationSimulationCommandQueue {
    static let shared = DispatchQueue(label: "com.routelocation.simulator-location-sim")
}

#if DEBUG
private var simulatorPreparedOverride = false
#endif

struct LocationSimulationSessionSnapshot: Sendable, Equatable {
    let isPrepared: Bool
}

enum LocationSimulationPreparationStage: String, Codable, Sendable {
    case pairingRead = "PAIRING_READ"
    case rpairing = "RPAIRING"
    case rsd = "RSD"
    case locationSimulationService = "LOCATION_SIMULATION_SERVICE"
    case ready = "READY"
}

struct LocationSimulationPreparationResult: Codable, Equatable, Sendable {
    let target: String
    let stage: LocationSimulationPreparationStage
    let statusCode: Int32
    let ffiCode: Int32?
    let ffiSubCode: Int32?
    let message: String?
    let durationMs: Double
    var isSuccess: Bool { stage == .ready && statusCode == 0 }
}

func prepare_location_simulation_session(_ deviceIP: String, _ pairingFile: String) -> LocationSimulationPreparationResult {
    LocationSimulationPreparationResult(target: "\(deviceIP):49152", stage: .pairingRead, statusCode: -1, ffiCode: nil, ffiSubCode: nil, message: "Device communication is unavailable in the iOS Simulator.", durationMs: 0)
}
func set_prepared_location(_ latitude: Double, _ longitude: Double) -> Int32 { -1 }
func has_prepared_location_simulation_session() -> Bool {
    #if DEBUG
    return simulatorPreparedOverride
    #else
    return false
    #endif
}
func cleanup_prepared_location_simulation_session() {
    #if DEBUG
    simulatorPreparedOverride = false
    #endif
}
func location_simulation_session_snapshot() -> LocationSimulationSessionSnapshot {
    LocationSimulationSessionSnapshot(isPrepared: has_prepared_location_simulation_session())
}

#if DEBUG
func location_simulation_set_prepared_for_testing(_ prepared: Bool) {
    simulatorPreparedOverride = prepared
}
#endif
func probe_location_simulation_session(_ deviceIP: String, _ pairingFile: String) -> LocationSimulationPreparationResult {
    prepare_location_simulation_session(deviceIP, pairingFile)
}

struct LocationClearOutcome: Sendable {
    let statusCode: Int32
    let stage: String
    let underlyingFfiCode: Int32?
    let underlyingFfiSubCode: Int32?
    let underlyingMessage: String?
    let reusedActiveSession: Bool
    let attemptedFreshBootstrap: Bool
}

func simulate_location(_ deviceIP: String, _ latitude: Double, _ longitude: Double, _ pairingFile: String) -> Int32 {
    -1
}

func clear_simulated_location(deviceIP: String? = nil, pairingFile: String? = nil) -> LocationClearOutcome {
    LocationClearOutcome(
        statusCode: -1,
        stage: "simulator-stub",
        underlyingFfiCode: nil,
        underlyingFfiSubCode: nil,
        underlyingMessage: "Device communication is unavailable in the iOS Simulator.",
        reusedActiveSession: false,
        attemptedFreshBootstrap: false
    )
}

func clear_simulated_location() -> Int32 {
    -1
}

func clear_simulated_location_retaining_session(deviceIP: String? = nil, pairingFile: String? = nil) -> LocationClearOutcome {
    clear_simulated_location(deviceIP: deviceIP, pairingFile: pairingFile)
}
#endif
