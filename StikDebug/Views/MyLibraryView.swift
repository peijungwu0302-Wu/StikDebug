import SwiftUI

struct MyLibraryView: View {
    @Binding var selectedTab: RouteLocationTab
    @State private var selectedSection: MyLibrarySection = .places
    @AppStorage("RouteLocation.libraryDisplayDensity") private var densityRawValue = LibraryDisplayDensity.compact.rawValue
    
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
                        Picker(L10n.text("顯示方式"), selection: $densityRawValue) {
                            ForEach(LibraryDisplayDensity.allCases) { density in
                                Text(density.title).tag(density.rawValue)
                            }
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
    @AppStorage("RouteLocation.libraryDisplayDensity") private var densityRawValue = LibraryDisplayDensity.compact.rawValue
    @State private var showClearConfirmation = false

    var body: some View {
        List {
            if model.recentLocations.isEmpty {
                ContentUnavailableView(L10n.text("尚無最近位置"), systemImage: "clock", description: Text(L10n.text("模擬位置或開始路線後，最近使用的位置會顯示在這裡。")))
            } else {
                ForEach(model.recentLocations) { item in
                    let density = LibraryDisplayDensity(rawValue: densityRawValue) ?? .compact
                    VStack(alignment: .leading, spacing: density == .compact ? 4 : 6) {
                        HStack(spacing: 5) {
                            Text(item.title ?? L10n.text("最近位置")).font(.headline)
                            Spacer()
                            Text(item.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                        if density == .detailed {
                            RecentPlaceInfo(coordinate: item.coordinate)
                        }
                        Text(String(format: "%.6f, %.6f", item.coordinate.latitude, item.coordinate.longitude))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        HStack {
                            Button(L10n.text("模擬")) { Task { await model.teleport(to: item.coordinate) } }
                            Button(L10n.text("加入喜愛")) { Task { await model.addFavorite(name: model.suggestedFavoriteName(), coordinate: item.coordinate) } }
                            Button(L10n.text("顯示於地圖")) { model.focusOnMap(item.coordinate); selectedTab = .map }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(L10n.text("刪除"), role: .destructive) { Task { await model.deleteRecentLocation(item) } }
                    }
                    .contextMenu {
                        Button { Task { await model.teleport(to: item.coordinate) } } label: { Label(L10n.text("再次模擬"), systemImage: "location.fill") }
                        Button { CoordinateClipboard.copy(item.coordinate) } label: { Label(L10n.text("複製座標"), systemImage: "doc.on.doc") }
                        Button { Task { await model.addFavorite(name: model.suggestedFavoriteName(), coordinate: item.coordinate) } } label: { Label(L10n.text("加入喜愛"), systemImage: "star") }
                        Button(role: .destructive) { Task { await model.deleteRecentLocation(item) } } label: { Label(L10n.text("刪除"), systemImage: "trash") }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.text("清除所有最近位置"), role: .destructive) { showClearConfirmation = true }
                    .disabled(model.recentLocations.isEmpty)
            }
        }
        .confirmationDialog(L10n.text("要清除所有最近位置嗎？"), isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button(L10n.text("清除所有最近位置"), role: .destructive) { Task { await model.clearRecentLocations() } }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("此操作不會影響收藏地點。"))
        }
    }
}

private struct RecentPlaceInfo: View {
    let coordinate: RouteCoordinate
    @State private var info: PlaceInfo?
    @AppStorage("RouteLocation.timeZoneComparisonBaseline") private var baselineRawValue = TimeZoneComparisonBaseline.taiwan.rawValue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let info {
                let area = [info.administrativeArea, info.locality, info.subLocality].compactMap { $0 }.joined(separator: " · ")
                HStack(spacing: 5) {
                    if let flag = CountryFlagFormatter.flag(for: info.countryCode) { Text(flag) }
                    Text(area.isEmpty ? (info.country ?? "") : area).font(.caption).foregroundStyle(.secondary)
                    if let id = info.timeZoneIdentifier, let zone = TimeZone(identifier: id) {
                        Text(PlaceTimeFormatter.gmtOffsetText(for: zone, at: context.date)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: coordinate.id) {
            info = await PlaceInfoResolver.shared.resolve(coordinate)
        }
    }
}
