import Foundation
@testable import RouteLocation

@MainActor
enum TestBootstrapEnvironment {
    static func reset(policy: CellularBootstrapPolicy = .directOnly) {
        ConnectionMonitor.shared.updateForTesting(
            transport: .wifi,
            isWifiAvailable: true,
            isCellularAvailable: false,
            deviceSession: .idle
        )
        LocationDataPathHealth.shared.resetForTesting()
        BootstrapCoordinator.shared.resetForTesting()
        CellularAssistedBootstrapStateMachine.shared.resetForTesting()
        ShortcutBootstrapService.shared.resetForTesting(resetConfiguration: true)
        ShortcutBootstrapService.shared.cellularBootstrapPolicy = policy
        DirectCellularResearchService.shared.resetForTesting()
        BootstrapTraceStore.shared.resetForTesting()
    }
}
