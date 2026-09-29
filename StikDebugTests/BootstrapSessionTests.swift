import Foundation
import Testing
@testable import RouteLocation

struct BootstrapSessionTests {
    @Test func endpointStrategyUsesExpectedProductionAddresses() {
        #expect(BootstrapEndpointStrategy.resolvedAddress(mode: .localDevVPN, transport: .wifi) == "10.7.0.1")
        #expect(BootstrapEndpointStrategy.resolvedAddress(mode: .loopbackIPv4, transport: .cellular) == "127.0.0.1")
        #expect(BootstrapEndpointStrategy.resolvedAddress(mode: .automatic, transport: .wifi) == "10.7.0.1")
        #expect(BootstrapEndpointStrategy.resolvedAddress(mode: .automatic, transport: .cellular) == "127.0.0.1")
    }

    @Test func customEndpointValidationRejectsInvalidAddresses() {
        #expect(BootstrapEndpointStrategy.isValidIPv4("127.0.0.1"))
        #expect(BootstrapEndpointStrategy.isValidIPv4("10.7.0.1"))
        #expect(!BootstrapEndpointStrategy.isValidIPv4("10.7.1.1:49152"))
        #expect(!BootstrapEndpointStrategy.isValidIPv4("999.1.1.1"))
        #expect(!BootstrapEndpointStrategy.isValidIPv4(""))
    }

    @Test func preparationResultReadyIsTheOnlyPreparedState() {
        let ready = LocationSimulationPreparationResult(
            target: "127.0.0.1:49152", stage: .ready, statusCode: 0,
            ffiCode: nil, ffiSubCode: nil, message: nil, durationMs: 1
        )
        let rsdOnly = LocationSimulationPreparationResult(
            target: "127.0.0.1:49152", stage: .rsd, statusCode: 9,
            ffiCode: 16, ffiSubCode: nil, message: "Connection refused", durationMs: 1
        )
        #expect(ready.isSuccess)
        #expect(!rsdOnly.isSuccess)
    }

    @Test func researchTrialResultDoesNotRepresentALocationWrite() {
        // The trial value carries only preparation stages. A successful READY
        // value is deliberately not a location command or coordinate write.
        let trial = FullCellularFFITrial(LocationSimulationPreparationResult(
            target: "127.0.0.1:49152", stage: .ready, statusCode: 0,
            ffiCode: nil, ffiSubCode: nil, message: nil, durationMs: 0
        ))
        #expect(trial.stage == "READY")
        #expect(!trial.target.isEmpty)
    }
}
