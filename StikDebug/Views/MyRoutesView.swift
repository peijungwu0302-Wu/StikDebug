import SwiftUI

struct MyRoutesView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var tutorial: GuidedTutorialCoordinator
    @Binding var selectedTab: RouteLocationTab
    @Binding var openEditorOnAppear: Bool
    @State private var renamingRoute: SavedRoute?
    @State private var routeToDelete: SavedRoute?
    @State private var showDeleteConfirmation = false
    @State private var showImporter = false
    @State private var showAdvancedEditor = false
    @State private var searchText = ""
    @State private var showingRecentlyUsed = false

    private var sortedRoutes: [SavedRoute] {
        let source = showingRecentlyUsed ? RouteLibrarySortPolicy.recentlyUsed(model.savedRoutes) : model.savedRoutes.sorted { $0.updatedAt > $1.updatedAt }
        guard !searchText.isEmpty else { return source }
        return source.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            Section {
                Picker(L10n.text("路線列表"), selection: $showingRecentlyUsed) {
                    Text(L10n.text("最近路線")).tag(true)
                    Text(L10n.text("所有路線")).tag(false)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }

            if sortedRoutes.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "map")
                } description: {
                    Text(L10n.text(searchText.isEmpty
                        ? (showingRecentlyUsed && !model.savedRoutes.isEmpty ? "尚無最近使用路線" : "請在地圖上規劃路線後儲存。")
                        : "請嘗試其他路線名稱。"))
                } actions: {
                    if searchText.isEmpty && model.savedRoutes.isEmpty {
                        Button(L10n.text("建立路線")) {
                            model.quickRouteMode = .route
                            selectedTab = .map
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                ForEach(sortedRoutes) { route in
                    routeRow(route)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: L10n.text("搜尋路線名稱"))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    if model.isAnyRouteActive {
                        model.presentedError = L10n.text("目前正在執行路線，請先結束目前路線後再編輯。")
                    } else {
                        showAdvancedEditor = true
                    }
                } label: {
                    Image(systemName: "pencil.and.list.clipboard")
                }
                .accessibilityLabel(L10n.text("編輯路線詳細資訊"))
                .disabled(model.isAnyRouteActive)
                .accessibilityHint(model.isAnyRouteActive ? L10n.text("路線播放中，請先停止路線再編輯。") : "")

                Button { showImporter = true } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel(L10n.text("匯入路線"))
                .disabled(model.isAnyRouteActive)
                .accessibilityHint(model.isAnyRouteActive ? L10n.text("路線播放中，請先停止路線再編輯。") : "")
            }
        }
        .sheet(item: $renamingRoute) { route in
            RouteRenameView(route: route, onRename: { name in
                Task { await model.renameRoute(route, to: name) }
            })
        }
        .sheet(isPresented: $showAdvancedEditor) { RouteEditorView() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: CoordinateImportParser.supportedContentTypes) { result in
            guard case .success(let url) = result else {
                if case .failure(let error) = result {
                    let nsError = error as NSError
                    if nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError {
                        model.presentedError = error.localizedDescription
                    }
                }
                return
            }
            Task { @MainActor in
                do {
                    let values = try await Task.detached { try CoordinateImportParser.parse(url: url) }.value
                    guard await model.importSavedRoute(values) != nil else { return }
                    selectedTab = .map
                } catch {
                    model.presentedError = error.localizedDescription
                }
            }
        }
        .confirmationDialog(L10n.text("刪除這條路線？"), isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button(L10n.text("刪除"), role: .destructive) {
                guard let route = routeToDelete else { return }
                Task { await model.deleteRoute(route) }
                routeToDelete = nil
            }
            Button(L10n.text("取消"), role: .cancel) { routeToDelete = nil }
        } message: {
            Text(L10n.text("刪除後無法復原。"))
        }
        .onChange(of: openEditorOnAppear, initial: true) { _, requested in
            guard requested else { return }
            guard !model.isAnyRouteActive else { openEditorOnAppear = false; return }
            showAdvancedEditor = true
            model.consumeRouteEditorRequest()
            openEditorOnAppear = false
        }
    }

    private func routeRow(_ route: SavedRoute) -> some View {
        HStack(spacing: 8) {
            Button {
                model.previewRoute(route)
                selectedTab = .map
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(route.name).font(.headline).foregroundStyle(.primary)
                        if route.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    }
                    Text(L10n.format("%d 航點 · %@", route.waypoints.count, route.totalDistance.formattedRouteDistance))
                        .font(.caption).foregroundStyle(.secondary)
                    if let lastUsedAt = route.lastUsedAt {
                        Text(L10n.format("最近使用：%@", relativeDate(lastUsedAt)))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tutorialTarget(.openSavedRoute, when: route.id == tutorial.highlightedRouteID)

            Button {
                model.requestStartRoute(route)
            } label: {
                Image(systemName: "play.fill")
                    .font(.caption.bold())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(L10n.format("開始路線：%@", route.name))
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                Task { await model.toggleFavoriteRoute(route) }
            } label: {
                Label(L10n.text(route.isFavorite ? "取消喜愛" : "加入喜愛"), systemImage: route.isFavorite ? "star.slash" : "star")
            }
            .tint(.yellow)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(L10n.text("刪除"), role: .destructive) {
                routeToDelete = route
                showDeleteConfirmation = true
            }
            Button(L10n.text("重新命名")) { renamingRoute = route }.tint(.blue)
        }
        .contextMenu {
            Button(L10n.text(model.pinnedQuickPlaybackRouteID == route.id ? "取消固定，使用自動挑選" : "固定為快捷播放路線")) {
                model.pinQuickPlaybackRoute(model.pinnedQuickPlaybackRouteID == route.id ? nil : route)
            }
            Button { model.previewRoute(route); selectedTab = .map } label: {
                Label(L10n.text("查看地圖"), systemImage: "map")
            }
            Button { model.requestStartRoute(route) } label: {
                Label(L10n.text("開始路線"), systemImage: "play.fill")
            }
            Button { Task { await model.toggleFavoriteRoute(route) } } label: {
                Label(L10n.text(route.isFavorite ? "取消喜愛" : "加入喜愛"), systemImage: route.isFavorite ? "star.slash" : "star")
            }
            Button { renamingRoute = route } label: {
                Label(L10n.text("重新命名"), systemImage: "pencil")
            }
            Button {
                if model.requestEditRoute(route) { showAdvancedEditor = true }
            } label: {
                Label(L10n.text("編輯詳細航點"), systemImage: "pencil.and.list.clipboard")
            }
            Button(role: .destructive) {
                routeToDelete = route
                showDeleteConfirmation = true
            } label: {
                Label(L10n.text("刪除"), systemImage: "trash")
            }
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let language = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey) ?? AppLanguage.traditionalChinese.rawValue
        formatter.locale = Locale(identifier: language)
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    private var emptyTitle: String {
        if !searchText.isEmpty { return L10n.text("找不到路線") }
        if showingRecentlyUsed && !model.savedRoutes.isEmpty { return L10n.text("尚無最近使用路線") }
        return L10n.text("尚無儲存路線")
    }
}

private struct RouteRenameView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    let route: SavedRoute
    let onRename: (String) -> Void

    init(route: SavedRoute, onRename: @escaping (String) -> Void) {
        self.route = route
        _name = State(initialValue: route.name)
        self.onRename = onRename
    }

    var body: some View {
        NavigationStack {
            Form { TextField(L10n.text("路線名稱"), text: $name) }
                .navigationTitle(L10n.text("重新命名"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.text("取消")) { dismiss() }.accessibilityLabel(L10n.text("取消"))
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.text("儲存")) { onRename(name); dismiss() }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityLabel(L10n.text("儲存"))
                    }
                }
        }
    }
}
