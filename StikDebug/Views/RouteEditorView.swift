import SwiftUI
import UIKit

struct RouteEditorView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @State private var showPaste = false
    @State private var showImporter = false
    @State private var showSearch = false
    @State private var showSaveSheet = false
    @State private var renamingRoute: SavedRoute?
    @FocusState private var speedFieldFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section("路線") {
                    TextField("路線名稱", text: $model.routeName)
                    Picker("路線類型", selection: $model.routeMode) {
                        ForEach(RouteMode.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    if model.routeMode == .navigation {
                        Picker("交通方式", selection: $model.navigationTransport) {
                            ForEach(NavigationTransportMode.allCases) { Text($0.title).tag($0) }
                        }
                        if model.navigationGeometryNeedsRecalculation {
                            Label("路線需要重新計算", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        Button(L10n.text(model.isResolvingNavigation ? "計算中…" : "使用 Apple 地圖計算")) {
                            Task { await model.recalculateNavigation() }
                        }.disabled(model.isResolvingNavigation || model.waypoints.count < 2)
                    }
                    Toggle("封閉路線", isOn: $model.isClosedLoop)
                }

                Section("航點（\(model.waypoints.count)）") {
                    ForEach(Array(model.waypoints.enumerated()), id: \.offset) { index, waypoint in
                        WaypointRow(index: index, waypoint: waypoint) { latitude, longitude in
                            model.updateWaypoint(at: index, latitude: latitude, longitude: longitude)
                        }
                    }
                    .onDelete(perform: model.removeWaypoints)
                    .onMove(perform: model.moveWaypoints)
                    HStack {
                        Button("貼上") { showPaste = true }
                        Spacer(); Button("匯入檔案") {
                            showPaste = false
                            showSearch = false
                            showImporter = true
                        }
                        Spacer(); Button("搜尋") { showSearch = true }
                    }
                    .buttonStyle(.borderless)
                    Text("支援文字、CSV、JSON、GeoJSON、GPX 與 KML。")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.selectedCoordinate != nil { Button("加入地圖所選位置") { model.addSelectedWaypoint() } }
                    Button("全部清除", role: .destructive) { model.clearWaypoints() }.disabled(model.waypoints.isEmpty)
                }

                Section("播放") {
                    HStack {
                        TextField("速度", value: $model.speedKmh, format: .number)
                            .keyboardType(.decimalPad)
                            .focused($speedFieldFocused)
                        Text("km/h").foregroundStyle(.secondary)
                    }
                    Picker("模式", selection: $model.playbackMode) {
                        ForEach(RoutePlaybackMode.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("距離", value: model.geometry.totalDistance.formattedRouteDistance)
                    LabeledContent("預估單圈時間", value: model.estimatedLapDuration?.formattedDuration ?? "—")
                    Button("開始播放") { Task { await model.startPlayback() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.geometry.totalDistance <= 0 || model.navigationGeometryNeedsRecalculation)
                    Button("儲存路線") { speedFieldFocused = false; showSaveSheet = true }
                        .disabled(model.geometry.totalDistance <= 0 || model.navigationGeometryNeedsRecalculation)
                }

                Section("已儲存路線") {
                    if model.savedRoutes.isEmpty { Text("尚無已儲存路線。").foregroundStyle(.secondary) }
                    ForEach(model.savedRoutes) { route in
                        Button { model.loadRoute(route) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(route.name).foregroundStyle(.primary)
                                    Text("\(route.routeMode.title) • \(route.totalDistance.formattedRouteDistance) • \(route.preferredSpeedKmh.formatted(.number.precision(.fractionLength(1)))) km/h")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if route.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading) {
                            Button { Task { await model.toggleFavoriteRoute(route) } } label: {
                                Label(route.isFavorite ? "取消喜愛" : "加入喜愛", systemImage: route.isFavorite ? "star.slash" : "star")
                            }.tint(.yellow)
                        }
                        .swipeActions {
                            Button("刪除", role: .destructive) { Task { await model.deleteRoute(route) } }
                            Button("重新命名") { renamingRoute = route }.tint(.blue)
                        }
                        .contextMenu {
                            Button { Task { await model.toggleFavoriteRoute(route) } } label: {
                                Label(route.isFavorite ? "取消喜愛" : "加入喜愛", systemImage: route.isFavorite ? "star.slash" : "star")
                            }
                            Button("重新命名") { renamingRoute = route }
                        }
                    }
                }
            }
            .navigationTitle("路線")
            .toolbar { EditButton() }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        speedFieldFocused = false
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
        }
        .sheet(isPresented: $showPaste) { CoordinatePasteView { model.replaceWaypoints($0) } }
        .sheet(isPresented: $showSearch) { LocationSearchPicker { model.addWaypoint($0) } }
        .sheet(isPresented: $showSaveSheet) {
            RouteSaveView(initialName: model.routeName, updatingExisting: model.hasLoadedRoute) { name, asCopy in
                Task { await model.saveCurrentRoute(named: name, asCopy: asCopy) }
            }
        }
        .sheet(item: $renamingRoute) { route in
            RouteRenameView(route: route) { name in Task { await model.renameRoute(route, to: name) } }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: CoordinateImportParser.supportedContentTypes) { result in
            showSearch = false
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
                } catch { await MainActor.run { model.presentedError = error.localizedDescription } }
            }
        }
        .onDisappear {
            speedFieldFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
}

private struct RouteSaveView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    let updatingExisting: Bool
    let onSave: (String, Bool) -> Void

    init(initialName: String, updatingExisting: Bool, onSave: @escaping (String, Bool) -> Void) {
        _name = State(initialValue: initialName)
        self.updatingExisting = updatingExisting
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("路線名稱", text: $name)
                if updatingExisting {
                    Text("你可以更新目前路線，或保留原路線並另存一份。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("儲存路線")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if updatingExisting {
                        Button("另存新路線") { save(asCopy: true) }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Button(L10n.text(updatingExisting ? "更新" : "儲存")) { save(asCopy: false) }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save(asCopy: Bool) {
        onSave(name, asCopy)
        dismiss()
    }
}

private struct RouteRenameView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    let route: SavedRoute
    let onSave: (String) -> Void

    init(route: SavedRoute, onSave: @escaping (String) -> Void) {
        self.route = route
        self.onSave = onSave
        _name = State(initialValue: route.name)
    }

    var body: some View {
        NavigationStack {
            Form { TextField("路線名稱", text: $name) }
                .navigationTitle("重新命名路線")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("儲存") { onSave(name); dismiss() }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

private struct WaypointRow: View {
    let index: Int
    let waypoint: RouteCoordinate
    let onSave: (Double, Double) -> Void
    @State private var latitude = ""
    @State private var longitude = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text("航點 \(index + 1)").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("緯度", text: $latitude).keyboardType(.numbersAndPunctuation)
                TextField("經度", text: $longitude).keyboardType(.numbersAndPunctuation)
                Button("更新") { if let lat = Double(latitude), let lon = Double(longitude) { onSave(lat, lon) } }
                    .font(.caption)
            }
        }
        .onAppear { updateText(waypoint) }
        .onChange(of: waypoint) { _, value in updateText(value) }
    }

    private func updateText(_ value: RouteCoordinate) {
        latitude = String(format: "%.6f", value.latitude)
        longitude = String(format: "%.6f", value.longitude)
    }
}

struct CoordinatePasteView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    let onImport: ([RouteCoordinate]) -> Void
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                Text("每行輸入一組緯度,經度；支援 CSV 標題、分號與 Tab 分隔。").font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $text).font(.body.monospaced()).border(.quaternary)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }.padding().navigationTitle("貼上座標")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("匯入") { parse() } }
                }
        }
    }
    private func parse() {
        do { onImport(try CoordinateImportParser.parseInline(text)); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

extension Double {
    var formattedRouteDistance: String { self >= 1000 ? String(format: "%.2f km", self / 1000) : String(format: "%.0f m", self) }
}

extension TimeInterval {
    var formattedDuration: String {
        let seconds = Int(self.rounded())
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}
