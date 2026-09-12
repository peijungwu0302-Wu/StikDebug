import MapKit
import SwiftUI
import UIKit

struct AdaptiveRouteMapView: View {
    @EnvironmentObject private var model: RouteLocationModel

    var body: some View {
        if model.mapInteractionStyle == .quickRoute {
            QuickRouteMapView()
        } else {
            RouteMapView()
        }
    }
}

struct RouteMapView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var playback: RoutePlaybackEngine
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showSearch = false
    @State private var showFavoriteName = false
    @State private var showCoordinateEntry = false
    @State private var favoriteName = ""

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera) {
                    UserAnnotation()
                    if let selected = model.selectedCoordinate {
                        Marker("已選位置", coordinate: selected.clCoordinate).tint(.blue)
                    }
                    ForEach(Array(model.waypoints.enumerated()), id: \.offset) { index, waypoint in
                        Annotation("航點 \(index + 1)", coordinate: waypoint.clCoordinate) {
                            ZStack {
                                Circle().fill(.orange).frame(width: 28, height: 28)
                                Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white)
                            }
                        }
                    }
                    if model.geometry.coordinates.count > 1 {
                        MapPolyline(coordinates: model.geometry.coordinates.map(\.clCoordinate))
                            .stroke(.blue, lineWidth: 5)
                    }
                    if let current = playback.currentCoordinate {
                        Annotation("目前模擬位置", coordinate: current.clCoordinate) {
                            Image(systemName: "location.circle.fill")
                                .font(.title).foregroundStyle(.green).background(.white, in: Circle())
                        }
                    }
                }
                .mapControls { MapCompass(); MapScaleView(); MapUserLocationButton() }
                .onTapGesture { point in
                    if let coordinate = proxy.convert(point, from: .local) { model.select(coordinate) }
                }
            }
            .safeAreaInset(edge: .bottom) { controlCard }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("搜尋地點")
                    Button { showCoordinateEntry = true } label: { Image(systemName: "number") }
                        .accessibilityLabel("輸入座標")
                    Button { fitRoute() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .accessibilityLabel("顯示完整路線")
                        .disabled(model.geometry.coordinates.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showSearch) {
            LocationSearchPicker { coordinate in
                model.select(coordinate.clCoordinate)
                camera = .region(MKCoordinateRegion(center: coordinate.clCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
            }
        }
        .sheet(isPresented: $showCoordinateEntry) {
            CoordinateTeleportView { coordinate, simulateImmediately in
                model.selectedCoordinate = coordinate
                camera = .region(MKCoordinateRegion(center: coordinate.clCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
                if simulateImmediately {
                    model.requestSinglePointSimulation(at: coordinate)
                }
            }
        }
        .alert("儲存喜好地點", isPresented: $showFavoriteName) {
            TextField("名稱", text: $favoriteName)
            Button("儲存") { Task { await model.addFavorite(name: favoriteName); favoriteName = "" } }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: model.selectedCoordinate) { _, coordinate in
            guard let coordinate else { return }
            camera = .region(MKCoordinateRegion(center: coordinate.clCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
        }
        .onChange(of: model.mapFocusRevision) { _, _ in
            guard let coordinate = model.selectedCoordinate else { return }
            camera = .region(MKCoordinateRegion(center: coordinate.clCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
        }
    }

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(model.connectionMonitor.effectiveTunnelHealthy ? .green : .orange).frame(width: 9, height: 9)
                Text(model.connectionMonitor.connectionBannerText)
                    .font(.caption)
                Spacer()
                Text(playback.state.label).font(.caption).foregroundStyle(.secondary)
            }
            if let selected = model.selectedCoordinate {
                Text(String(format: "%.6f, %.6f", selected.latitude, selected.longitude))
                    .font(.footnote.monospaced()).textSelection(.enabled)
                HStack {
                    Button("模擬此位置") { model.requestSinglePointSimulation() }.buttonStyle(.borderedProminent)
                    Button("加入航點") { model.addSelectedWaypoint() }.buttonStyle(.bordered)
                    Button { showFavoriteName = true } label: { Image(systemName: "star") }.buttonStyle(.bordered)
                }
            } else {
                Text("點選地圖、搜尋地點、輸入座標，或選擇喜愛地點。").font(.footnote).foregroundStyle(.secondary)
                Button("輸入精確座標") { showCoordinateEntry = true }.buttonStyle(.bordered)
            }
            if model.geometry.totalDistance > 0 {
                HStack {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    Text(playback.state == .running || playback.state == .reconnecting ? playback.routeName : model.routeName)
                        .font(.headline).lineLimit(1)
                }
                HStack {
                    Label(model.geometry.totalDistance.formattedDistance, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    Spacer()
                    Text("\(model.speedKmh.formatted(.number.precision(.fractionLength(1)))) km/h")
                    if playback.state == .running || playback.state == .reconnecting {
                        Text("第 \(playback.lapNumber) 圈").fontWeight(.semibold)
                    }
                }.font(.footnote)
                HStack {
                    Button("開始路線") { Task { await model.startPlayback() } }.buttonStyle(.borderedProminent)
                    Button("停止") { playback.stop(clearMarker: true) }.buttonStyle(.bordered).tint(.red)
                        .disabled(playback.state != .running && playback.state != .reconnecting)
                    Button("清除路線", role: .destructive) { model.clearCurrentRoute() }.buttonStyle(.bordered)
                }
            }
            Button("恢復真實位置", role: .destructive) { Task { await model.returnToRealLocation() } }
                .font(.footnote)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal).padding(.bottom, 4)
    }

    private func fitRoute() {
        let coordinates = model.geometry.coordinates
        guard let first = coordinates.first else { return }
        var rect = MKMapRect(origin: MKMapPoint(first.clCoordinate), size: MKMapSize(width: 0, height: 0))
        for coordinate in coordinates.dropFirst() {
            rect = rect.union(MKMapRect(origin: MKMapPoint(coordinate.clCoordinate), size: .init(width: 0, height: 0)))
        }
        camera = .rect(rect.insetBy(dx: -max(rect.width * 0.15, 500), dy: -max(rect.height * 0.15, 500)))
    }
}

struct QuickRouteMapView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var playback: RoutePlaybackEngine
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showSearch = false
    @State private var showCoordinateEntry = false
    @State private var showSaveSheet = false
    @State private var showClearDraftAlert = false
    @State private var showFavoriteName = false
    @State private var favoriteName = ""
    @FocusState private var isSpeedFieldFocused: Bool

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera) {
                    UserAnnotation()
                    if let selected = model.selectedCoordinate {
                        Marker("已選位置", coordinate: selected.clCoordinate).tint(.blue)
                    }
                    ForEach(Array(model.waypoints.enumerated()), id: \.offset) { index, waypoint in
                        Annotation("航點 \(index + 1)", coordinate: waypoint.clCoordinate) {
                            ZStack {
                                Circle().fill(.orange).frame(width: 28, height: 28)
                                Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white)
                            }
                        }
                    }
                    if model.geometry.coordinates.count > 1 {
                        MapPolyline(coordinates: model.geometry.coordinates.map(\.clCoordinate))
                            .stroke(.blue, lineWidth: 5)
                    }
                    if let current = playback.currentCoordinate {
                        Annotation("目前模擬位置", coordinate: current.clCoordinate) {
                            Image(systemName: "location.circle.fill")
                                .font(.title).foregroundStyle(.green).background(.white, in: Circle())
                        }
                    }
                }
                .mapControls { MapCompass(); MapScaleView(); MapUserLocationButton() }
                .onTapGesture { point in
                    if let coordinate = proxy.convert(point, from: .local) {
                        if model.quickRouteMode == .route {
                            model.addWaypoint(RouteCoordinate(coordinate))
                        } else {
                            model.select(coordinate)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { quickControlCard }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("模式", selection: $model.quickRouteMode) {
                        ForEach(QuickRouteInteractionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("搜尋地點")
                    Button { showCoordinateEntry = true } label: { Image(systemName: "number") }
                        .accessibilityLabel("輸入座標")
                    Button { fitRoute() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .accessibilityLabel("顯示完整路線")
                        .disabled(model.geometry.coordinates.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showSearch) {
            LocationSearchPicker { coordinate in
                if model.quickRouteMode == .route {
                    model.addWaypoint(coordinate)
                    ToastManager.shared.show(L10n.text("已新增航點。"), kind: .success)
                } else {
                    model.select(coordinate.clCoordinate)
                }
                camera = .region(MKCoordinateRegion(center: coordinate.clCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
            }
        }
        .sheet(isPresented: $showCoordinateEntry) {
            CoordinateTeleportView { coordinate, simulateImmediately in
                if simulateImmediately {
                    model.requestSinglePointSimulation(at: coordinate)
                } else if model.quickRouteMode == .route {
                    model.addWaypoint(coordinate)
                    ToastManager.shared.show(L10n.text("已新增航點。"), kind: .success)
                } else {
                    model.selectedCoordinate = coordinate
                }
                camera = .region(MKCoordinateRegion(center: coordinate.clCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
            }
        }
        .sheet(isPresented: $showSaveSheet) {
            RouteSaveView(initialName: model.routeName, updatingExisting: model.hasLoadedRoute) { name, asCopy in
                Task { await model.saveCurrentRoute(named: name, asCopy: asCopy) }
            }
        }
        .alert("儲存喜好地點", isPresented: $showFavoriteName) {
            TextField("名稱", text: $favoriteName)
            Button("儲存") { Task { await model.addFavorite(name: favoriteName); favoriteName = "" } }
            Button("取消", role: .cancel) {}
        }
        .alert("清除草稿", isPresented: $showClearDraftAlert) {
            Button("清除草稿", role: .destructive) { model.clearCurrentDraft() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("確定要清除目前的路線草稿嗎？")
        }
        .onChange(of: model.selectedCoordinate) { _, coordinate in
            guard let coordinate else { return }
            camera = .region(MKCoordinateRegion(center: coordinate.clCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
        }
        .onChange(of: model.mapFocusRevision) { _, _ in
            guard let coordinate = model.selectedCoordinate else { return }
            camera = .region(MKCoordinateRegion(center: coordinate.clCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
        }
    }

    private var quickControlCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Circle().fill(model.connectionMonitor.effectiveTunnelHealthy ? .green : .orange).frame(width: 9, height: 9)
                Text(model.connectionMonitor.connectionBannerText)
                    .font(.caption)
                Spacer()
                Text(playback.state.label).font(.caption).foregroundStyle(.secondary)
            }

            if model.quickRouteMode == .singlePoint {
                singlePointContent
            } else {
                routeDraftContent
            }

            if playback.state == .running || playback.state == .reconnecting {
                Divider()
                HStack {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    Text(playback.routeName).font(.headline).lineLimit(1)
                    Spacer()
                    Text("第 \(playback.lapNumber) 圈").font(.subheadline.bold())
                }
                HStack {
                    Label(playback.traveledDistance.formattedDistance, systemImage: "figure.walk")
                    Spacer()
                    Text("\(playback.speedKmh.formatted(.number.precision(.fractionLength(1)))) km/h")
                    Button("停止") { playback.stop(clearMarker: true) }
                        .buttonStyle(.bordered).tint(.red)
                }.font(.footnote)
            }

            if model.simulationMode.isSimulating {
                Button("恢復真實位置", role: .destructive) {
                    Task { await model.returnToRealLocation() }
                }
                .font(.footnote)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal).padding(.bottom, 4)
    }

    @ViewBuilder
    private var singlePointContent: some View {
        if let selected = model.selectedCoordinate {
            Text(String(format: "%.6f, %.6f", selected.latitude, selected.longitude))
                .font(.footnote.monospaced()).textSelection(.enabled)
            HStack {
                Button("在此模擬") {
                    model.requestSinglePointSimulation()
                }
                .buttonStyle(.borderedProminent)

                Button("加入航點") {
                    model.addSelectedWaypoint()
                }
                .buttonStyle(.bordered)

                Button {
                    showFavoriteName = true
                } label: {
                    Image(systemName: "star")
                }
                .buttonStyle(.bordered)
            }
        } else {
            Text("在單點模式下點選地圖可選擇模擬位置。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("輸入精確座標") { showCoordinateEntry = true }.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var routeDraftContent: some View {
        HStack {
            Text("建立路線").font(.subheadline.bold())
            Spacer()
            Text("航點：\(model.waypoints.count)").font(.footnote)
            Text("距離：\(model.geometry.totalDistance.formattedDistance)").font(.footnote)
        }

        HStack {
            Text("路線方式").font(.caption).foregroundStyle(.secondary)
            Picker("路線方式", selection: $model.routeMode) {
                ForEach(RouteMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }

        if model.routeMode == .navigation {
            HStack {
                Picker("交通方式", selection: $model.navigationTransport) {
                    ForEach(NavigationTransportMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.navigationGeometryNeedsRecalculation {
                    Button(model.isResolvingNavigation ? "計算中…" : "計算導航") {
                        Task { await model.recalculateNavigation() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isResolvingNavigation || model.waypoints.count < 2)
                }
            }
        }

        HStack(spacing: 8) {
            Text("速度").font(.caption).foregroundStyle(.secondary)
            TextField("18.6", value: $model.speedKmh, format: .number)
                .keyboardType(.decimalPad)
                .focused($isSpeedFieldFocused)
                .frame(width: 55)
                .textFieldStyle(.roundedBorder)
            Text("km/h").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Toggle(isOn: $model.isClosedLoop) {
                Text("無限循環").font(.caption)
            }
            .toggleStyle(.button)
        }

        HStack {
            Button("復原") { model.undoLastWaypoint() }
                .buttonStyle(.bordered)
                .disabled(model.waypoints.isEmpty)

            Button("清除", role: .destructive) { showClearDraftAlert = true }
                .buttonStyle(.bordered)
                .disabled(model.waypoints.isEmpty)

            Spacer()

            Button("儲存路線") {
                showSaveSheet = true
            }
            .buttonStyle(.bordered)
            .disabled(model.geometry.totalDistance <= 0 || model.navigationGeometryNeedsRecalculation)

            Button("開始路線") {
                Task { await model.startPlayback() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.geometry.totalDistance <= 0 || model.navigationGeometryNeedsRecalculation)
        }
    }

    private func fitRoute() {
        let coordinates = model.geometry.coordinates
        guard let first = coordinates.first else { return }
        var rect = MKMapRect(origin: MKMapPoint(first.clCoordinate), size: MKMapSize(width: 0, height: 0))
        for coordinate in coordinates.dropFirst() {
            rect = rect.union(MKMapRect(origin: MKMapPoint(coordinate.clCoordinate), size: .init(width: 0, height: 0)))
        }
        camera = .rect(rect.insetBy(dx: -max(rect.width * 0.15, 500), dy: -max(rect.height * 0.15, 500)))
    }
}

private struct CoordinateTeleportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var coordinateText = ""
    @State private var errorMessage: String?
    let onSubmit: (RouteCoordinate, Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("座標") {
                    TextField("25.033964,121.564468", text: $coordinateText)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                    Text("依序輸入緯度與經度，使用逗號、分號或 Tab 分隔。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
                }
                Section("操作") {
                    Button("在地圖預覽") { submit(simulateImmediately: false) }
                    Button("立即模擬此座標") { submit(simulateImmediately: true) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("輸入精確座標")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
        }
    }

    private func submit(simulateImmediately: Bool) {
        do {
            guard let coordinate = try CoordinateImportParser.parseInline(coordinateText).first else {
                throw CoordinateImportError.noCoordinates
            }
            onSubmit(coordinate, simulateImmediately)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class LocationSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()
    override init() { super.init(); completer.delegate = self; completer.resultTypes = [.address, .pointOfInterest] }
    func update(_ query: String) { completer.queryFragment = query }
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let values = completer.results
        Task { @MainActor in self.results = values }
    }
    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

struct LocationSearchPicker: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var completer = LocationSearchCompleter()
    @State private var query = ""
    @State private var errorMessage: String?
    let onSelect: (RouteCoordinate) -> Void

    var body: some View {
        NavigationStack {
            List(completer.results, id: \.self) { result in
                Button { Task { await resolve(result) } } label: {
                    VStack(alignment: .leading) {
                        Text(result.title).foregroundStyle(.primary)
                        if !result.subtitle.isEmpty { Text(result.subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .overlay { if completer.results.isEmpty { ContentUnavailableView("搜尋 Apple 地圖", systemImage: "magnifyingglass", description: Text(errorMessage ?? "輸入地點或地址。")) } }
            .searchable(text: $query, prompt: "地點或地址")
            .onChange(of: query) { _, value in completer.update(value) }
            .navigationTitle("搜尋")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func resolve(_ completion: MKLocalSearchCompletion) async {
        do {
            let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
            guard let coordinate = response.mapItems.first?.placemark.coordinate else { return }
            onSelect(RouteCoordinate(coordinate)); dismiss()
        } catch { errorMessage = L10n.format("搜尋需要網際網路連線：%@", error.localizedDescription) }
    }
}

private extension CLLocationDistance {
    var formattedDistance: String {
        self >= 1000 ? String(format: "%.2f km", self / 1000) : String(format: "%.0f m", self)
    }
}
