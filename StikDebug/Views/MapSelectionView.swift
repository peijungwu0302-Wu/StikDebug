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
    @State private var showMyRoutes = false
    @State private var favoriteName = ""
    @State private var isCardExpanded = true

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
                    Button { showMyRoutes = true } label: { Image(systemName: "star.circle.fill") }
                        .accessibilityLabel("我的路線")
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
                if let previewing = model.previewingRoute {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "eye.fill").foregroundStyle(.blue)
                            Text(previewing.name).font(.headline).lineLimit(1)
                            Spacer()
                            Text("預覽中").font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15), in: Capsule())
                                .foregroundStyle(.blue)
                        }
                        HStack {
                            Text("\(previewing.waypoints.count) 航點 · \(previewing.totalDistance.formattedDistance) · \(previewing.preferredSpeedKmh.formatted(.number.precision(.fractionLength(1)))) km/h")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("開始路線") { model.requestStartRoute(previewing) }.buttonStyle(.borderedProminent)
                            Button("編輯") { NotificationCenter.default.post(name: .switchToRoutesTab, object: nil) }.buttonStyle(.bordered)
                            Button("取消預覽", role: .cancel) { model.cancelRoutePreview() }.buttonStyle(.bordered)
                        }
                    }
                } else if let selected = model.selectedCoordinate {
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
    @State private var showMyRoutes = false
    @State private var favoriteName = ""
    @State private var isCardExpanded = false
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
                    if model.quickRouteMode == .route {
                        Button { showMyRoutes = true } label: { Image(systemName: "star.circle.fill") }
                            .accessibilityLabel("我的路線")
                    }
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
                .accessibilityLabel(isCardExpanded ? "收合卡片" : "展開卡片")
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
        playback.state == .running || playback.state == .reconnecting
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
                Text("預覽中")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15), in: Capsule())
                    .foregroundStyle(.blue)
            }

            HStack {
                Text("\(route.waypoints.count) 點 · \(route.totalDistance.formattedDistance) · \(route.preferredSpeedKmh.formatted(.number.precision(.fractionLength(1)))) km/h")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 8) {
                Button("開始路線") {
                    model.requestStartRoute(route)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("編輯") {
                    NotificationCenter.default.post(name: .switchToRoutesTab, object: nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("取消預覽", role: .cancel) {
                    model.cancelRoutePreview()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var activePlaybackContent: some View {
        HStack {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .foregroundStyle(.blue)
            Text(playback.routeName)
                .font(.subheadline.bold())
                .lineLimit(1)
            Spacer()
            Text(L10n.format("第 %d 圈", playback.lapNumber))
                .font(.caption.bold())
            Button("停止") {
                playback.stop(clearMarker: true)
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
                    Text("\(playback.speedKmh.formatted(.number.precision(.fractionLength(1)))) km/h")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if model.simulationMode.isSimulating {
                    Button("恢復真實位置", role: .destructive) {
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
                    Text(String(format: "%.6f, %.6f", selected.latitude, selected.longitude))
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)

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

                        Spacer()
                    }

                    if model.simulationMode.isSimulating {
                        Button("恢復真實位置", role: .destructive) {
                            Task { await model.returnToRealLocation() }
                        }
                        .font(.footnote)
                    }
                }
            } else {
                HStack {
                    Text(String(format: "%.6f, %.6f", selected.latitude, selected.longitude))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    Spacer()
                    Button("在此模擬") {
                        model.requestSinglePointSimulation()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        } else {
            if isCardExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("在單點模式下點選地圖或搜尋以選擇模擬位置。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("輸入精確座標") {
                        showCoordinateEntry = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if model.simulationMode.isSimulating {
                        Button("恢復真實位置", role: .destructive) {
                            Task { await model.returnToRealLocation() }
                        }
                        .font(.footnote)
                    }
                }
            } else {
                Text("點選地圖以選擇模擬位置")
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
                    Text("在路線模式下點選地圖或使用搜尋以依序新增航點。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button {
                            showMyRoutes = true
                        } label: {
                            Label("我的路線", systemImage: "star.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer()
                    }
                    if model.simulationMode.isSimulating {
                        Button("恢復真實位置", role: .destructive) {
                            Task { await model.returnToRealLocation() }
                        }
                        .font(.footnote)
                    }
                }
            } else {
                HStack {
                    Text("點選地圖以新增航點")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showMyRoutes = true
                    } label: {
                        Label("我的路線", systemImage: "star.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        } else if model.waypoints.count == 1 {
            HStack {
                Text("已新增 1 個航點，請點選下一個航點")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("復原") { model.undoLastWaypoint() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else {
            if isCardExpanded {
                VStack(alignment: .leading, spacing: 8) {
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
                        Button("清除", role: .destructive) { showClearDraftAlert = true }
                            .buttonStyle(.bordered)
                        Button { showMyRoutes = true } label: { Image(systemName: "star.circle.fill") }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("儲存路線") { showSaveSheet = true }
                            .buttonStyle(.bordered)
                            .disabled(model.geometry.totalDistance <= 0 || model.navigationGeometryNeedsRecalculation)
                        Button("開始路線") { Task { await model.startPlayback() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.geometry.totalDistance <= 0 || model.navigationGeometryNeedsRecalculation)
                    }

                    if model.simulationMode.isSimulating {
                        Button("恢復真實位置", role: .destructive) {
                            Task { await model.returnToRealLocation() }
                        }
                        .font(.footnote)
                    }
                }
            } else {
                HStack {
                    Text("\(model.waypoints.count) 點 · \(model.geometry.totalDistance.formattedDistance) · \(model.speedKmh.formatted(.number.precision(.fractionLength(1)))) km/h")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button { showMyRoutes = true } label: { Image(systemName: "star.circle.fill") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("開始路線") { Task { await model.startPlayback() } }
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
