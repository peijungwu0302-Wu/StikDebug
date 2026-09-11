import SwiftUI

struct RouteEditorView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @State private var showPaste = false
    @State private var showImporter = false
    @State private var showSearch = false

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
                        Button(model.isResolvingNavigation ? "計算中…" : "使用 Apple 地圖計算") {
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
                        Spacer(); Button("匯入檔案") { showImporter = true }
                        Spacer(); Button("搜尋") { showSearch = true }
                    }
                    if model.selectedCoordinate != nil { Button("加入地圖所選位置") { model.addSelectedWaypoint() } }
                    Button("全部清除", role: .destructive) { model.clearWaypoints() }.disabled(model.waypoints.isEmpty)
                }

                Section("播放") {
                    HStack {
                        TextField("速度", value: $model.speedKmh, format: .number)
                            .keyboardType(.decimalPad)
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
                    Button("儲存路線") { Task { await model.saveCurrentRoute() } }
                        .disabled(model.geometry.totalDistance <= 0 || model.navigationGeometryNeedsRecalculation)
                }

                Section("已儲存路線") {
                    if model.savedRoutes.isEmpty { Text("尚無已儲存路線。").foregroundStyle(.secondary) }
                    ForEach(model.savedRoutes) { route in
                        Button { model.loadRoute(route) } label: {
                            VStack(alignment: .leading) {
                                Text(route.name).foregroundStyle(.primary)
                                Text("\(route.routeMode.title) • \(route.totalDistance.formattedRouteDistance) • \(route.preferredSpeedKmh.formatted(.number.precision(.fractionLength(1)))) km/h")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.swipeActions { Button("刪除", role: .destructive) { Task { await model.deleteRoute(route) } } }
                    }
                }
            }
            .navigationTitle("路線")
            .toolbar { EditButton() }
        }
        .sheet(isPresented: $showPaste) { CoordinatePasteView { model.replaceWaypoints($0) } }
        .sheet(isPresented: $showSearch) { LocationSearchPicker { model.addWaypoint($0) } }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: CoordinateImportParser.supportedContentTypes) { result in
            guard case .success(let url) = result else {
                if case .failure(let error) = result { model.presentedError = error.localizedDescription }
                return
            }
            Task.detached {
                do {
                    let values = try CoordinateImportParser.parse(url: url)
                    await MainActor.run { model.replaceWaypoints(values) }
                } catch { await MainActor.run { model.presentedError = error.localizedDescription } }
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

private extension Double {
    var formattedRouteDistance: String { self >= 1000 ? String(format: "%.2f km", self / 1000) : String(format: "%.0f m", self) }
}

private extension TimeInterval {
    var formattedDuration: String {
        let seconds = Int(self.rounded())
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}
