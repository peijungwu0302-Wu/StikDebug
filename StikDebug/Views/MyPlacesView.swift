import SwiftUI

struct MyPlacesView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var tutorialUI: TutorialUIContext
    @EnvironmentObject private var tutorial: GuidedTutorialCoordinator
    @Binding var selectedTab: RouteLocationTab
    @State private var editingFavorite: FavoriteLocation?
    @State private var showAdd = false
    @State private var addingFavoriteCoordinate: RouteCoordinate?
    @State private var pendingDeleteIDs: Set<UUID> = []
    @State private var showDeleteConfirmation = false
    @State private var searchText = ""
    @AppStorage(LibraryDisplayDensity.preferenceKey) private var densityRawValue = LibraryDisplayDensity.compact.rawValue
    
    var body: some View {
        List {
            if filteredFavorites.isEmpty {
                ContentUnavailableView {
                    Label(
                        searchText.isEmpty ? L10n.text("尚無喜愛地點") : L10n.text("找不到喜愛地點"),
                        systemImage: "star"
                    )
                } description: {
                    Text(L10n.text(searchText.isEmpty
                        ? "請先在地圖選擇位置，再儲存為喜愛地點。"
                        : "請嘗試其他名稱或備註。"))
                } actions: {
                    if model.favorites.isEmpty {
                        Button(L10n.text("前往地圖")) { selectedTab = .map }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                ForEach(filteredFavorites) { favorite in
                    Button {
                        model.focusOnMap(favorite.coordinate)
                        tutorialUI.selectedFavoriteID = favorite.id
                        selectedTab = .map
                    } label: {
                        let density = LibraryDisplayDensity(rawValue: densityRawValue) ?? .compact
                        VStack(alignment: .leading, spacing: density == .compact ? 3 : 5) {
                            PlaceInfoSummary(name: favorite.name, coordinate: favorite.coordinate, density: density)
                            if let note = favorite.note, !note.isEmpty {
                                Text(note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tutorialTarget(.favoriteLibrary, when: favorite.id == tutorial.highlightedFavoriteID)
                    .swipeActions(edge: .trailing) {
                        Button(L10n.text("刪除"), role: .destructive) {
                            requestDelete(ids: [favorite.id])
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
                            requestDelete(ids: [favorite.id])
                        } label: {
                            Label(L10n.text("刪除"), systemImage: "trash")
                        }
                    }
                    .moveDisabled(model.librarySortOption != .manual || !searchText.isEmpty)
                }
                .onDelete { offsets in
                    let displayed = filteredFavorites
                    let selectedIDs = Set(offsets.compactMap { displayed.indices.contains($0) ? displayed[$0].id : nil })
                    requestDelete(ids: selectedIDs)
                }
                .onMove { offsets, destination in
                    guard model.librarySortOption == .manual, searchText.isEmpty else { return }
                    var ids = model.sortedFavorites.map(\.id)
                    ids.move(fromOffsets: offsets, toOffset: destination)
                    Task { await model.setManualFavoriteOrder(ids) }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: L10n.text("搜尋地點名稱或備註"))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton().disabled(model.librarySortOption != .manual || !searchText.isEmpty)
                Button { addingFavoriteCoordinate = model.selectedCoordinate; showAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityHint(L10n.text("請先在地圖選取位置。"))
                    .accessibilityLabel(L10n.text("新增喜愛地點"))
            }
        }
        .sheet(item: $editingFavorite) { favorite in
            FavoriteEditor(favorite: favorite) { name, note in
                Task { await model.updateFavorite(favorite, name: name, note: note) }
            }
        }
        .sheet(isPresented: $showAdd) {
            FavoriteEditor(favorite: nil, coordinate: addingFavoriteCoordinate) { name, note in
                Task { await model.addFavorite(name: name, note: note, coordinate: addingFavoriteCoordinate) }
            }
        }
        .confirmationDialog(L10n.text("刪除喜愛地點？"), isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button(L10n.text("刪除"), role: .destructive) {
                let ids = pendingDeleteIDs
                pendingDeleteIDs = []
                Task { await model.deleteFavorites(ids: ids) }
            }
            Button(L10n.text("取消"), role: .cancel) { pendingDeleteIDs = [] }
        } message: {
            Text(L10n.text("此操作不會影響最近位置。"))
        }
    }

    private var filteredFavorites: [FavoriteLocation] {
        let sorted = model.sortedFavorites
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) || ($0.note?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private func requestDelete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDeleteIDs = ids
        showDeleteConfirmation = true
    }
}

private struct PlaceInfoSummary: View {
    let name: String
    let coordinate: RouteCoordinate
    var density: LibraryDisplayDensity = .detailed
    @State private var info: PlaceInfo?
    @AppStorage("RouteLocation.timeZoneComparisonBaseline") private var baselineRawValue = TimeZoneComparisonBaseline.taiwan.rawValue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            summaryContent(now: context.date)
        }
        .task(id: coordinate.id) {
            let resolved = await PlaceInfoResolver.shared.resolve(coordinate)
            guard !Task.isCancelled else { return }
            info = resolved
        }
    }

    @ViewBuilder
    private func summaryContent(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if let flag = CountryFlagFormatter.flag(for: info?.countryCode) {
                    Text(flag)
                }
                Text(name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 0)
            }
            if let info {
                VStack(alignment: .leading, spacing: 2) {
                    if let areaText {
                        Text(areaText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if let name = info.bestDisplayName {
                        Text(name).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if density == .detailed, let country = info.country, !country.isEmpty {
                        Text(country).font(.caption).foregroundStyle(.secondary)
                    }
                    if density == .detailed {
                        CoordinateValueText(coordinate: coordinate)
                            .foregroundStyle(.secondary)
                    }
                    if density == .detailed, let timezoneDetails = timezoneDetails(at: now) {
                        Text(timezoneDetails.localAndGMT)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(timezoneDetails.identifier)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(timezoneDetails.offset)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                CoordinateValueText(coordinate: coordinate)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var areaText: String? {
        guard let info else { return nil }
        let values = [info.administrativeArea, info.locality, info.subLocality]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func timezoneDetails(at now: Date) -> (localAndGMT: String, identifier: String, offset: String)? {
        guard let info,
              let identifier = info.timeZoneIdentifier,
              let timeZone = TimeZone(identifier: identifier) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = timeZone
        let baseline = TimeZoneComparisonBaseline(rawValue: baselineRawValue) ?? .taiwan
        return (
            L10n.format("%@ · %@", formatter.string(from: now), PlaceTimeFormatter.gmtOffsetText(for: timeZone, at: now)),
            identifier,
            PlaceTimeFormatter.offsetText(for: timeZone, at: now, baseline: baseline)
        )
    }
}

private struct FavoriteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var note: String
    let favorite: FavoriteLocation?
    let coordinate: RouteCoordinate?
    let onSave: (String, String?) -> Void

    init(favorite: FavoriteLocation?, coordinate: RouteCoordinate? = nil, onSave: @escaping (String, String?) -> Void) {
        self.favorite = favorite
        self.coordinate = favorite?.coordinate ?? coordinate
        self.onSave = onSave
        _name = State(initialValue: favorite?.name ?? L10n.text("新地點"))
        _note = State(initialValue: favorite?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.text("名稱"), text: $name)
                TextField(L10n.text("備註（選填）"), text: $note, axis: .vertical)
                Section(L10n.text("儲存座標")) {
                    if let coordinate {
                        CoordinateValueText(coordinate: coordinate).foregroundStyle(.secondary)
                    } else {
                        Text(L10n.text("請先在地圖選取位置。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
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
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (favorite == nil && coordinate == nil))
                    .accessibilityLabel(L10n.text("儲存"))
                }
            }
        }
    }
}
