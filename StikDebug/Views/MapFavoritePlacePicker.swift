import SwiftUI

struct MapFavoritePlacePicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: RouteLocationModel
    
    let onSelect: (FavoriteLocation) -> Void
    
    var body: some View {
        NavigationStack {
            Group {
                if model.favorites.isEmpty {
                    ContentUnavailableView(L10n.text("尚無我的最愛"), systemImage: "star.slash", description: Text(L10n.text("您收藏的地點將會顯示在這裡。")))
                } else {
                    List(model.favorites) { favorite in
                        Button {
                            onSelect(favorite)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(.yellow)
                                    Text(favorite.name)
                                        .foregroundStyle(.primary)
                                }
                                
                                Text(String(format: "%.6f, %.6f", favorite.latitude, favorite.longitude))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.text("我的最愛"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("關閉")) {
                        dismiss()
                    }
                    .accessibilityLabel(L10n.text("關閉"))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
