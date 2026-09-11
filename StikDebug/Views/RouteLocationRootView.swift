import SwiftUI

struct RouteLocationRootView: View {
    @EnvironmentObject private var model: RouteLocationModel

    var body: some View {
        TabView {
            RouteMapView().tabItem { Label("地圖", systemImage: "map") }
            RouteEditorView().tabItem { Label("路線", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
            FavoritesView().tabItem { Label("喜好地點", systemImage: "star") }
            SetupDiagnosticsView().tabItem { Label("設定", systemImage: "gearshape") }
        }
        .alert("RouteLocation", isPresented: Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.presentedError = nil } }
        )) { Button("好") { model.presentedError = nil } } message: { Text(model.presentedError ?? "") }
        .overlay(alignment: .top) {
            if let status = model.statusMessage {
                Text(status).font(.footnote).padding(10).background(.regularMaterial, in: Capsule()).padding(.top, 8)
                    .onTapGesture { model.statusMessage = nil }
            }
        }
    }
}
