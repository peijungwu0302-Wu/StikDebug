import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @Binding var selectedTab: RouteLocationTab
    @State private var selection: FavoriteKind = .locations
    @State private var selectedLocation: FavoriteLocation?
    @State private var selectedRoute: SavedRoute?
    @State private var editingFavorite: FavoriteLocation?
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                Picker("喜愛類型", selection: $selection) {
                    ForEach(FavoriteKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if selection == .locations { locationContent } else { routeContent }
            }
            .navigationTitle("喜愛")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if selection == .locations {
                        EditButton()
                        Button { showAdd = true } label: { Image(systemName: "plus") }
                            .disabled(model.selectedCoordinate == nil)
                    }
                }
            }
        }
        .sheet(item: $selectedLocation) { favorite in
            FavoriteLocationDetailView(favorite: favorite, selectedTab: $selectedTab)
        }
        .sheet(item: $selectedRoute) { route in
            FavoriteRouteDetailView(route: route, selectedTab: $selectedTab)
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

    @ViewBuilder
    private var locationContent: some View {
        if model.favorites.isEmpty {
            ContentUnavailableView("尚無喜愛地點", systemImage: "star", description: Text("請先在地圖選擇位置，再儲存為喜愛地點。"))
        } else {
            ForEach(model.favorites) { favorite in
                Button { selectedLocation = favorite } label: {
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
                .swipeActions {
                    Button("刪除", role: .destructive) {
                        if let index = model.favorites.firstIndex(where: { $0.id == favorite.id }) {
                            Task { await model.deleteFavorites(at: IndexSet(integer: index)) }
                        }
                    }
                    Button("編輯") { editingFavorite = favorite }.tint(.blue)
                }
            }
            .onDelete { offsets in Task { await model.deleteFavorites(at: offsets) } }
        }
    }

    @ViewBuilder
    private var routeContent: some View {
        if model.favoriteRoutes.isEmpty {
            ContentUnavailableView("尚無喜愛路線", systemImage: "star", description: Text("請在路線列表向右滑動，將路線加入喜愛。"))
        } else {
            ForEach(model.favoriteRoutes) { route in
                Button { selectedRoute = route } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(route.name).font(.headline).foregroundStyle(.primary)
                            Text("\(route.routeMode.title) • \(route.totalDistance.formattedRouteDistance) • \(route.preferredSpeedKmh.formatted(.number.precision(.fractionLength(1)))) km/h")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("取消喜愛") { Task { await model.toggleFavoriteRoute(route) } }.tint(.yellow)
                }
            }
        }
    }
}

private enum FavoriteKind: String, CaseIterable, Identifiable {
    case locations, routes
    var id: String { rawValue }
    var title: String { L10n.text(self == .locations ? "地點" : "路線") }
}

private struct FavoriteLocationDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: RouteLocationModel
    let favorite: FavoriteLocation
    @Binding var selectedTab: RouteLocationTab

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("緯度", value: String(format: "%.6f", favorite.latitude))
                    LabeledContent("經度", value: String(format: "%.6f", favorite.longitude))
                    if let note = favorite.note, !note.isEmpty { Text(note) }
                }
                Section("操作") {
                    Button("模擬此位置") {
                        dismiss()
                        Task { await model.teleport(to: favorite.coordinate) }
                    }
                    Button("顯示於地圖") {
                        model.focusOnMap(favorite.coordinate)
                        selectedTab = .map
                        dismiss()
                    }
                    Button("加入目前路線") {
                        model.addWaypoint(favorite.coordinate)
                        model.statusMessage = L10n.text("已將喜愛地點加入路線。")
                        dismiss()
                    }
                }
            }
            .navigationTitle(favorite.name)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private struct FavoriteRouteDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: RouteLocationModel
    let route: SavedRoute
    @Binding var selectedTab: RouteLocationTab

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("類型", value: route.routeMode.title)
                    LabeledContent("距離", value: route.totalDistance.formattedRouteDistance)
                    LabeledContent("速度", value: "\(route.preferredSpeedKmh.formatted(.number.precision(.fractionLength(1)))) km/h")
                    LabeledContent("播放模式", value: route.playbackMode.title)
                }
                Section("操作") {
                    Button("載入並顯示於地圖") {
                        model.loadRoute(route)
                        selectedTab = .map
                        dismiss()
                    }
                    Button("立即開始播放") {
                        model.loadRoute(route)
                        selectedTab = .map
                        dismiss()
                        Task { await model.startPlayback() }
                    }
                    Button("取消喜愛") {
                        dismiss()
                        Task { await model.toggleFavoriteRoute(route) }
                    }
                }
            }
            .navigationTitle(route.name)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
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
                TextField("名稱", text: $name)
                TextField("備註（選填）", text: $note, axis: .vertical)
            }
            .navigationTitle(L10n.text(favorite == nil ? "新增喜愛地點" : "編輯喜愛地點"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { onSave(name, note.isEmpty ? nil : note); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
