import MapKit
import SwiftUI
import UIKit

struct AdaptiveRouteMapView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var tutorial: GuidedTutorialCoordinator

    var body: some View {
        if model.mapInteractionStyle == .classic && !tutorial.isActive {
            RouteMapView()
        } else {
            MapHomeView()
        }
    }
}

struct RouteMapView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var playback: RoutePlaybackEngine
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @StateObject private var s2Grid = S2GridController()
    @State private var projectedViewportWidth: Double?
    @State private var projectedViewportLatitude: Double?
    @AppStorage("RouteLocation.s2GridEnabled") private var s2GridEnabled = true
    @AppStorage("RouteLocation.s2GridLevelMode") private var s2GridLevelRawValue = "17"
    @State private var showSearch = false
    @State private var showFavoriteName = false
    @State private var showFavoriteRouteName = false
    @State private var showCoordinateEntry = false
    @State private var showMyRoutes = false
    @State private var favoriteName = ""
    @State private var favoriteRouteName = ""
    @State private var favoriteCoordinate: RouteCoordinate?
    @State private var isCardExpanded = true

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                GeometryReader { mapGeometry in
                    Map(position: $camera) {
                        RouteMapOverlayContent(
                            s2Cells: s2Grid.result.cells,
                            selection: model.selectedCoordinate,
                            showsSelection: true,
                            waypoints: displayWaypoints,
                            routeCoordinates: displayCoordinates,
                            showsRoute: RouteMapOverlayPolicy.shouldShowRouteGeometry(
                                mode: model.quickRouteMode,
                                hasPreview: model.previewingRoute != nil,
                                routeIsActive: model.isAnyRouteActive
                            ),
                            activeCoordinate: playback.currentCoordinate ?? model.activeSimulatedCoordinate
                        )
                    }
                    .mapControls { MapCompass(); MapScaleView(); MapUserLocationButton() }
                    .onTapGesture { point in
                        guard let coordinate = proxy.convert(point, from: .local) else { return }
                        switch MapTapRoutePolicy.action(mode: model.quickRouteMode, routeIsActive: model.isAnyRouteActive) {
                        case .addWaypoint:
                            model.addWaypoint(RouteCoordinate(coordinate))
                        case .selectPlace:
                            model.select(coordinate)
                        case .ignoreWhileRouteActive:
                            return
                        }
                    }
                    .onMapCameraChange(frequency: .onEnd) { context in
                        projectedViewportWidth = context.rect.size.width
                        let center = MKMapPoint(
                            x: context.rect.origin.x + context.rect.size.width / 2,
                            y: context.rect.origin.y + context.rect.size.height / 2
                        ).coordinate
                        projectedViewportLatitude = center.latitude
                        updateS2Grid(proxy: proxy, size: mapGeometry.size, projectedWidth: context.rect.size.width, centerLatitude: center.latitude)
                    }
                    .onAppear {
                        if let projectedViewportWidth, let projectedViewportLatitude {
                            updateS2Grid(proxy: proxy, size: mapGeometry.size, projectedWidth: projectedViewportWidth, centerLatitude: projectedViewportLatitude)
                        }
                    }
                    .onChange(of: s2GridEnabled) { _, enabled in
                        if enabled, let projectedViewportWidth, let projectedViewportLatitude {
                            updateS2Grid(proxy: proxy, size: mapGeometry.size, projectedWidth: projectedViewportWidth, centerLatitude: projectedViewportLatitude)
                        }
                        else { s2Grid.clear() }
                    }
                    .onChange(of: s2GridLevelRawValue) { _, _ in
                        if s2GridEnabled, let projectedViewportWidth, let projectedViewportLatitude {
                            updateS2Grid(proxy: proxy, size: mapGeometry.size, projectedWidth: projectedViewportWidth, centerLatitude: projectedViewportLatitude)
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) { controlCard }
            .overlay(alignment: .topLeading) {
                if s2GridEnabled, let level = s2Grid.result.actualLevel {
                    Text("Lv.\(level)")
                        .font(.caption2.bold())
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.leading, 12)
                        .padding(.top, 56)
                        .allowsHitTesting(false)
                        .accessibilityLabel(L10n.format("S2 網格層級 %@", String(level)))
                } else if s2GridEnabled, s2Grid.result.didExceedCellLimit {
                    Text(L10n.text("縮小地圖以顯示 S2 網格"))
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.leading, 12)
                        .padding(.top, 56)
                        .allowsHitTesting(false)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Picker(L10n.text("模式"), selection: $model.quickRouteMode) {
                            ForEach(QuickRouteInteractionMode.allCases) { mode in
                                Text(mode.title).tag(mode).accessibilityLabel(mode.accessibilityTitle)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                        .disabled(model.isAnyRouteActive)
                        .accessibilityHint(model.isAnyRouteActive ? L10n.text("路線播放中，請先停止路線再編輯。") : "")
                        if !model.waypoints.isEmpty {
                            Button { model.quickRouteMode = .route } label: {
                                Text(L10n.format("草稿 %d 點", model.waypoints.count))
                                .font(.caption2.bold())
                                .monospacedDigit()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isAnyRouteActive)
                            .accessibilityHint(L10n.text("返回路線編輯；航點會保留。"))
                                .accessibilityLabel(L10n.format("路線草稿，%d 個航點", model.waypoints.count))
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showMyRoutes = true } label: { Image(systemName: "list.bullet.rectangle") }
                        .accessibilityLabel(L10n.text("我的路線"))
                    Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel(L10n.text("搜尋地點"))
                    Button { showCoordinateEntry = true } label: { Image(systemName: "location.viewfinder") }
                        .accessibilityLabel(L10n.text("輸入座標"))
                    CoordinatePasteToolbarButton(
                        isDisabled: model.isAnyRouteActive,
                        onPaste: handlePastedValues
                    )
                    Menu {
                        Button(L10n.text("顯示完整路線"), action: fitRoute)
                            .disabled(model.geometry.coordinates.isEmpty)
                        Divider()
                        Toggle(L10n.text("顯示 S2 網格"), isOn: $s2GridEnabled)
                        Picker(L10n.text("S2 層級"), selection: $s2GridLevelRawValue) {
                            Text(L10n.text("自動")).tag("auto")
                            ForEach(S2GridLevelMode.supportedLevels, id: \.self) { level in
                                Text("Lv.\(level)").tag(String(level))
                            }
                        }
                        .disabled(!s2GridEnabled)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(L10n.text("更多地圖選項"))
                }
            }
        }
        .sheet(isPresented: $showMyRoutes) {
            MyRoutesSheet { route in
                model.previewRoute(route)
                fitRoute()
            }
        }
        .sheet(isPresented: $showSearch) {
            LocationSearchPicker { coordinate in
                model.select(coordinate.clCoordinate)
                camera = .region(MKCoordinateRegion(center: coordinate.clCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
            }
        }
        .background {
            CoordinateAlertPresenter(isPresented: $showCoordinateEntry) { coordinates, simulateImmediately in
                if coordinates.count == 1, let coordinate = coordinates.first, simulateImmediately {
                    model.focusOnMap(coordinate)
                    model.requestSinglePointSimulation(at: coordinate)
                } else {
                    model.requestCoordinatePreview(coordinates)
                }
            }
            .frame(width: 1, height: 1)
        }
        .alert(L10n.text("儲存喜好地點"), isPresented: $showFavoriteName) {
            TextField(L10n.text("名稱"), text: $favoriteName)
            Button(L10n.text("儲存")) {
                let coordinate = favoriteCoordinate
                Task {
                    await model.addFavorite(name: favoriteName, coordinate: coordinate)
                    favoriteName = ""
                    favoriteCoordinate = nil
                }
            }
            Button(L10n.text("取消"), role: .cancel) {
                favoriteCoordinate = nil
            }
        }
        .onChange(of: model.mapFocusRevision) { _, _ in
            if model.previewingRoute != nil || model.mapFocusTargetsRoute {
                fitRoute()
            } else if let coordinate = model.selectedCoordinate {
                camera = .region(MKCoordinateRegion(center: coordinate.clCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
            }
        }
        .alert(L10n.text("收藏目前路線"), isPresented: $showFavoriteRouteName) {
            TextField(L10n.text("名稱"), text: $favoriteRouteName)
            Button(L10n.text("儲存")) {
                let name = favoriteRouteName
                favoriteRouteName = ""
                Task {
                    if await model.favoriteCurrentRoute(named: name) {
                        ToastManager.shared.show(L10n.text("已加入喜愛路線。"), kind: .success)
                    }
                }
            }
            Button(L10n.text("取消"), role: .cancel) { favoriteRouteName = "" }
        } message: {
            Text(L10n.text("此路線會先儲存，再加入喜愛路線。"))
        }
        .onChange(of: model.speedKmh) { _, newSpeed in
            guard playback.state == .running || playback.state == .paused else { return }
            if abs(playback.speedKmh - newSpeed) > 0.0001 { model.setPlaybackSpeed(newSpeed) }
        }
    }

    private func updateS2Grid(proxy: MapProxy, size: CGSize, projectedWidth: Double, centerLatitude: Double) {
        guard s2GridEnabled else { return }
        guard size.width > 0, size.height > 0,
              let metersPerPoint = S2GridViewportScalePolicy.metersPerPoint(
                  projectedViewportWidth: projectedWidth,
                  viewportWidthPoints: Double(size.width),
                metersPerMapPoint: MKMetersPerMapPointAtLatitude(centerLatitude)
              ) else {
            s2Grid.clear()
            return
        }
        let mode = S2GridLevelMode(rawValue: s2GridLevelRawValue)
        let renderLevel: Int
        switch mode {
        case .automatic:
            renderLevel = S2GridLevelPolicy.choose(metersPerPoint: metersPerPoint, previousLevel: s2Grid.result.actualLevel)
        case .fixed(let value):
            renderLevel = min(20, max(14, value))
        }
        let stridePoints = S2GridSamplingPolicy.stridePoints(level: renderLevel, metersPerPoint: metersPerPoint)
        guard S2GridSamplingPolicy.estimatedSampleCount(size: size, stridePoints: stridePoints)
            <= S2GridSamplingPolicy.maximumViewportSamples else {
            s2Grid.showCellLimitMessage()
            return
        }
        let samples = S2GridSamplingPolicy.samplePoints(size: size, stridePoints: CGFloat(stridePoints))
            .compactMap { point -> S2GridCoordinate? in
                guard let coordinate = proxy.convert(point, from: .local) else { return nil }
                return S2GridCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
            }
        guard samples.count <= S2GridSamplingPolicy.maximumViewportSamples else {
            s2Grid.showCellLimitMessage()
            return
        }
        s2Grid.update(samples: samples, metersPerPoint: metersPerPoint, mode: mode)
    }


    private func handlePastedValues(_ values: [String]) {
        do { model.requestCoordinatePreview(try CoordinatePastePayload.parse(values)) }
        catch { model.presentedError = error.localizedDescription }
    }


    @ViewBuilder
    private var controlCard: some View {
        if model.isAnyRouteActive && playback.state.showsRouteControls {
            RouteFloatingCard(
                mode: .active,
                onStartRoute: {},
                onEdit: {},
                onCancelPreview: {},
                onEndRoute: { model.stopAndHoldCurrentLocation() },
                onRestoreRealLocation: { Task { await model.returnToRealLocation() } },
                onFavoriteUnsavedRoute: {
                    favoriteRouteName = model.suggestedFavoriteRouteName()
                    showFavoriteRouteName = true
                }
            )
            .padding(.horizontal)
            .padding(.bottom, 4)
        } else {
            classicControlCard
        }
    }

    private var classicControlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(model.connectionMonitor.effectiveTunnelHealthy ? .green : .orange).frame(width: 9, height: 9)
                Text(model.connectionMonitor.connectionBannerText)
                    .font(.caption)
                Spacer()
                Text(playback.state.label).font(.caption).foregroundStyle(.secondary)
                Button {
                    withAnimation(.spring()) { isCardExpanded.toggle() }
                } label: {
                    Image(systemName: isCardExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
            if isCardExpanded {
                if model.waypoints.isEmpty, model.selectedCoordinate == nil,
                   model.previewingRoute == nil, !model.simulationMode.isSimulating {
                    QuickPlaybackRouteShortcut()
                }
                if let active = model.activeSimulatedCoordinate, !model.simulationMode.isRouteSimulation {
                    if let candidate = ClassicRouteMapCardSelection.selectedCandidate(
                        active: active,
                        selected: model.selectedCoordinate
                    ) {
                        classicSelectedPlaceContent(for: candidate)
                    } else {
                        ActiveSimulationFloatingCard(
                            coordinate: active,
                            onSaveFavorite: {
                                favoriteCoordinate = FavoriteCoordinateCapture.coordinate(
                                    for: .activeSimulation,
                                    active: active,
                                    selected: model.selectedCoordinate
                                )
                                favoriteName = model.suggestedFavoriteName()
                                showFavoriteName = true
                            },
                            onRestore: { Task { await model.returnToRealLocation() } }
                        )
                    }
                } else if let previewing = model.previewingRoute {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "eye.fill").foregroundStyle(.blue)
                            Text(previewing.name).font(.headline).lineLimit(1)
                            Spacer()
                            Text(L10n.text("預覽中")).font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15), in: Capsule())
                                .foregroundStyle(.blue)
                        }
                        HStack {
                            Text(L10n.format("路線資訊：%lld 航點 · %@ · %@ km/h", Int64(previewing.waypoints.count), previewing.totalDistance.formattedDistance, previewing.preferredSpeedKmh.formatted(.number.precision(.fractionLength(1)))))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        RouteEndpointTimeZoneSummary(route: previewing)
                        HStack {
                            Button(L10n.text("開始路線")) { model.requestStartRoute(previewing) }.buttonStyle(.borderedProminent)
                            Button(L10n.text("編輯")) {
                                model.requestOpenRouteEditor(previewing)
                            }.buttonStyle(.bordered)
                            Button(L10n.text("取消預覽"), role: .cancel) { model.cancelRoutePreview() }.buttonStyle(.bordered)
                        }
                    }
                } else if let selected = model.selectedCoordinate {
                    classicSelectedPlaceContent(for: selected)
                } else {
                    Text(L10n.text("點選地圖、搜尋地點、輸入座標，或選擇喜愛地點。")).font(.footnote).foregroundStyle(.secondary)
                    Button(L10n.text("輸入精確座標")) { showCoordinateEntry = true }.buttonStyle(.bordered)
                }
                if model.geometry.totalDistance > 0 && RoutePlanningControlsPolicy.shouldShow(
                    mode: model.quickRouteMode,
                    hasPreview: model.previewingRoute != nil,
                    routeIsActive: model.isAnyRouteActive
                ) {
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
                            Text(L10n.format("第 %d 圈", playback.lapNumber)).fontWeight(.semibold)
                        }
                    }.font(.footnote)
                    RouteEndpointTimeZoneSummary(waypoints: model.waypoints, isClosedLoop: model.isClosedLoop)
                    HStack {
                        Button(L10n.text("開始路線")) { Task { await model.startPlayback() } }.buttonStyle(.borderedProminent)
                        Button(L10n.text("停止")) { model.stopRoutePlayback(clearMarker: true) }.buttonStyle(.bordered).tint(.red)
                            .disabled(playback.state != .running && playback.state != .reconnecting)
                        Button(L10n.text("清除路線"), role: .destructive) { model.clearCurrentRoute() }.buttonStyle(.bordered)
                    }
                }
                Button(L10n.text("恢復真實位置"), role: .destructive) { Task { await model.returnToRealLocation() } }
                    .font(.footnote)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal).padding(.bottom, 4)
    }

    @ViewBuilder
    private func classicSelectedPlaceContent(for selected: RouteCoordinate) -> some View {
        HStack(spacing: 8) {
            CoordinateValueText(coordinate: selected)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button { model.clearSelectedPlace() } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("清除目前選取位置"))
        }
        HStack {
            Button(L10n.text("在此模擬")) {
                model.requestSinglePointSimulation(at: selected)
            }
            .buttonStyle(.borderedProminent)
            Button(L10n.text("加入路線")) { model.addSelectedWaypointAndSwitchToRoute() }
                .buttonStyle(.bordered)
            Button {
                favoriteCoordinate = FavoriteCoordinateCapture.coordinate(
                    for: .selectedPlace,
                    active: model.activeSimulatedCoordinate,
                    selected: selected
                )
                favoriteName = model.suggestedFavoriteName()
                showFavoriteName = true
            } label: { Image(systemName: "star") }
            .buttonStyle(.bordered)
        }
    }

    private func fitRoute() {
        let coordinates = displayCoordinates
        guard let first = coordinates.first else { return }
        var rect = MKMapRect(origin: MKMapPoint(first.clCoordinate), size: MKMapSize(width: 0, height: 0))
        for coordinate in coordinates.dropFirst() {
            rect = rect.union(MKMapRect(origin: MKMapPoint(coordinate.clCoordinate), size: .init(width: 0, height: 0)))
        }
        camera = .rect(rect.insetBy(dx: -max(rect.width * 0.15, 500), dy: -max(rect.height * 0.15, 500)))
    }

    private var displayWaypoints: [RouteCoordinate] {
        model.previewingRoute?.waypoints ?? model.waypoints
    }

    private var displayCoordinates: [RouteCoordinate] {
        model.previewingRoute?.resolvedGeometry.coordinates ?? model.geometry.coordinates
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
    @State private var showMyRoutes = false
    @State private var showCustomRepeat = false
    @State private var customRepeatText = ""
    @State private var favoriteName = ""
    @State private var isCardExpanded = false
    @FocusState private var isSpeedFieldFocused: Bool

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera) {
                    RouteMapOverlayContent(
                        s2Cells: [],
                        selection: model.selectedCoordinate,
                        showsSelection: model.quickRouteMode == .singlePoint,
                        waypoints: model.waypoints,
                        routeCoordinates: model.geometry.coordinates,
                        showsRoute: RouteMapOverlayPolicy.shouldShowRouteGeometry(
                            mode: model.quickRouteMode,
                            hasPreview: model.previewingRoute != nil,
                            routeIsActive: model.isAnyRouteActive
                        ),
                        activeCoordinate: playback.currentCoordinate
                    )
                }
                .mapControls { MapCompass(); MapScaleView(); MapUserLocationButton() }
                .onTapGesture { point in
                    if let coordinate = proxy.convert(point, from: .local) {
                        if model.quickRouteMode == .route {
                            model.addWaypoint(RouteCoordinate(coordinate), notifyIfLocked: false)
                        } else {
                            model.select(coordinate)
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) { quickControlCard }
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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.quickRouteMode == .route {
                        Button { showMyRoutes = true } label: { Image(systemName: "list.bullet.rectangle") }
                            .accessibilityLabel(L10n.text("我的路線"))
                    }
                    Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel(L10n.text("搜尋地點"))
                    Button { showCoordinateEntry = true } label: { Image(systemName: "location.viewfinder") }
                        .accessibilityLabel(L10n.text("輸入座標"))
                    Button { fitRoute() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .accessibilityLabel(L10n.text("顯示完整路線"))
                        .disabled(model.geometry.coordinates.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showSearch) {
            LocationSearchPicker { coordinate in
                if model.quickRouteMode == .route {
                    if model.addWaypoint(coordinate, notifyIfLocked: true) {
                        ToastManager.shared.show(L10n.text("已新增航點。"), kind: .success)
                    }
                } else {
                    model.select(coordinate.clCoordinate)
                }
                camera = .region(MKCoordinateRegion(center: coordinate.clCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
            }
        }
        .background {
            CoordinateAlertPresenter(isPresented: $showCoordinateEntry) { coordinates, simulateImmediately in
                if coordinates.count == 1, let coordinate = coordinates.first, simulateImmediately {
                    model.focusOnMap(coordinate)
                    model.requestSinglePointSimulation(at: coordinate)
                } else {
                    model.requestCoordinatePreview(coordinates)
                }
            }
            .frame(width: 1, height: 1)
        }
        .sheet(isPresented: $showMyRoutes) {
            MyRoutesSheet { route in
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
        .alert(L10n.text("播放次數"), isPresented: $showCustomRepeat) {
            TextField(L10n.text("圈數"), text: $customRepeatText)
                .keyboardType(.numberPad)
            Button(L10n.text("套用")) {
                if let count = RouteRepeatEntryPolicy.finiteCount(customRepeatText) {
                    model.playbackMode = model.isClosedLoop ? .finite(count) : .once
                }
            }
            .disabled(!model.isClosedLoop || RouteRepeatEntryPolicy.finiteCount(customRepeatText) == nil)
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("請輸入 1 到 9999 圈。"))
        }
        .onChange(of: model.mapFocusRevision) { _, _ in
            guard let coordinate = model.selectedCoordinate else { return }
            camera = .region(MKCoordinateRegion(center: coordinate.clCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
        }
    }

    private var quickControlCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(model.connectionMonitor.effectiveTunnelHealthy ? .green : .orange).frame(width: 8, height: 8)
                Text(model.connectionMonitor.connectionBannerText)
                    .font(.caption2)
                    .lineLimit(1)
                Spacer()
                if isPlaybackActive {
                    Text(playback.state.label)
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isCardExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isCardExpanded ? "chevron.down.circle.fill" : "chevron.up.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(L10n.text(isCardExpanded ? "收合卡片" : "展開卡片"))
            }

            if let previewing = model.previewingRoute {
                previewRouteContent(previewing)
            } else if isPlaybackActive {
                activePlaybackContent
            } else if model.quickRouteMode == .singlePoint {
                singlePointContent
            } else {
                routeDraftContent
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private var isPlaybackActive: Bool {
        model.isAnyRouteActive && playback.state.showsRouteControls
    }

    @ViewBuilder
    private func previewRouteContent(_ route: SavedRoute) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "eye.fill")
                    .foregroundStyle(.blue)
                Text(route.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                Text(L10n.text("預覽中"))
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15), in: Capsule())
                    .foregroundStyle(.blue)
            }

            HStack {
                Text(L10n.format("路線資訊：%lld 航點 · %@ · %@ km/h", Int64(route.waypoints.count), route.totalDistance.formattedDistance, route.preferredSpeedKmh.formatted(.number.precision(.fractionLength(1)))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 8) {
                Button(L10n.text("開始路線")) {
                    model.requestStartRoute(route)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(L10n.text("編輯")) {
                    if model.requestEditRoute(route) {
                        NotificationCenter.default.post(name: .switchToRoutesTab, object: nil)
                        NotificationCenter.default.post(name: .openRouteEditor, object: nil)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(L10n.text("取消預覽"), role: .cancel) {
                    model.cancelRoutePreview()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var activePlaybackContent: some View {
        if let message = playback.state.interruptionMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        HStack {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .foregroundStyle(.blue)
            Text(playback.routeName)
                .font(.subheadline.bold())
                .lineLimit(1)
            Spacer()
            Text(L10n.format("第 %d 圈", playback.lapNumber))
                .font(.caption.bold())
            if playback.state == .running {
                Button(L10n.text("暫停移動")) { playback.pause() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if playback.state == .paused {
                Button(L10n.text("繼續")) { Task { await playback.resume() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button(L10n.text("停止")) {
                model.stopRoutePlayback(clearMarker: true)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
        }

        if isCardExpanded {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                HStack {
                    Label(playback.traveledDistance.formattedDistance, systemImage: "figure.walk")
                    Spacer()
                    Label(formatDuration(playback.elapsedTime), systemImage: "clock")
                    Spacer()
                    Button { model.adjustPlaybackSpeed(by: -0.1) } label: { Image(systemName: "minus") }
                        .buttonStyle(.bordered).frame(minWidth: 40, minHeight: 40)
                        .disabled(playback.state == .reconnecting)
                        .accessibilityLabel(L10n.text("降低速度 0.1 公里每小時"))
                    Text("\(playback.speedKmh.formatted(.number.precision(.fractionLength(1))))")
                        .monospacedDigit()
                    Button { model.adjustPlaybackSpeed(by: 0.1) } label: { Image(systemName: "plus") }
                        .buttonStyle(.bordered).frame(minWidth: 40, minHeight: 40)
                        .disabled(playback.state == .reconnecting)
                        .accessibilityLabel(L10n.text("提高速度 0.1 公里每小時"))
                    Text("km/h").font(.caption)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if let current = model.activeSimulatedCoordinate {
                    HStack {
                        Text(L10n.text("目前位置")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { CoordinateClipboard.copy(current) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.plain).frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel(L10n.text("複製座標"))
                    }
                }

                if model.simulationMode.isSimulating {
                    Button(L10n.text("恢復真實位置"), role: .destructive) {
                        Task { await model.returnToRealLocation() }
                    }
                    .font(.footnote)
                    .padding(.top, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var singlePointContent: some View {
        if let selected = model.selectedCoordinate {
            if isCardExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    CoordinateValueText(coordinate: selected)
                        .textSelection(.enabled)

                    HStack {
                        Button(L10n.text("在此模擬")) {
                            model.requestSinglePointSimulation()
                        }
                        .buttonStyle(.borderedProminent)

                        Button(L10n.text("加入航點")) {
                            model.addSelectedWaypointAndSwitchToRoute()
                        }
                        .buttonStyle(.bordered)

                        Button {
                            favoriteName = model.suggestedFavoriteName(); showFavoriteName = true
                        } label: {
                            Image(systemName: "star")
                        }
                        .buttonStyle(.bordered)

                        Spacer()
                    }

                    if model.simulationMode.isSimulating {
                        Button(L10n.text("恢復真實位置"), role: .destructive) {
                            Task { await model.returnToRealLocation() }
                        }
                        .font(.footnote)
                    }
                }
            } else {
                HStack {
                    CoordinateValueText(coordinate: selected)
                        .lineLimit(1)
                    Spacer()
                    Button(L10n.text("在此模擬")) {
                        model.requestSinglePointSimulation()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        } else {
            if isCardExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("在單點模式下點選地圖或搜尋以選擇模擬位置。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(L10n.text("輸入精確座標")) {
                        showCoordinateEntry = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if model.simulationMode.isSimulating {
                        Button(L10n.text("恢復真實位置"), role: .destructive) {
                            Task { await model.returnToRealLocation() }
                        }
                        .font(.footnote)
                    }
                }
            } else {
                Text(L10n.text("點選地圖以選擇模擬位置"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var routeDraftContent: some View {
        if model.waypoints.isEmpty {
            if isCardExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("在路線模式下點選地圖或使用搜尋以依序新增航點。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button {
                            showMyRoutes = true
                        } label: {
                            Label(L10n.text("我的路線"), systemImage: "list.bullet.rectangle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer()
                    }
                    if model.simulationMode.isSimulating {
                        Button(L10n.text("恢復真實位置"), role: .destructive) {
                            Task { await model.returnToRealLocation() }
                        }
                        .font(.footnote)
                    }
                }
            } else {
                HStack {
                    Text(L10n.text("點選地圖以新增航點"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showMyRoutes = true
                    } label: {
                            Label(L10n.text("我的路線"), systemImage: "list.bullet.rectangle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        } else if model.waypoints.count == 1 {
            HStack {
                Text(L10n.text("已新增 1 個航點，請點選下一個航點"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("復原")) { model.undoLastWaypoint() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else {
            if isCardExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.text("建立路線")).font(.subheadline.bold())
                        Spacer()
                        Text(L10n.format("航點：%d", model.waypoints.count)).font(.footnote)
                        Text(L10n.format("距離：%@", model.geometry.totalDistance.formattedDistance)).font(.footnote)
                    }

                    HStack {
                        Text(L10n.text("路線方式")).font(.caption).foregroundStyle(.secondary)
                        Picker(L10n.text("路線方式"), selection: $model.routeMode) {
                            ForEach(RouteMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    if model.routeMode == .navigation {
                        HStack {
                            Picker(L10n.text("交通方式"), selection: $model.navigationTransport) {
                                ForEach(NavigationTransportMode.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            if model.navigationGeometryNeedsRecalculation {
                                Button(L10n.text(model.isResolvingNavigation ? "計算中…" : "計算導航")) {
                                    Task { await model.recalculateNavigation() }
                                }
                                .buttonStyle(.bordered)
                                .disabled(model.isResolvingNavigation || model.waypoints.count < 2)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Text(L10n.text("速度")).font(.caption).foregroundStyle(.secondary)
                        Button { model.adjustPlaybackSpeed(by: -0.1) } label: { Image(systemName: "minus") }
                            .buttonStyle(.bordered).frame(minWidth: 40, minHeight: 40)
                            .disabled(playback.state == .reconnecting)
                            .accessibilityLabel(L10n.text("降低速度 0.1 公里每小時"))
                        TextField("18.6", value: $model.speedKmh, format: .number)
                            .keyboardType(.decimalPad)
                            .focused($isSpeedFieldFocused)
                            .frame(width: 55)
                            .textFieldStyle(.roundedBorder)
                            .disabled(playback.state == .reconnecting)
                        Button { model.adjustPlaybackSpeed(by: 0.1) } label: { Image(systemName: "plus") }
                            .buttonStyle(.bordered).frame(minWidth: 40, minHeight: 40)
                            .disabled(playback.state == .reconnecting)
                            .accessibilityLabel(L10n.text("提高速度 0.1 公里每小時"))
                        Text("km/h").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            Toggle(L10n.text("封閉路線"), isOn: $model.isClosedLoop)
                            Picker(L10n.text("播放次數"), selection: $model.playbackMode) {
                                Text(L10n.text("1 圈")).tag(RoutePlaybackMode.once)
                                Text(L10n.text("2 圈")).tag(RoutePlaybackMode.finite(2))
                                Text(L10n.text("3 圈")).tag(RoutePlaybackMode.finite(3))
                                Text(L10n.text("5 圈")).tag(RoutePlaybackMode.finite(5))
                                Text(L10n.text("無限")).tag(RoutePlaybackMode.infiniteLoop)
                            }
                            .disabled(!model.isClosedLoop)
                            Button(L10n.text("自訂…")) {
                                customRepeatText = model.playbackMode.finiteCount.map(String.init) ?? ""
                                showCustomRepeat = true
                            }
                            .disabled(!model.isClosedLoop)
                            if !model.isClosedLoop {
                                Text(L10n.text("開放路線只能播放一次；需要多圈時請開啟封閉路線。"))
                            }
                        } label: {
                            Label(routeRepeatSummary, systemImage: "repeat")
                                .font(.caption)
                        }
                    }

                    HStack {
                        Button(L10n.text("復原")) { model.undoLastWaypoint() }
                            .buttonStyle(.bordered)
                        Menu {
                            Button(L10n.text("清除路線"), role: .destructive) { showClearDraftAlert = true }
                            Button(L10n.text("我的路線")) { showMyRoutes = true }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel(L10n.text("更多路線操作"))
                        Spacer()
                        Button(L10n.text("儲存路線")) { showSaveSheet = true }
                            .buttonStyle(.bordered)
                            .disabled(model.geometry.totalDistance <= 0 || model.navigationGeometryNeedsRecalculation)
                        Button(L10n.text("開始路線")) { Task { await model.startPlayback() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.geometry.totalDistance <= 0 || model.navigationGeometryNeedsRecalculation)
                    }

                    if model.simulationMode.isSimulating {
                        Button(L10n.text("恢復真實位置"), role: .destructive) {
                            Task { await model.returnToRealLocation() }
                        }
                        .font(.footnote)
                    }
                }
            } else {
                HStack {
                    Text(L10n.format("路線資訊：%lld 航點 · %@ · %@ km/h", Int64(model.waypoints.count), model.geometry.totalDistance.formattedDistance, model.speedKmh.formatted(.number.precision(.fractionLength(1)))))
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button { showMyRoutes = true } label: { Image(systemName: "list.bullet.rectangle") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button(L10n.text("開始路線")) { Task { await model.startPlayback() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.geometry.totalDistance <= 0 || model.navigationGeometryNeedsRecalculation)
                }
            }
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

    private var routeRepeatSummary: String {
        let geometry = model.isClosedLoop ? L10n.text("封閉") : L10n.text("開放")
        let repeatText: String
        switch model.playbackMode {
        case .once: repeatText = L10n.text(model.isClosedLoop ? "1 圈" : "1 次")
        case .infiniteLoop: repeatText = "∞"
        case .finite(let count): repeatText = L10n.format("%d 圈", count)
        }
        return "\(geometry) · \(repeatText)"
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(max(0, duration))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
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
            .overlay { if completer.results.isEmpty { ContentUnavailableView(L10n.text("搜尋 Apple 地圖"), systemImage: "magnifyingglass", description: Text(errorMessage ?? L10n.text("輸入地點或地址。"))) } }
            .searchable(text: $query, prompt: L10n.text("地點或地址"))
            .onChange(of: query) { _, value in completer.update(value) }
            .navigationTitle(L10n.text("搜尋"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { dismiss() } } }
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
