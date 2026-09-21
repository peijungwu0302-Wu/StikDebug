import SwiftUI

struct MyPlacesView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @Binding var selectedTab: RouteLocationTab
    @State private var editingFavorite: FavoriteLocation?
    @State private var showAdd = false
    
    var body: some View {
        List {
            if model.favorites.isEmpty {
                ContentUnavailableView(
                    L10n.text("尚無喜愛地點"),
                    systemImage: "star",
                    description: Text(L10n.text("請先在地圖選擇位置，再儲存為喜愛地點。"))
                )
            } else {
                ForEach(model.favorites) { favorite in
                    Button {
                        model.focusOnMap(favorite.coordinate)
                        selectedTab = .map
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(favorite.name).font(.headline).foregroundStyle(.primary)
                            Text(String(format: "%.6f, %.6f", favorite.latitude, favorite.longitude))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            if let note = favorite.note, !note.isEmpty {
                                Text(note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(L10n.text("刪除"), role: .destructive) {
                            if let index = model.favorites.firstIndex(where: { $0.id == favorite.id }) {
                                Task { await model.deleteFavorites(at: IndexSet(integer: index)) }
                            }
                        }
                        Button(L10n.text("編輯")) {
                            editingFavorite = favorite
                        }.tint(.blue)
                    }
                    .contextMenu {
                        Button {
                            model.focusOnMap(favorite.coordinate)
                            selectedTab = .map
                        } label: {
                            Label(L10n.text("查看地圖"), systemImage: "map")
                        }
                        Button {
                            editingFavorite = favorite
                        } label: {
                            Label(L10n.text("編輯"), systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            if let index = model.favorites.firstIndex(where: { $0.id == favorite.id }) {
                                Task { await model.deleteFavorites(at: IndexSet(integer: index)) }
                            }
                        } label: {
                            Label(L10n.text("刪除"), systemImage: "trash")
                        }
                    }
                }
                .onDelete { offsets in
                    Task { await model.deleteFavorites(at: offsets) }
                }
            }
        }
        .listStyle(.plain)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()
                Button { showAdd = true } label: { Image(systemName: "plus") }
                    .disabled(model.selectedCoordinate == nil)
                    .accessibilityLabel(L10n.text("新增喜愛地點"))
            }
        }
        .sheet(item: $editingFavorite) { favorite in
            FavoriteEditor(favorite: favorite) { name, note in
                Task { await model.updateFavorite(favorite, name: name, note: note) }
            }
        }
        .sheet(isPresented: $showAdd) {
            FavoriteEditor(favorite: nil) { name, note in
                Task { await model.addFavorite(name: name, note: note) }
            }
        }
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
            Form {
                TextField(L10n.text("名稱"), text: $name)
                TextField(L10n.text("備註（選填）"), text: $note, axis: .vertical)
            }
            .navigationTitle(L10n.text(favorite == nil ? "新增喜愛地點" : "編輯喜愛地點"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("取消")) { dismiss() }
                        .accessibilityLabel(L10n.text("取消"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("儲存")) {
                        onSave(name, note.isEmpty ? nil : note)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel(L10n.text("儲存"))
                }
            }
        }
    }
}
