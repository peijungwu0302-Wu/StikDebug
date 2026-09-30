import SwiftUI

struct MyLibraryView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @Binding var selectedTab: RouteLocationTab
    @State private var selectedSection: MyLibrarySection = .places
    @AppStorage(LibraryDisplayDensity.preferenceKey) private var densityRawValue = LibraryDisplayDensity.compact.rawValue
    @State private var showClearRecentConfirmation = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(L10n.text("資料庫"), selection: $selectedSection) {
                    ForEach(MyLibrarySection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                if selectedSection == .places {
                    MyPlacesView(selectedTab: $selectedTab)
                } else if selectedSection == .routes {
                    MyRoutesView(selectedTab: $selectedTab)
                } else {
                    RecentLocationsView(selectedTab: $selectedTab)
                }
            }
            .navigationTitle(L10n.text("我的"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if selectedSection == .places {
                            Picker(L10n.text("排序方式"), selection: $model.librarySortOption) {
                                ForEach(LibrarySortOption.allCases) { option in
                                    Text(option.title).tag(option)
                                }
                            }
                            Divider()
                        }
                        Picker(L10n.text("顯示方式"), selection: $densityRawValue) {
                            ForEach(LibraryDisplayDensity.allCases) { density in
                                Text(density.title).tag(density.rawValue)
                            }
                        }
                        if selectedSection == .recent {
                            Divider()
                            Button(L10n.text("清除所有最近位置"), role: .destructive) {
                                showClearRecentConfirmation = true
                            }
                            .disabled(model.recentLocations.isEmpty)
                        }
                    } label: {
                        Image(systemName: "rectangle.compress.vertical")
                    }
                    .accessibilityLabel(L10n.text("顯示方式"))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToRoutesTab)) { _ in
                selectedSection = .routes
            }
            .confirmationDialog(L10n.text("要清除所有最近位置嗎？"), isPresented: $showClearRecentConfirmation, titleVisibility: .visible) {
                Button(L10n.text("清除所有最近位置"), role: .destructive) {
                    Task { await model.clearRecentLocations() }
                }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: {
                Text(L10n.text("此操作不會影響收藏地點。"))
            }
        }
    }
}

private enum MyLibrarySection: String, CaseIterable, Identifiable, Hashable {
    case places, routes, recent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .places: return L10n.text("地點")
        case .routes: return L10n.text("路線")
        case .recent: return L10n.text("最近位置")
        }
    }
}

private struct RecentLocationsView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @Binding var selectedTab: RouteLocationTab
    @AppStorage(LibraryDisplayDensity.preferenceKey) private var densityRawValue = LibraryDisplayDensity.compact.rawValue

    var body: some View {
        List {
            if model.recentLocations.isEmpty {
                ContentUnavailableView(L10n.text("尚無最近位置"), systemImage: "clock", description: Text(L10n.text("模擬位置或開始路線後，最近使用的位置會顯示在這裡。")))
            } else {
                ForEach(model.recentLocations) { item in
                    let density = LibraryDisplayDensity(rawValue: densityRawValue) ?? .compact
                    RecentPlaceInfo(
                        coordinate: item.coordinate,
                        title: item.title ?? L10n.text("最近位置"),
                        density: density,
                        createdAt: item.createdAt
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.focusOnMap(item.coordinate)
                        selectedTab = .map
                    }
                    .swipeActions(edge: .trailing) {
                        Button(L10n.text("刪除"), role: .destructive) { Task { await model.deleteRecentLocation(item) } }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if !model.isFavorite(coordinate: item.coordinate) {
                            Button {
                                Task { await model.addFavoriteIfNeeded(name: item.title ?? model.suggestedFavoriteName(), coordinate: item.coordinate) }
                            } label: {
                                Label(L10n.text("加入喜愛"), systemImage: "star")
                            }
                            .tint(.yellow)
                        }
                    }
                    .contextMenu {
                        Button { Task { await model.teleport(to: item.coordinate) } } label: { Label(L10n.text("再次模擬"), systemImage: "location.fill") }
                        Button { CoordinateClipboard.copy(item.coordinate) } label: { Label(L10n.text("複製座標"), systemImage: "doc.on.doc") }
                        if !model.isFavorite(coordinate: item.coordinate) {
                            Button { Task { await model.addFavoriteIfNeeded(name: item.title ?? model.suggestedFavoriteName(), coordinate: item.coordinate) } } label: { Label(L10n.text("加入喜愛"), systemImage: "star") }
                        }
                        Button(role: .destructive) { Task { await model.deleteRecentLocation(item) } } label: { Label(L10n.text("刪除"), systemImage: "trash") }
                    }
                }
            }
        }
    }
}

private struct RecentPlaceInfo: View {
    let coordinate: RouteCoordinate
    let title: String
    let density: LibraryDisplayDensity
    let createdAt: Date
    @State private var info: PlaceInfo?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: density == .compact ? 2 : 4) {
                HStack(spacing: 5) {
                    if let flag = CountryFlagFormatter.flag(for: info?.countryCode) { Text(flag) }
                    Text(title).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
                }
                if let info {
                    let area = [info.administrativeArea, info.locality, info.subLocality]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    if !area.isEmpty {
                        Text(area).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if density == .detailed {
                        if let country = info.country, !country.isEmpty {
                            Text(country).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let details = timezoneDetails(at: context.date) {
                            Text(details.localAndGMT).font(.caption).foregroundStyle(.secondary)
                            Text(details.identifier).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(L10n.format("最近使用：%@", relativeDate(createdAt)))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text(String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: coordinate.id) {
            info = await PlaceInfoResolver.shared.resolve(coordinate)
        }
    }

    private func timezoneDetails(at date: Date) -> (localAndGMT: String, identifier: String)? {
        guard let identifier = info?.timeZoneIdentifier,
              let zone = TimeZone(identifier: identifier) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = zone
        return (
            L10n.format("%@ · %@", formatter.string(from: date), PlaceTimeFormatter.gmtOffsetText(for: zone, at: date)),
            identifier
        )
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let language = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey) ?? AppLanguage.traditionalChinese.rawValue
        formatter.locale = Locale(identifier: language)
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}
