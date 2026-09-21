import MapKit
import SwiftUI

struct MapHomeView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var playback: RoutePlaybackEngine
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showSearch = false
    @State private var showCoordinateEntry = false
    @State private var showFavoritePlacePicker = false
    @State private var showFavoriteRoutePicker = false
    @State private var showSaveSheet = false
    @State private var showClearDraftAlert = false
    @State private var showFavoriteName = false
    @State private var showEndRouteOptions = false
    @State private var showMoreActions = false
    @State private var favoriteName = ""
    @FocusState private var isSpeedFieldFocused: Bool

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera) {
                    UserAnnotation()
                    if model.quickRouteMode == .singlePoint {
                        if let selected = model.selectedCoordinate {
                            Marker(L10n.text("已選位置"), coordinate: selected.clCoordinate).tint(.blue)
                        }
                    } else {
                        ForEach(Array(model.waypoints.enumerated()), id: \.offset) { index, waypoint in
                            Annotation(L10n.format("航點 %d", index + 1), coordinate: waypoint.clCoordinate) {
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
                    }
                    if let current = playback.currentCoordinate {
                        Annotation(L10n.text("目前模擬位置"), coordinate: current.clCoordinate) {
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
            .safeAreaInset(edge: .bottom) { floatingCardArea }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker(L10n.text("模式"), selection: $model.quickRouteMode) {
                        ForEach(QuickRouteInteractionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
                ToolbarItemGroup(placement: .topBarLeading) {
                    if model.quickRouteMode == .singlePoint {
                        Button { showFavoritePlacePicker = true } label: {
                            Label(L10n.text("我的最愛"), systemImage: "star.fill")
                        }
                        .accessibilityLabel(L10n.text("我的最愛"))
                    } else {
                        Button { showFavoriteRoutePicker = true } label: {
                            Label(L10n.text("我的路線"), systemImage: "star.circle.fill")
                        }
                        .accessibilityLabel(L10n.text("我的路線"))
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel(L10n.text("搜尋地點"))
                    Button { showCoordinateEntry = true } label: { Image(systemName: "number") }
                        .accessibilityLabel(L10n.text("輸入座標"))
                    if !model.geometry.coordinates.isEmpty {
                        Button { fitRoute() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .accessibilityLabel(L10n.text("顯示完整路線"))
                    }
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
        .sheet(isPresented: $showFavoritePlacePicker) {
            MapFavoritePlacePicker { favorite in
                model.focusOnMap(favorite.coordinate)
            }
        }
        .sheet(isPresented: $showFavoriteRoutePicker) {
            MapFavoriteRoutePicker { route in
                model.previewRoute(route)
                fitRoute()
            }
        }
        .sheet(isPresented: $showSaveSheet) {
            RouteSaveView(initialName: model.routeName, updatingExisting: model.hasLoadedRoute) { name, asCopy in
                Task { await model.saveCurrentRoute(named: name, asCopy: asCopy) }
            }
        }
        .alert(L10n.text("儲存喜好地點"), isPresented: $showFavoriteName) {
            TextField(L10n.text("名稱"), text: $favoriteName)
            Button(L10n.text("儲存")) { Task { await model.addFavorite(name: favoriteName); favoriteName = "" } }
            Button(L10n.text("取消"), role: .cancel) {}
        }
        .alert(L10n.text("清除草稿"), isPresented: $showClearDraftAlert) {
            Button(L10n.text("清除草稿"), role: .destructive) { model.clearCurrentDraft() }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("確定要清除目前的路線草稿嗎？"))
        }
        .confirmationDialog(
            L10n.text("路線已結束"),
            isPresented: $model.showEndRouteOptions,
            titleVisibility: .visible
        ) {
            Button(L10n.text("保持目前位置")) {
                model.showEndRouteOptions = false
            }
            Button(L10n.text("恢復真實定位"), role: .destructive) {
                model.showEndRouteOptions = false
                Task { await model.returnToRealLocation() }
            }
        } message: {
            Text(L10n.text("目前位置仍為模擬位置"))
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

    // MARK: - Floating Card Area

    @ViewBuilder
    private var floatingCardArea: some View {
        VStack(spacing: 0) {
            if let previewing = model.previewingRoute, !isPlaybackActiveForRoute(previewing) {
                // Route Preview Card
                RouteFloatingCard(
                    mode: .preview(previewing),
                    onStartRoute: { model.requestStartRoute(previewing) },
                    onEdit: {
                        model.loadRoute(previewing)
                        NotificationCenter.default.post(name: .switchToRoutesTab, object: nil)
                    },
                    onCancelPreview: { model.cancelRoutePreview() },
                    onEndRoute: {},
                    onRestoreRealLocation: {}
                )
            } else if isPlaybackActive {
                // Active Route Card
                RouteFloatingCard(
                    mode: .active,
                    onStartRoute: {},
                    onEdit: {},
                    onCancelPreview: {},
                    onEndRoute: { model.endRoute() },
                    onRestoreRealLocation: { Task { await model.returnToRealLocation() } }
                )
            } else if model.quickRouteMode == .singlePoint {
                singlePointFloatingContent
            } else {
                routeDraftFloatingContent
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private var isPlaybackActive: Bool {
        playback.state == .running || playback.state == .paused || playback.state == .reconnecting
    }

    private func isPlaybackActiveForRoute(_ route: SavedRoute) -> Bool {
        isPlaybackActive && playback.routeName == route.name
    }

    // MARK: - Single Point Content

    @ViewBuilder
    private var singlePointFloatingContent: some View {
        if let selected = model.selectedCoordinate {
            PlaceFloatingCard(
                coordinate: selected,
                onSaveFavorite: { showFavoriteName = true }
            )
        } else if model.simulationMode.isSimulating {
            // Active single point simulation
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "location.fill").foregroundStyle(.green)
                    Text(L10n.text("模擬位置中")).font(.subheadline.bold())
                    Spacer()
                    Text(model.simulationMode.label).font(.caption2).foregroundStyle(.secondary)
                }
                Button(L10n.text("恢復真實位置"), role: .destructive) {
                    Task { await model.returnToRealLocation() }
                }
                .font(.footnote)
                .accessibilityLabel(L10n.text("恢復真實定位"))
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        } else {
            // Empty state
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle().fill(model.connectionMonitor.effectiveTunnelHealthy ? .green : .orange).frame(width: 8, height: 8)
                    Text(model.connectionMonitor.effectiveTunnelHealthy
                         ? L10n.text("定位通道 · 已就緒")
                         : L10n.text("定位通道 · 需要處理"))
                        .font(.caption2)
                    Spacer()
                }
                Text(L10n.text("點選地圖、搜尋或選擇我的最愛"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Route Draft Content

    @ViewBuilder
    private var routeDraftFloatingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(model.connectionMonitor.effectiveTunnelHealthy ? .green : .orange).frame(width: 8, height: 8)
                Text(model.connectionMonitor.effectiveTunnelHealthy
                     ? L10n.text("定位通道 · 已就緒")
                     : L10n.text("定位通道 · 需要處理"))
                    .font(.caption2)
                Spacer()
            }

            if model.waypoints.isEmpty {
                HStack {
                    Text(L10n.text("點選地圖以新增航點"))
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button { showFavoriteRoutePicker = true } label: {
                        Label(L10n.text("我的路線"), systemImage: "star.circle.fill")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            } else if model.waypoints.count == 1 {
                HStack {
                    Text(L10n.text("已新增 1 個航點，請點選下一個航點"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("復原")) { model.undoLastWaypoint() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.text("建立路線")).font(.subheadline.bold())
                        Spacer()
                        Text(L10n.format("航點：%d", model.waypoints.count)).font(.footnote)
                        Text(L10n.format("· %@", model.geometry.totalDistance.formattedMapDistance)).font(.footnote)
                    }

                    HStack {
                        Picker(L10n.text("路線方式"), selection: $model.routeMode) {
                            ForEach(RouteMode.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                    }

                    if model.routeMode == .navigation {
                        HStack {
                            Picker(L10n.text("交通方式"), selection: $model.navigationTransport) {
                                ForEach(NavigationTransportMode.allCases) { Text($0.title).tag($0) }
                            }.pickerStyle(.segmented)
                            if model.navigationGeometryNeedsRecalculation {
                                Button(model.isResolvingNavigation ? L10n.text("計算中…") : L10n.text("計算導航")) {
                                    Task { await model.recalculateNavigation() }
                                }
                                .buttonStyle(.bordered)
                                .disabled(model.isResolvingNavigation || model.waypoints.count < 2)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Text(L10n.text("速度")).font(.caption).foregroundStyle(.secondary)
                        TextField("18.6", value: $model.speedKmh, format: .number)
                            .keyboardType(.decimalPad)
                            .focused($isSpeedFieldFocused)
                            .frame(width: 55)
                            .textFieldStyle(.roundedBorder)
                        Text("km/h").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Toggle(isOn: $model.isClosedLoop) {
                            Text(L10n.text("無限循環")).font(.caption)
                        }.toggleStyle(.button)
                    }

                    HStack {
                        Button(L10n.text("復原")) { model.undoLastWaypoint() }.buttonStyle(.bordered)
                        Button(L10n.text("清除"), role: .destructive) { showClearDraftAlert = true }.buttonStyle(.bordered)
                        Spacer()
                        Button(L10n.text("儲存路線")) { showSaveSheet = true }
                            .buttonStyle(.bordered)
                            .disabled(model.geometry.totalDistance <= 0 || model.navigationGeometryNeedsRecalculation)
                        Button(L10n.text("開始路線")) { Task { await model.startPlayback() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.geometry.totalDistance <= 0 || model.navigationGeometryNeedsRecalculation)
                            .accessibilityLabel(L10n.text("開始路線"))
                    }
                }
            }

            if model.simulationMode.isSimulating && !isPlaybackActive {
                Button(L10n.text("恢復真實位置"), role: .destructive) {
                    Task { await model.returnToRealLocation() }
                }
                .font(.footnote)
                .accessibilityLabel(L10n.text("恢復真實定位"))
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Helpers

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

// MARK: - Distance Formatting Extension

private extension CLLocationDistance {
    var formattedMapDistance: String {
        self >= 1000 ? String(format: "%.2f km", self / 1000) : String(format: "%.0f m", self)
    }
}
