import Foundation
import SwiftUI
import Testing

@testable import RouteLocation

struct V1_2_19SettingsUXTests {
    @Test func appearanceDefaultsToSystemAndMapsToNativeSchemes() {
        #expect(AppearancePreference.resolve(nil) == .system)
        #expect(AppearancePreference.resolve("unknown") == .system)
        #expect(AppearancePreference.system.colorScheme == nil)
        #expect(AppearancePreference.light.colorScheme == .light)
        #expect(AppearancePreference.dark.colorScheme == .dark)
        #expect(AppearancePreference.allCases.compactMap { AppearancePreference(rawValue: $0.rawValue) } == AppearancePreference.allCases)
    }

    @Test func coordinateTextSizeDefaultsToStandardAndKeepsItsScopeLocal() {
        #expect(CoordinateTextSizePreference.resolve(nil) == .standard)
        #expect(CoordinateTextSizePreference.resolve("unknown") == .standard)
        #expect(CoordinateTextSizePreference.smaller.fixedPointSize == 11)
        #expect(CoordinateTextSizePreference.standard.fixedPointSize == 13)
        #expect(CoordinateTextSizePreference.larger.fixedPointSize == 15)
        #expect(CoordinateTextSizePreference.followSystem.fixedPointSize == nil)
        #expect(CoordinateTextSizePreference.followSystem.usesDynamicType)
        #expect(CoordinateTextSizePreference.allCases.map(\.rawValue) == ["smaller", "standard", "larger", "followSystem"])
        #expect(CoordinateTextSizePreference.allCases.allSatisfy {
            CoordinateTextSizePreference.resolve($0.rawValue) == $0
        })
    }

    @Test func optionalDDIReadinessSkipsMountedAndInFlightWork() {
        #expect(OptionalDDIReadinessPolicy.shouldStartAttempt(isMounted: true, isMounting: false) == false)
        #expect(OptionalDDIReadinessPolicy.shouldStartAttempt(isMounted: false, isMounting: true) == false)
        #expect(OptionalDDIReadinessPolicy.shouldStartAttempt(isMounted: false, isMounting: false) == true)
    }

    @Test func healthCapabilityDistinguishesSignatureFailureFromUserDenial() {
        let entitlementError = HealthKitLastError(
            domain: "com.apple.healthkit",
            code: 4,
            localizedDescription: "Missing com.apple.developer.healthkit entitlement"
        )
        #expect(HealthKitCapabilityStatus.resolve(isAvailable: true, authorization: .notDetermined, lastError: entitlementError) == .signatureUnavailable)
        #expect(HealthKitCapabilityStatus.resolve(isAvailable: true, authorization: .sharingDenied, lastError: nil) == .permissionDenied)
        #expect(HealthKitCapabilityStatus.resolve(isAvailable: false, authorization: .unavailable, lastError: nil) == .deviceUnavailable)
    }

    @Test func favoriteSortPolicyUsesExistingManualOrderAsSingleSource() {
        let first = FavoriteLocation(name: "First", coordinate: RouteCoordinate(latitude: 25, longitude: 121))
        let second = FavoriteLocation(name: "Second", coordinate: RouteCoordinate(latitude: 35, longitude: 139))
        let sorted = FavoriteSortPolicy.sort(
            [second, first],
            option: .manual,
            manualOrder: [first.id, second.id],
            deviceCoordinate: nil
        )
        #expect(sorted.map(\.id) == [first.id, second.id])
        #expect(Set(sorted.map(\.id)).count == 2)
    }
}
