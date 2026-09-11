import MapKit
import SwiftUI

struct RouteMapView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var playback: RoutePlaybackEngine
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showSearch = false
    @State private var showFavoriteName = false
    @State private var showPaste = false
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
            .navigationTitle(ProductIdentity.name)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                    Button { showPaste = true } label: { Image(systemName: "doc.on.clipboard") }
                    Button { fitRoute() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
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
        .sheet(isPresented: $showPaste) {
            CoordinatePasteView { coordinates in
                if let first = coordinates.first { model.selectedCoordinate = first }
                if coordinates.count > 1 { model.replaceWaypoints(coordinates) }
            }
        }
        .alert("儲存喜好地點", isPresented: $showFavoriteName) {
            TextField("名稱", text: $favoriteName)
            Button("儲存") { Task { await model.addFavorite(name: favoriteName); favoriteName = "" } }
            Button("取消", role: .cancel) {}
        }
    }

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(model.connectionMonitor.tunnelConnected ? .green : .orange).frame(width: 9, height: 9)
                Text(model.connectionMonitor.tunnelConnected ? "裝置通道已連線" : "請連接 LocalDevVPN")
                    .font(.caption)
                Spacer()
                Text(playback.state.label).font(.caption).foregroundStyle(.secondary)
            }
            if let selected = model.selectedCoordinate {
                Text(String(format: "%.6f, %.6f", selected.latitude, selected.longitude))
                    .font(.footnote.monospaced()).textSelection(.enabled)
                HStack {
                    Button("模擬此位置") { Task { await model.teleport() } }.buttonStyle(.borderedProminent)
                    Button("加入航點") { model.addSelectedWaypoint() }.buttonStyle(.bordered)
                    Button { showFavoriteName = true } label: { Image(systemName: "star") }.buttonStyle(.bordered)
                }
            } else {
                Text("點選地圖、搜尋地點、貼上座標，或選擇喜好地點。").font(.footnote).foregroundStyle(.secondary)
                Button("貼上座標") { showPaste = true }.buttonStyle(.bordered)
            }
            if model.geometry.totalDistance > 0 {
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
                    Button("停止") { playback.stop(clearMarker: false) }.buttonStyle(.bordered).tint(.red)
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
        } catch { errorMessage = "搜尋需要網際網路連線：\(error.localizedDescription)" }
    }
}

private extension CLLocationDistance {
    var formattedDistance: String {
        self >= 1000 ? String(format: "%.2f km", self / 1000) : String(format: "%.0f m", self)
    }
}
