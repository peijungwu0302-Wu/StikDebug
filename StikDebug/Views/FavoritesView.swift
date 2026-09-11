import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @State private var editingFavorite: FavoriteLocation?
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                if model.favorites.isEmpty {
                    ContentUnavailableView("尚無喜好地點", systemImage: "star", description: Text("請先在地圖選擇位置，再儲存為喜好地點。"))
                }
                ForEach(model.favorites) { favorite in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(favorite.name).font(.headline)
                        Text(String(format: "%.6f, %.6f", favorite.latitude, favorite.longitude)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let note = favorite.note, !note.isEmpty { Text(note).font(.caption) }
                        HStack {
                            Button("模擬") { Task { await model.teleport(to: favorite.coordinate) } }
                            Button("顯示於地圖") { model.selectedCoordinate = favorite.coordinate }
                            Button("加入路線") { model.addWaypoint(favorite.coordinate) }
                            Spacer(); Button { editingFavorite = favorite } label: { Image(systemName: "pencil") }
                        }.font(.caption)
                    }.padding(.vertical, 4)
                }.onDelete { offsets in Task { await model.deleteFavorites(at: offsets) } }
            }
            .navigationTitle("喜好地點")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                    Button { showAdd = true } label: { Image(systemName: "plus") }.disabled(model.selectedCoordinate == nil)
                }
            }
        }
        .sheet(item: $editingFavorite) { favorite in
            FavoriteEditor(favorite: favorite) { name, note in
                Task { await model.updateFavorite(favorite, name: name, note: note) }
            }
        }
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
            Form { TextField("名稱", text: $name); TextField("備註（選填）", text: $note, axis: .vertical) }
                .navigationTitle(favorite == nil ? "新增喜好地點" : "編輯喜好地點")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("儲存") { onSave(name, note.isEmpty ? nil : note); dismiss() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
                }
        }
    }
}
