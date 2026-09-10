#if targetEnvironment(simulator)
import Foundation

/// The bundled idevice archive is built for physical iOS devices. These stubs
/// keep simulator-hosted route tests independent from hardware communication;
/// the physical-device target continues to compile and link the real bridge.
final class JITEnableContext {
    static let shared = JITEnableContext()

    private init() {}

    func startTunnel() throws {
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

func simulate_location(_ deviceIP: String, _ latitude: Double, _ longitude: Double, _ pairingFile: String) -> Int32 {
    -1
}

func clear_simulated_location() -> Int32 {
    -1
}
#endif
