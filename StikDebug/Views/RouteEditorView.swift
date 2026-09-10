import SwiftUI

struct RouteEditorView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @State private var showPaste = false
    @State private var showImporter = false
    @State private var showSearch = false

    var body: some View {
        NavigationStack {
            List {
                Section("Route") {
                    TextField("Route name", text: $model.routeName)
                    Picker("Geometry", selection: $model.routeMode) {
                        ForEach(RouteMode.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    if model.routeMode == .navigation {
                        Picker("Transport", selection: $model.navigationTransport) {
                            ForEach(NavigationTransportMode.allCases) { Text($0.title).tag($0) }
                        }
                        if model.navigationGeometryNeedsRecalculation {
                            Label("Geometry needs recalculation", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        Button(model.isResolvingNavigation ? "Calculating…" : "Calculate with Apple Maps") {
                            Task { await model.recalculateNavigation() }
                        }.disabled(model.isResolvingNavigation || model.waypoints.count < 2)
                    }
                    Toggle("Closed Route", isOn: $model.isClosedLoop)
                }

                Section("Waypoints (\(model.waypoints.count))") {
                    ForEach(Array(model.waypoints.enumerated()), id: \.offset) { index, waypoint in
                        WaypointRow(index: index, waypoint: waypoint) { latitude, longitude in
                            model.updateWaypoint(at: index, latitude: latitude, longitude: longitude)
                        }
                    }
                    .onDelete(perform: model.removeWaypoints)
                    .onMove(perform: model.moveWaypoints)
                    HStack {
                        Button("Paste") { showPaste = true }
                        Spacer(); Button("Import File") { showImporter = true }
                        Spacer(); Button("Search") { showSearch = true }
                    }
                    if model.selectedCoordinate != nil { Button("Add Selected Map Point") { model.addSelectedWaypoint() } }
                    Button("Clear All", role: .destructive) { model.clearWaypoints() }.disabled(model.waypoints.isEmpty)
                }

                Section("Playback") {
                    HStack {
                        TextField("Speed", value: $model.speedKmh, format: .number)
                            .keyboardType(.decimalPad)
                        Text("km/h").foregroundStyle(.secondary)
                    }
                    Picker("Mode", selection: $model.playbackMode) {
                        ForEach(RoutePlaybackMode.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Distance", value: model.geometry.totalDistance.formattedRouteDistance)
                    LabeledContent("Estimated lap", value: model.estimatedLapDuration?.formattedDuration ?? "—")
                    Button("Start Playback") { Task { await model.startPlayback() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.geometry.totalDistance <= 0 || model.navigationGeometryNeedsRecalculation)
                    Button("Save Route") { Task { await model.saveCurrentRoute() } }
                        .disabled(model.geometry.totalDistance <= 0 || model.navigationGeometryNeedsRecalculation)
                }

                Section("Saved Routes") {
                    if model.savedRoutes.isEmpty { Text("No saved routes yet.").foregroundStyle(.secondary) }
                    ForEach(model.savedRoutes) { route in
                        Button { model.loadRoute(route) } label: {
                            VStack(alignment: .leading) {
                                Text(route.name).foregroundStyle(.primary)
                                Text("\(route.routeMode.title) • \(route.totalDistance.formattedRouteDistance) • \(route.preferredSpeedKmh.formatted(.number.precision(.fractionLength(1)))) km/h")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.swipeActions { Button("Delete", role: .destructive) { Task { await model.deleteRoute(route) } } }
                    }
                }
            }
            .navigationTitle("Routes")
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
            Text("Waypoint \(index + 1)").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Latitude", text: $latitude).keyboardType(.numbersAndPunctuation)
                TextField("Longitude", text: $longitude).keyboardType(.numbersAndPunctuation)
                Button("Update") { if let lat = Double(latitude), let lon = Double(longitude) { onSave(lat, lon) } }
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
                Text("One latitude,longitude pair per line. CSV headers, semicolons, and tabs are supported.").font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $text).font(.body.monospaced()).border(.quaternary)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }.padding().navigationTitle("Paste Coordinates")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Import") { parse() } }
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
