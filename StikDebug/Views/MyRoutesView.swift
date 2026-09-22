import SwiftUI

struct MyRoutesView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @Binding var selectedTab: RouteLocationTab
    @State private var renamingRoute: SavedRoute?
    @State private var showImporter = false
    @State private var showAdvancedEditor = false
    
    var sortedRoutes: [SavedRoute] {
        model.savedRoutes.sorted(by: { $0.updatedAt > $1.updatedAt })
    }
    
    var body: some View {
        List {
            if model.savedRoutes.isEmpty {
                ContentUnavailableView(
                    L10n.text("尚無儲存路線"),
                    systemImage: "map",
                    description: Text(L10n.text("請在地圖上規劃路線後儲存。"))
                )
            } else {
                ForEach(sortedRoutes) { route in
                    Button {
                        model.previewRoute(route)
                        selectedTab = .map
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(route.name).font(.headline).foregroundStyle(.primary)
                                Text("\(route.routeMode.title) • \(route.totalDistance.formattedRouteDistance) • \(route.preferredSpeedKmh.formatted(.number.precision(.fractionLength(1)))) km/h")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if route.isFavorite {
                                Image(systemName: "star.fill").foregroundStyle(.yellow)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading) {
                        Button {
                            Task { await model.toggleFavoriteRoute(route) }
                        } label: {
                            Label(
                                L10n.text(route.isFavorite ? "取消喜愛" : "加入喜愛"),
                                systemImage: route.isFavorite ? "star.slash" : "star"
                            )
                        }
                        .tint(.yellow)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(L10n.text("刪除"), role: .destructive) {
                            Task { await model.deleteRoute(route) }
                        }
                        Button(L10n.text("重新命名")) {
                            renamingRoute = route
                        }.tint(.blue)
                    }
                    .contextMenu {
                        Button {
                            model.previewRoute(route)
                            selectedTab = .map
                        } label: {
                            Label(L10n.text("查看地圖"), systemImage: "map")
                        }
                        Button {
                            Task { await model.toggleFavoriteRoute(route) }
                        } label: {
                            Label(
                                L10n.text(route.isFavorite ? "取消喜愛" : "加入喜愛"),
                                systemImage: route.isFavorite ? "star.slash" : "star"
                            )
                        }
                        Button {
                            renamingRoute = route
                        } label: {
                            Label(L10n.text("重新命名"), systemImage: "pencil")
                        }
                        Button {
                            if model.requestEditRoute(route) {
                                showAdvancedEditor = true
                            }
                        } label: {
                            Label(L10n.text("編輯詳細航點"), systemImage: "pencil.and.list.clipboard")
                        }
                        Button(role: .destructive) {
                            Task { await model.deleteRoute(route) }
                        } label: {
                            Label(L10n.text("刪除"), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    if model.isAnyRouteActive {
                        model.presentedError = L10n.text("目前正在執行路線，請先結束目前路線後再編輯其他路線。")
                    } else {
                        showAdvancedEditor = true
                    }
                } label: {
                    Image(systemName: "pencil.and.list.clipboard")
                }
                .accessibilityLabel(L10n.text("編輯路線詳細資訊"))

                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel(L10n.text("匯入路線"))
            }
        }
        .sheet(item: $renamingRoute) { route in
            RouteRenameView(route: route, onRename: { name in
                Task { await model.renameRoute(route, to: name) }
            })
        }
        .sheet(isPresented: $showAdvancedEditor) {
            RouteEditorView()
        }
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
            Task.detached {
                do {
                    let values = try CoordinateImportParser.parse(url: url)
                    await MainActor.run {
                        model.replaceWaypoints(values)
                        model.statusMessage = L10n.format("已匯入 %d 個航點。", values.count)
                    }
                } catch {
                    await MainActor.run { model.presentedError = error.localizedDescription }
                }
            }
        }
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
            Form {
                TextField(L10n.text("路線名稱"), text: $name)
            }
            .navigationTitle(L10n.text("重新命名"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("取消")) { dismiss() }
                        .accessibilityLabel(L10n.text("取消"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("儲存")) {
                        onRename(name)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel(L10n.text("儲存"))
                }
            }
        }
    }
}
