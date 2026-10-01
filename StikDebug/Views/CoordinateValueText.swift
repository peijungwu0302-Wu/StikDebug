import SwiftUI

/// A read-only exact coordinate value styled by the app's coordinate-only
/// preference. Coordinate entry fields intentionally do not use this view.
struct CoordinateValueText: View {
    private let value: String

    init(coordinate: RouteCoordinate) {
        value = String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
    }

    init(value: String) {
        self.value = value
    }

    @AppStorage(CoordinateTextSizePreference.defaultsKey)
    private var sizeRawValue = CoordinateTextSizePreference.standard.rawValue

    private var preference: CoordinateTextSizePreference {
        CoordinateTextSizePreference.resolve(sizeRawValue)
    }

    var body: some View {
        Text(value)
            .font(preference.font)
            .monospacedDigit()
            .lineLimit(1)
    }
}
