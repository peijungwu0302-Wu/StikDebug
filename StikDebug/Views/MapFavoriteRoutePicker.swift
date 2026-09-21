import SwiftUI

struct MapFavoriteRoutePicker: View {
    @EnvironmentObject private var model: RouteLocationModel
    @Environment(\.dismiss) private var dismiss
    let onSelect: (SavedRoute) -> Void

    private var favoriteRoutes: [SavedRoute] {
        model.savedRoutes.filter(\.isFavorite).sorted {
            ($0.lastUsedAt ?? $0.updatedAt) > ($1.lastUsedAt ?? $1.updatedAt)
        }
    }

    private var recentRoutes: [SavedRoute] {
        model.savedRoutes.filter { !$0.isFavorite && $0.lastUsedAt != nil }.sorted {
            ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast)
        }
    }

    private var otherRoutes: [SavedRoute] {
        model.savedRoutes.filter { !$0.isFavorite && $0.lastUsedAt == nil }.sorted {
            $0.updatedAt > $1.updatedAt
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if model.savedRoutes.isEmpty {
                    ContentUnavailableView(
                        L10n.text("尚未儲存路線"),
                        systemImage: "map",
                        description: Text(L10n.text("請先建立並儲存路線，即可在此快速選擇。"))
                    )
                } else {
                    if !favoriteRoutes.isEmpty {
                        Section(L10n.text("最愛路線")) {
                            ForEach(favoriteRoutes) { route in
                                routeRow(route)
                            }
                        }
                    }

                    if !recentRoutes.isEmpty {
                        Section(L10n.text("最近使用")) {
                            ForEach(recentRoutes) { route in
                                routeRow(route)
                            }
                        }
                    }

                    if !otherRoutes.isEmpty {
                        Section(L10n.text("全部路線")) {
                            ForEach(otherRoutes) { route in
                                routeRow(route)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.text("我的路線"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("關閉")) { dismiss() }
                        .accessibilityLabel(L10n.text("關閉"))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func routeRow(_ route: SavedRoute) -> some View {
        Button {
            onSelect(route)
            dismiss()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: route.isFavorite ? "star.fill" : "point.topleft.down.to.point.bottomright.curvepath")
                    .foregroundStyle(route.isFavorite ? .yellow : .blue)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(route.name)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    HStack(spacing: 8) {
                        Text(L10n.format("%d 個航點", route.waypoints.count))
                        Text("•")
                        Text(formatDistance(route.totalDistance))
                        Text("•")
                        Text(L10n.format("%.1f km/h", route.preferredSpeedKmh))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.format("選擇路線：%@", route.name))
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        }
        return String(format: "%d m", Int(meters))
    }
}
