import Foundation

/// Owns the production preparation path used by normal cellular bootstrap.
/// Research probes intentionally live in DirectCellularResearchService and
/// FullCellularResearchSuite; they must never be used as product readiness.
@MainActor
final class ProductionLocationSessionPreparer {
    static let shared = ProductionLocationSessionPreparer()

    private init() {}

    func prepare(
        endpointAddress: String,
        pairingFile: String,
        completion: @escaping @MainActor (LocationSimulationPreparationResult) -> Void
    ) {
        #if DEBUG
        if let mockPreparationResult {
            completion(mockPreparationResult(endpointAddress, pairingFile))
            return
        }
        #endif

        Task {
            let result = await withCheckedContinuation { continuation in
                LocationSimulationCommandQueue.shared.async {
                    continuation.resume(returning: prepare_location_simulation_session(endpointAddress, pairingFile))
                }
            }
            completion(result)
        }
    }

    #if DEBUG
    /// Deterministic seam for coordinator tests. It returns a preparation
    /// result only; no shortcut URL or real device operation is invoked.
    var mockPreparationResult: ((String, String) -> LocationSimulationPreparationResult)?

    func resetForTesting() {
        mockPreparationResult = nil
    }
    #endif
}
