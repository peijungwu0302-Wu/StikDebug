import MapKit
import SwiftUI

struct MapHomeView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var playback: RoutePlaybackEngine
    @EnvironmentObject private var tutorial: GuidedTutorialCoordinator
    @EnvironmentObject private var tutorialUI: TutorialUIContext
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @StateObject private var s2Grid = S2GridController()
    @State private var projectedViewportWidth: Double?
    @State private var projectedViewportLatitude: Double?
    @AppStorage("RouteLocation.s2GridEnabled") private var s2GridEnabled = false
    @AppStorage("RouteLocation.s2GridLevelMode") private var s2GridLevelRawValue = "auto"
    @State private var showSearch = false
    @State private var showCoordinateEntry = false
    @State private var showRouteInputChooser = false
    @State private var showRoutePaste = false
    @State private var showRouteImporter = false
    @State private var showFavoritePlacePicker = false
    @State private var showFavoriteRoutePicker = false
    @State private var showSaveSheet = false
    @State private var showRouteEditor = false
    @State private var showClearDraftAlert = false
    @State private var showFavoriteName = false
    @State private var showFavoriteRouteName = false
    @State private var showEndRouteOptions = false
    @State private var showCustomRepeat = false
    @State private var customRepeatText = ""
    @State private var pendingPasteCoordinates: [RouteCoordinate] = []
    @State private var showPasteDraftChoice = false
    @State private var favoriteName = ""
    @State private var favoriteRouteName = ""
    @State private var favoriteCoordinate: RouteCoordinate?
    @State private var routeSpeedText = ""
    @FocusState private var isSpeedFieldFocused: Bool

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                GeometryReader { mapGeometry in
                Map(position: $camera) {
                    RouteMapOverlayContent(
                        s2Cells: s2Grid.result.cells,
                        selection: candidateCoordinate,
                        showsSelection: model.quickRouteMode == .singlePoint && model.previewingRoute == nil,
                        waypoints: displayWaypoints,
                        routeCoordinates: displayCoordinates,
                        showsRoute: model.quickRouteMode != .singlePoint || model.previewingRoute != nil,
                        activeCoordinate: activeSimulatedCoordinate
                    )
                }
                .mapControls { MapCompass(); MapScaleView(); MapUserLocationButton() }
                .onTapGesture { point in
                    if let coordinate = proxy.convert(point, from: .local) {
                        switch MapTapRoutePolicy.action(mode: model.quickRouteMode, routeIsActive: model.isAnyRouteActive) {
                        case .addWaypoint:
                            // Route mode is already active: a map tap is the
                            // explicit add action. Marker + draft badge give
                            // immediate feedback without a blocking toast on
                            // every fast waypoint tap.
                            model.addWaypoint(RouteCoordinate(coordinate))
                        case .selectPlace:
                            model.select(coordinate)
                        case .ignoreWhileRouteActive:
                            // Passive map gestures never toast while playback owns an immutable snapshot.
                            return
                        }
                    }
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    projectedViewportWidth = context.rect.size.width
                    let center = MKCoordinateForMapPoint(MKMapPoint(
                        x: context.rect.origin.x + context.rect.size.width / 2,
                        y: context.rect.origin.y + context.rect.size.height / 2
                    ))
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
            .overlay(alignment: .bottom) { floatingCardArea }
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
                        QuickRouteModePicker(selection: $model.quickRouteMode)
                        .tutorialTarget(.routeMode)
                        .frame(width: 140)
                        .disabled(model.isAnyRouteActive)
                        if !model.waypoints.isEmpty {
                            Text(L10n.format("路線 %d", model.waypoints.count))
                                .font(.caption2.bold())
                                .monospacedDigit()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                                .accessibilityLabel(L10n.format("路線草稿，%d 個航點", model.waypoints.count))
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { showFavoriteRoutePicker = true } label: {
                        Label(L10n.text("我的路線"), systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityLabel(L10n.text("我的路線"))
                    if model.quickRouteMode == .singlePoint {
                        Button { showFavoritePlacePicker = true } label: {
                            Label(L10n.text("我的最愛"), systemImage: "star.fill")
                        }
                        .accessibilityLabel(L10n.text("我的最愛"))
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel(L10n.text("搜尋地點"))
                    Button {
                        if model.quickRouteMode == .route { showRouteInputChooser = true } else { showCoordinateEntry = true }
                    } label: { Image(systemName: "location.viewfinder") }
                        .accessibilityLabel(L10n.text("輸入座標"))
                        .tutorialTarget(.coordinateEntry)
                    PasteButton(payloadType: String.self) { pastedValues in
                        guard let text = pastedValues.first else { return }
                        acceptPastedCoordinates(text)
                    } label: {
                        Label(L10n.text("貼上座標"), systemImage: "doc.on.clipboard")
                    }
                    .accessibilityLabel(L10n.text("貼上座標"))
                    .disabled(model.isAnyRouteActive)
                    Menu {
                        if !displayCoordinates.isEmpty {
                            Button(L10n.text("顯示完整路線")) { fitRoute() }
                        }
                        if !displayCoordinates.isEmpty { Divider() }
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
        .sheet(isPresented: $showSearch) {
            LocationSearchPicker { coordinate in
                if model.quickRouteMode == .route {
                    model.addWaypointAndSwitchToRoute(coordinate)
                } else {
                    model.focusOnMap(coordinate)
                }
                camera = .region(MKCoordinateRegion(center: coordinate.clCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
            }
        }
        .background {
            CoordinateAlertPresenter(isPresented: $showCoordinateEntry) { coordinate, simulateImmediately in
                if simulateImmediately {
                    model.requestSinglePointSimulation(at: coordinate)
                } else if model.quickRouteMode == .route {
                    model.addWaypointAndSwitchToRoute(coordinate)
                } else {
                    model.focusOnMap(coordinate)
                }
                camera = .region(MKCoordinateRegion(center: coordinate.clCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
            }
            .frame(width: 1, height: 1)
        }
        .sheet(isPresented: $showRouteInputChooser) {
            RouteInputChooser(
                hasExistingWaypoints: !model.waypoints.isEmpty,
                onSingle: { showCoordinateEntry = true },
                onPaste: { showRoutePaste = true },
                onImport: { showRouteImporter = true }
            )
        }
        .sheet(isPresented: $showRoutePaste) {
            RoutePasteView(
                hasExistingWaypoints: !model.waypoints.isEmpty,
                onReplace: { values in
                    guard model.replaceWaypoints(values) else { return }
                    fitRoute()
                    statusAfterImport(values.count)
                },
                onAppend: { values in
                    guard model.appendWaypoints(values) else { return }
                    fitRoute()
                    statusAfterImport(values.count)
                }
            )
        }
        .fileImporter(isPresented: $showRouteImporter, allowedContentTypes: CoordinateImportParser.supportedContentTypes) { result in
            guard case .success(let url) = result else { return }
            Task.detached {
                do {
                    let values = try CoordinateImportParser.parse(url: url)
                    await MainActor.run {
                        guard model.replaceWaypoints(values) else { return }
                        fitRoute()
                        statusAfterImport(values.count)
                    }
                } catch { await MainActor.run { model.presentedError = error.localizedDescription } }
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
        .sheet(isPresented: $showRouteEditor) { RouteEditorView() }
        .confirmationDialog(L10n.text("目前已有路線草稿"), isPresented: $showPasteDraftChoice, titleVisibility: .visible) {
            Button(L10n.text("取代草稿並預覽")) { applyPastedRoute(replacing: true) }
            Button(L10n.text("附加到目前路線")) { applyPastedRoute(replacing: false) }
            Button(L10n.text("取消"), role: .cancel) { pendingPasteCoordinates = [] }
        } message: {
            Text(L10n.text("貼上的多個座標會建立路線。您可以取代或附加到目前草稿；取消不會變更路線。"))
        }
        .onChange(of: showCoordinateEntry) { _, visible in
            tutorialUI.coordinateEntryVisible = visible
            tutorialUI.modalVisible = visible
        }
        .onChange(of: showSaveSheet) { _, visible in tutorialUI.modalVisible = visible }
        .onChange(of: showFavoriteName) { _, visible in tutorialUI.modalVisible = visible }
        .alert(L10n.text("儲存喜好地點"), isPresented: $showFavoriteName) {
            TextField(L10n.text("名稱"), text: $favoriteName)
            Button(L10n.text("儲存")) { let coordinate = favoriteCoordinate; Task { await model.addFavorite(name: favoriteName, coordinate: coordinate); favoriteName = ""; favoriteCoordinate = nil } }
            Button(L10n.text("取消"), role: .cancel) {}
            if tutorial.isActive { Button(L10n.text("tutorial.skip")) { tutorial.skip() } }
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
        .confirmationDialog(
            L10n.text("路線已結束"),
            isPresented: $model.showEndRouteOptions,
            titleVisibility: .visible
        ) {
            Button(L10n.text("停止並停留目前位置")) {
                model.showEndRouteOptions = false
            }
            Button(L10n.text("恢復真實定位"), role: .destructive) {
                model.showEndRouteOptions = false
                Task { await model.returnToRealLocation() }
            }
        } message: {
            Text(L10n.text("目前位置仍為模擬位置"))
        }
        .onChange(of: model.mapFocusRevision) { _, _ in
            if model.previewingRoute != nil {
                fitRoute()
            } else if MapCameraActionPolicy.shouldRecenter(for: .intentionalNavigation), let coordinate = model.selectedCoordinate {
                camera = .region(MKCoordinateRegion(center: coordinate.clCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
            }
        }
    }

    private func statusAfterImport(_ count: Int) {
        ToastManager.shared.show(L10n.format("已匯入 %d 個航點。", count), kind: .success)
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
                        if model.requestEditRoute(previewing) {
                            NotificationCenter.default.post(name: .switchToRoutesTab, object: nil)
                            NotificationCenter.default.post(name: .openRouteEditor, object: nil)
                        }
                    },
                    onCancelPreview: { model.cancelRoutePreview() },
                    onEndRoute: {},
                    onRestoreRealLocation: {},
                    onFavoriteUnsavedRoute: {}
                )
            } else if isPlaybackActive {
                // Active Route Card
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
            } else if model.quickRouteMode == .singlePoint {
                singlePointFloatingContent
            } else {
                routeDraftFloatingContent
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
        .onChange(of: model.speedKmh) { _, newSpeed in
            guard playback.state == .running || playback.state == .paused else { return }
            if abs(playback.speedKmh - newSpeed) > 0.0001 { model.setPlaybackSpeed(newSpeed) }
        }
    }

    private var isPlaybackActive: Bool {
        model.isAnyRouteActive && playback.state.showsRouteControls
    }

    private func isPlaybackActiveForRoute(_ route: SavedRoute) -> Bool {
        model.isActiveRoute(route)
    }

    // MARK: - Single Point Content

    @ViewBuilder
    private var singlePointFloatingContent: some View {
        if let candidate = candidateCoordinate {
            PlaceFloatingCard(
                coordinate: candidate,
                onSaveFavorite: {
                    favoriteCoordinate = FavoriteCoordinateCapture.coordinate(
                        for: .selectedPlace,
                        active: model.activeSimulatedCoordinate,
                        selected: candidate
                    )
                    favoriteName = model.suggestedFavoriteName()
                    showFavoriteName = true
                },
                onClearSelection: { model.clearSelectedPlace() }
            )
        } else if let active = model.activeSimulatedCoordinate, !model.simulationMode.isRouteSimulation {
            ActiveSimulationFloatingCard(
                coordinate: active,
                onSaveFavorite: {
                    favoriteCoordinate = active
                    favoriteName = model.suggestedFavoriteName()
                    showFavoriteName = true
                },
                onRestore: { Task { await model.returnToRealLocation() } }
            )
        } else if model.simulationMode.isSimulating {
            // Active route simulation while in single point view
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "location.fill").foregroundStyle(.green)
                    Text(model.simulationMode.label).font(.subheadline.bold())
                    Spacer()
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
                    Text(model.connectionMonitor.mapConnectionSummary)
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
                Text(model.connectionMonitor.mapConnectionSummary)
                    .font(.caption2)
                Spacer()
            }

            if model.waypoints.isEmpty {
                HStack {
                    Text(L10n.text("點選地圖以新增航點"))
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button { showFavoriteRoutePicker = true } label: {
                        Label(L10n.text("我的路線"), systemImage: "list.bullet.rectangle")
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

                    HStack(spacing: 10) {
                        Text(L10n.text("速度")).font(.caption).foregroundStyle(.secondary)
                        Button { model.adjustPlaybackSpeed(by: -0.1) } label: { Image(systemName: "minus") }
                            .buttonStyle(.bordered).frame(minWidth: 44, minHeight: 44)
                            .disabled(playback.state == .reconnecting)
                            .accessibilityLabel(L10n.text("降低速度 0.1 公里每小時"))
                        TextField("18.6", text: $routeSpeedText)
                            .keyboardType(.decimalPad).focused($isSpeedFieldFocused).frame(width: 58)
                            .textFieldStyle(.roundedBorder).disabled(playback.state == .reconnecting)
                            .onSubmit(commitPlanningSpeedEdit)
                            .accessibilityLabel(L10n.text("播放速度"))
                        Button { model.adjustPlaybackSpeed(by: 0.1) } label: { Image(systemName: "plus") }
                            .buttonStyle(.bordered).frame(minWidth: 44, minHeight: 44)
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
                        .accessibilityLabel(L10n.text("路線設定"))
                    }

                    HStack {
                        Button { model.undoLastWaypoint() } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(.plain).frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel(L10n.text("復原"))
                        Button(L10n.text("儲存路線")) { showSaveSheet = true }
                            .buttonStyle(.bordered).disabled(model.geometry.totalDistance <= 0 || model.navigationGeometryNeedsRecalculation)
                            .tutorialTarget(.saveRoute)
                        Spacer()
                        Menu {
                            Button(L10n.text("編輯")) { showRouteEditor = true }
                            Button(L10n.text("清除路線"), role: .destructive) { showClearDraftAlert = true }
                            Button(L10n.text("我的路線")) { showFavoriteRoutePicker = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel(L10n.text("更多路線操作"))
                        .tutorialTarget(.routeEditor)
                        Button(L10n.text("開始路線")) { Task { await model.startPlayback() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.geometry.totalDistance <= 0 || model.navigationGeometryNeedsRecalculation)
                            .accessibilityLabel(L10n.text("開始路線"))
                            .tutorialTarget(.startRoute)
                    }
                }
            }

            if model.simulationMode.isSimulating && !isPlaybackActive {
                Button(L10n.text("恢復真實位置"), role: .destructive) {
                    Task { await model.returnToRealLocation() }
                }
                .font(.footnote)
                .accessibilityLabel(L10n.text("恢復真實定位"))
                .tutorialTarget(.restore)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.text("完成"), action: commitPlanningSpeedEdit)
            }
        }
        .onChange(of: isSpeedFieldFocused) { _, focused in
            routeSpeedText = focused
                ? ""
                : model.speedKmh.formatted(.number.precision(.fractionLength(1)))
        }
        .onAppear {
            routeSpeedText = model.speedKmh.formatted(.number.precision(.fractionLength(1)))
        }
        .onChange(of: model.speedKmh) { _, speed in
            if !isSpeedFieldFocused {
                routeSpeedText = speed.formatted(.number.precision(.fractionLength(1)))
            }
        }
    }

    // MARK: - Helpers

    private var candidateCoordinate: RouteCoordinate? {
        let active: RouteCoordinate?
        if case .singlePoint(let coordinate) = model.simulationMode {
            active = coordinate
        } else {
            active = nil
        }
        guard let preferred = MapSinglePointCardPriority.coordinate(
            active: active,
            selected: model.selectedCoordinate
        ), preferred != active else { return nil }
        return preferred
    }

    private func acceptPastedCoordinates(_ text: String) {
        do {
            let coordinates = try CoordinateImportParser.parseInline(text)
            guard !coordinates.isEmpty else { return }
            if coordinates.count == 1, let coordinate = coordinates.first {
                model.quickRouteMode = .singlePoint
                model.focusOnMap(coordinate)
                camera = .region(MKCoordinateRegion(center: coordinate.clCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
                return
            }
            pendingPasteCoordinates = coordinates
            if MultiCoordinatePastePolicy.requiresChoice(existingDraftCount: model.waypoints.count) {
                showPasteDraftChoice = true
            } else {
                applyPastedRoute(replacing: true)
            }
        } catch {
            model.presentedError = error.localizedDescription
        }
    }

    private func applyPastedRoute(replacing: Bool) {
        let coordinates = pendingPasteCoordinates
        pendingPasteCoordinates = []
        guard !coordinates.isEmpty else { return }
        let applied = replacing ? model.replaceWaypoints(coordinates) : model.appendWaypoints(coordinates)
        guard applied else { return }
        fitRoute()
        statusAfterImport(coordinates.count)
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
        s2Grid.update(
            samples: samples,
            metersPerPoint: metersPerPoint,
            mode: mode
        )
    }

    private func commitPlanningSpeedEdit() {
        if let value = PlaybackSpeedEntryPolicy.committedValue(routeSpeedText, preserving: model.speedKmh) {
            model.speedKmh = value
        }
        routeSpeedText = model.speedKmh.formatted(.number.precision(.fractionLength(1)))
        isSpeedFieldFocused = false
    }

    private var activeSimulatedCoordinate: RouteCoordinate? {
        model.activeSimulatedCoordinate
    }

    private var displayWaypoints: [RouteCoordinate] {
        model.previewingRoute?.waypoints ?? model.waypoints
    }

    private var displayCoordinates: [RouteCoordinate] {
        model.previewingRoute?.resolvedGeometry.coordinates ?? model.geometry.coordinates
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

    private func fitRoute() {
        let coordinates = displayCoordinates
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

struct RouteWaypointAnnotation: View {
    let number: Int

    var body: some View {
        ZStack {
            Circle().fill(.orange).frame(width: 28, height: 28)
            Text(String(number))
                .font(.caption.bold())
                .foregroundStyle(.white)
        }
    }
}

struct RouteWaypointMapContent: MapContent {
    let waypoints: [RouteCoordinate]

    var body: some MapContent {
        ForEach(Array(waypoints.enumerated()), id: \.offset) { index, waypoint in
            Annotation(L10n.format("航點 %d", index + 1), coordinate: waypoint.clCoordinate) {
                RouteWaypointAnnotation(number: index + 1)
            }
        }
    }
}

struct S2GridMapContent: MapContent {
    let cells: [S2GridCell]

    var body: some MapContent {
        ForEach(cells) { cell in
            MapPolygon(coordinates: cell.vertices.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            })
            .stroke(.purple.opacity(0.65), lineWidth: 1)
            .foregroundStyle(.purple.opacity(0.035))
        }
    }
}

struct RouteMapOverlayContent: MapContent {
    let s2Cells: [S2GridCell]
    let selection: RouteCoordinate?
    let showsSelection: Bool
    let waypoints: [RouteCoordinate]
    let routeCoordinates: [RouteCoordinate]
    let showsRoute: Bool
    let activeCoordinate: RouteCoordinate?

    var body: some MapContent {
        UserAnnotation()
        S2GridMapContent(cells: s2Cells)
        if showsSelection, let selection {
            Marker(L10n.text("已選位置"), coordinate: selection.clCoordinate).tint(.blue)
        }
        if showsRoute {
            RouteWaypointMapContent(waypoints: waypoints)
            if routeCoordinates.count > 1 {
                MapPolyline(coordinates: routeCoordinates.map(\.clCoordinate))
                    .stroke(.blue, lineWidth: 5)
            }
        }
        if let activeCoordinate {
            Annotation(L10n.text("目前模擬位置"), coordinate: activeCoordinate.clCoordinate) {
                Image(systemName: "location.circle.fill")
                    .font(.title).foregroundStyle(.green).background(.white, in: Circle())
            }
        }
    }
}

struct QuickRouteModePicker: View {
    @Binding var selection: QuickRouteInteractionMode

    var body: some View {
        Picker(L10n.text("模式"), selection: $selection) {
            ForEach(QuickRouteInteractionMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }
}
