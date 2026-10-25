import SwiftUI
import MapKit

struct SmartRouteSeed: Identifiable {
    let id = UUID()
    var coordinate: RouteCoordinate?
}

/// Shared by Quick (both layouts) and Classic. Apply is deferred until the
/// sheet is gone so the existing root draft-conflict alert can present safely.
@MainActor
private struct SmartRoutePresentation: ViewModifier {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var tutorialUI: TutorialUIContext
    @Binding var seed: SmartRouteSeed?
    @State private var routeToApply: SavedRoute?
    func body(content: Content) -> some View {
        content
            .sheet(item: $seed, onDismiss: {
                tutorialUI.modalVisible = false
                if let route = routeToApply {
                    routeToApply = nil
                    model.requestApplySmartRoute(route)
                }
            }) { value in
                SmartRouteGeneratorView(initialCoordinate: value.coordinate) { route in
                    routeToApply = route
                    seed = nil
                }
            }
            .onChange(of: seed?.id) { _, id in
                if id != nil { tutorialUI.modalVisible = true }
            }
    }
}

extension View {
    @MainActor func smartRouteGenerator(seed: Binding<SmartRouteSeed?>) -> some View {
        modifier(SmartRoutePresentation(seed: seed))
    }
}

@MainActor
struct SmartRouteGeneratorView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = SmartRouteGenerationSession()
    @State private var center: RouteCoordinate?
    @State private var targetKilometers = 5.0
    @State private var preferredCount = 8
    @State private var speedKmh = 18.6
    @State private var repeatMode = RoutePlaybackMode.infiniteLoop
    @State private var transport = NavigationTransportMode.walking
    @State private var originRole = SmartRouteOriginRole.start
    @State private var kind = SmartRouteKind.loop
    @State private var variation = 0
    @State private var showSearch = false
    @State private var showMapPicker = false
    @State private var showSave = false
    @State private var saveAsFavorite = false
    @State private var routeName = L10n.text("智慧路線")
    @State private var savedRouteID: UUID?
    @State private var isSaving = false
    @State private var saveStatus: String?
    let onApply: (SavedRoute) -> Void

    init(initialCoordinate: RouteCoordinate?, onApply: @escaping (SavedRoute) -> Void) {
        _center = State(initialValue: initialCoordinate)
        self.onApply = onApply
    }

    private var options: SmartRouteOptions {
        SmartRouteOptions(targetDistance: targetKilometers * 1_000, preferredWaypointCount: preferredCount,
                          speedKmh: speedKmh, playbackMode: repeatMode, transport: transport,
                          kind: kind, originRole: originRole, variation: variation)
    }
    private var inputIdentity: String {
        "\(center?.id ?? "none")/\(targetKilometers)/\(preferredCount)/\(transport.rawValue)/\(kind.rawValue)/\(originRole.rawValue)"
    }
    private var savedRoute: SavedRoute? { model.savedRoutes.first { $0.id == savedRouteID } }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("生成位置")) {
                    if let center { CoordinateValueText(coordinate: center) }
                    else { Text(L10n.text("請先搜尋或選擇地圖位置。")).foregroundStyle(.secondary) }
                    HStack {
                        Button(L10n.text("搜尋地點"), systemImage: "magnifyingglass") { showSearch = true }
                            .accessibilityIdentifier("smartRoute.search")
                        Spacer()
                        Button(L10n.text("地圖選點"), systemImage: "map") { showMapPicker = true }
                            .accessibilityIdentifier("smartRoute.pickMap")
                    }
                    .buttonStyle(.borderless)
                    Picker(L10n.text("位置用途"), selection: $originRole) {
                        ForEach(SmartRouteOriginRole.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section(L10n.text("生成條件")) {
                    Stepper(L10n.format("目標距離 %.1f 公里", targetKilometers), value: $targetKilometers, in: 0.5...50, step: 0.5)
                    Stepper(L10n.format("建議主要航點 %d 個", preferredCount), value: $preferredCount, in: 3...24)
                    Picker(L10n.text("交通方式"), selection: $transport) {
                        ForEach(NavigationTransportMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker(L10n.text("路線類型"), selection: $kind) {
                        ForEach(SmartRouteKind.allCases) { Text($0.title).tag($0) }
                    }
                    Text(L10n.text("主要航點是編輯控制點，不是軌跡點上限；必要道路彎道會保留。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(session.candidate == nil ? L10n.text("產生道路路線") : L10n.text("重新產生")) {
                        guard let center else { return }
                        variation &+= 1
                        session.generate(center: center, options: options)
                        savedRouteID = nil; saveStatus = nil
                    }
                    .accessibilityIdentifier("smartRoute.generate")
                    .disabled(center == nil || session.isGenerating || isSaving || !options.isValid)
                    if session.isGenerating {
                        HStack {
                            ProgressView()
                            Text(L10n.text("正在驗證道路與距離…"))
                            Spacer()
                            Button(L10n.text("取消")) { session.cancel() }
                        }
                    }
                    if let error = session.error {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                        if kind == .loop {
                            Button(L10n.text("明確改試折返路線")) { kind = .outAndBack }
                        }
                    }
                    Text(L10n.text("使用 Apple 地圖有限候選導航，並非完整道路拓撲。部分山區與步道無法生成；失敗時不會改成直線。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let candidate = session.candidate {
                    candidateSection(candidate)
                }
            }
            .navigationTitle(L10n.text("智慧路線"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("取消")) { session.cancel(); dismiss() }
                        .accessibilityIdentifier("smartRoute.cancel")
                }
            }
            .sheet(isPresented: $showSearch) {
                LocationSearchPicker { center = $0 }
            }
            .sheet(isPresented: $showMapPicker) {
                SmartRouteLocationPicker(initial: center) { center = $0 }
            }
            .alert(L10n.text("儲存智慧路線"), isPresented: $showSave) {
                TextField(L10n.text("路線名稱"), text: $routeName)
                Button(L10n.text("儲存")) { saveCandidate() }
                    .disabled(routeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L10n.text("取消"), role: .cancel) {}
            }
            .onChange(of: inputIdentity) { _, _ in
                session.invalidate(); savedRouteID = nil; saveStatus = nil
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { session.cancel() } }
            .onDisappear { session.cancel() }
        }
    }

    @ViewBuilder private func candidateSection(_ candidate: SmartRouteCandidate) -> some View {
        Section(L10n.text("候選預覽")) {
            Map(initialPosition: .automatic) {
                MapPolyline(coordinates: candidate.geometry.coordinates.map(\.clCoordinate)).stroke(.blue, lineWidth: 4)
                if let first = candidate.geometry.coordinates.first {
                    Marker(L10n.text("起點／終點"), coordinate: first.clCoordinate)
                }
            }
            .frame(height: 190)
            .id(candidate.id)
            Text(L10n.format("實際 %.2f 公里 · %d 個主要航點", candidate.geometry.totalDistance / 1_000, candidate.waypoints.count))
                .accessibilityIdentifier("smartRoute.candidate.summary")
            Text(L10n.format("與目標差異 %@", String(format: "%+.1f%%", candidate.deviation * 100)))
            Text(candidate.kind.title).foregroundStyle(.secondary)
            if candidate.usesRelaxedDistance {
                Text(L10n.text("未找到 ±15% 內候選，本結果使用 ±20% 容差。")).font(.caption).foregroundStyle(.secondary)
            }
            Stepper(L10n.format("速度 %.1f km/h", speedKmh), value: $speedKmh, in: 0.1...300, step: 0.1)
            Picker(L10n.text("播放次數"), selection: $repeatMode) {
                Text(L10n.text("無限循環")).tag(RoutePlaybackMode.infiniteLoop)
                Text(L10n.text("1 圈")).tag(RoutePlaybackMode.once)
                Text(L10n.text("3 圈")).tag(RoutePlaybackMode.finite(3))
                Text(L10n.text("5 圈")).tag(RoutePlaybackMode.finite(5))
            }
            Button(L10n.text("套用為路線草稿")) {
                var route = savedRoute ?? candidate.savedRoute(name: routeName, speedKmh: speedKmh, playbackMode: repeatMode)
                route.preferredSpeedKmh = speedKmh
                route.playbackMode = repeatMode
                onApply(route)
            }
            .disabled(model.isAnyRouteActive || isSaving)
            .accessibilityIdentifier("smartRoute.apply")
            if model.isAnyRouteActive {
                Text(L10n.text("路線播放中，請先停止路線再編輯。")).font(.caption)
            }
            Text(L10n.text("套用後可在原有路線卡編輯航點並手動開始播放；不會自動模擬。"))
                .font(.caption).foregroundStyle(.secondary)
            if let savedRoute {
                Text(savedRoute.name).font(.caption)
                Button(L10n.text(savedRoute.isFavorite ? "取消收藏目前路線" : "收藏目前路線")) {
                    isSaving = true
                    Task { await model.toggleFavoriteRoute(savedRoute); isSaving = false }
                }.buttonStyle(.borderless).disabled(isSaving)
            } else {
                HStack {
                    Button(L10n.text("儲存路線")) { saveAsFavorite = false; showSave = true }
                    Spacer()
                    Button(L10n.text("收藏目前路線")) { saveAsFavorite = true; showSave = true }
                }.disabled(isSaving)
            }
            if let saveStatus { Text(saveStatus).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func saveCandidate() {
        guard let candidate = session.candidate, !isSaving else { return }
        isSaving = true
        Task {
            let saved = await model.saveSmartRouteCandidate(candidate, named: routeName, speedKmh: speedKmh,
                                                           playbackMode: repeatMode, favorite: saveAsFavorite)
            isSaving = false
            guard session.candidate?.id == candidate.id else { return }
            savedRouteID = saved?.id
            saveStatus = saved == nil ? L10n.text("無法儲存路線；尚未加入收藏，請重試。") : L10n.text("路線已儲存，可離線播放。")
        }
    }
}

@MainActor
private struct SmartRouteLocationPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: RouteCoordinate?
    @State private var camera: MapCameraPosition
    let onSelect: (RouteCoordinate) -> Void
    init(initial: RouteCoordinate?, onSelect: @escaping (RouteCoordinate) -> Void) {
        _selection = State(initialValue: initial)
        _camera = State(initialValue: .region(MKCoordinateRegion(center: initial?.clCoordinate ?? CLLocationCoordinate2D(latitude: 25.033964, longitude: 121.564468), latitudinalMeters: 5_000, longitudinalMeters: 5_000)))
        self.onSelect = onSelect
    }
    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera) {
                    if let selection { Marker(L10n.text("已選位置"), coordinate: selection.clCoordinate) }
                }
                .onTapGesture { point in
                    if let coordinate = proxy.convert(point, from: .local) { selection = RouteCoordinate(coordinate) }
                }
            }
            .navigationTitle(L10n.text("地圖選點"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("使用此位置")) { if let selection { onSelect(selection); dismiss() } }
                        .disabled(selection == nil)
                }
            }
        }
    }
}
