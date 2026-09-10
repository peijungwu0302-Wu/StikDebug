import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @State private var editingFavorite: FavoriteLocation?
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                if model.favorites.isEmpty {
                    ContentUnavailableView("No Favorites", systemImage: "star", description: Text("Select a point on the map, then save it as a favorite."))
                }
                ForEach(model.favorites) { favorite in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(favorite.name).font(.headline)
                        Text(String(format: "%.6f, %.6f", favorite.latitude, favorite.longitude)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let note = favorite.note, !note.isEmpty { Text(note).font(.caption) }
                        HStack {
                            Button("Simulate") { Task { await model.teleport(to: favorite.coordinate) } }
                            Button("Show on Map") { model.selectedCoordinate = favorite.coordinate }
                            Button("Add to Route") { model.addWaypoint(favorite.coordinate) }
                            Spacer(); Button { editingFavorite = favorite } label: { Image(systemName: "pencil") }
                        }.font(.caption)
                    }.padding(.vertical, 4)
                }.onDelete { offsets in Task { await model.deleteFavorites(at: offsets) } }
            }
            .navigationTitle("Favorites")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                    Button { showAdd = true } label: { Image(systemName: "plus") }.disabled(model.selectedCoordinate == nil)
                }
            }
        }
        .sheet(item: $editingFavorite) { FavoriteEditor(favorite: $0) { name, note in Task { await model.updateFavorite($0, name: name, note: note) } } }
        .sheet(isPresented: $showAdd) { FavoriteEditor(favorite: nil) { name, note in Task { await model.addFavorite(name: name, note: note) } } }
    }
}

private struct FavoriteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var note: String
    let favorite: FavoriteLocation?
    let onSave: (String, String?) -> Void

    init(favorite: FavoriteLocation?, onSave: @escaping (String, String?) -> Void) {
        self.favorite = favorite
        self.onSave = onSave
        _name = State(initialValue: favorite?.name ?? "")
        _note = State(initialValue: favorite?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form { TextField("Name", text: $name); TextField("Note (optional)", text: $note, axis: .vertical) }
                .navigationTitle(favorite == nil ? "New Favorite" : "Edit Favorite")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(name, note.isEmpty ? nil : note); dismiss() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
                }
        }
    }
}
