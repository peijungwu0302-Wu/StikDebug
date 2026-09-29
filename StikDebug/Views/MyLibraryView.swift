import SwiftUI

struct MyLibraryView: View {
    @Binding var selectedTab: RouteLocationTab
    @State private var selectedSection: MyLibrarySection = .places
    
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

    var body: some View {
        List {
            if model.recentLocations.isEmpty {
                ContentUnavailableView(L10n.text("尚無最近位置"), systemImage: "clock", description: Text(L10n.text("模擬位置或開始路線後，最近使用的位置會顯示在這裡。")))
            } else {
                ForEach(model.recentLocations) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title ?? L10n.text("最近位置")).font(.headline)
                        Text(String(format: "%.6f, %.6f", item.coordinate.latitude, item.coordinate.longitude))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        HStack {
                            Button(L10n.text("模擬")) { Task { await model.teleport(to: item.coordinate) } }
                            Button(L10n.text("加入喜愛")) { Task { await model.addFavorite(name: "", coordinate: item.coordinate) } }
                            Button(L10n.text("顯示於地圖")) { model.focusOnMap(item.coordinate); selectedTab = .map }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.text("清除記錄"), role: .destructive) { Task { await model.clearRecentLocations() } }
                    .disabled(model.recentLocations.isEmpty)
            }
        }
    }
}
