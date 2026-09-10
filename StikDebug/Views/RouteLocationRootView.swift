import SwiftUI

struct RouteLocationRootView: View {
    @EnvironmentObject private var model: RouteLocationModel

    var body: some View {
        TabView {
            RouteMapView().tabItem { Label("Map", systemImage: "map") }
            RouteEditorView().tabItem { Label("Routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
            FavoritesView().tabItem { Label("Favorites", systemImage: "star") }
            SetupDiagnosticsView().tabItem { Label("Setup", systemImage: "gearshape") }
        }
        .alert("RouteLocation", isPresented: Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.presentedError = nil } }
        )) { Button("OK") { model.presentedError = nil } } message: { Text(model.presentedError ?? "") }
        .overlay(alignment: .top) {
            if let status = model.statusMessage {
                Text(status).font(.footnote).padding(10).background(.regularMaterial, in: Capsule()).padding(.top, 8)
                    .onTapGesture { model.statusMessage = nil }
            }
        }
    }
}
