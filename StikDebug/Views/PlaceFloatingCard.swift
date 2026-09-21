import SwiftUI

struct PlaceFloatingCard: View {
    @EnvironmentObject private var model: RouteLocationModel
    
    let coordinate: RouteCoordinate
    let onSaveFavorite: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude))
                .font(.footnote.monospaced())
                .textSelection(.enabled)
            
            HStack {
                Button {
                    model.requestSinglePointSimulation(at: coordinate)
                } label: {
                    Text(L10n.text("在此模擬"))
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(L10n.text("在此模擬"))
                
                Button {
                    model.addSelectedWaypoint()
                } label: {
                    Text(L10n.text("加入路線"))
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(L10n.text("加入路線"))
                
                Button {
                    onSaveFavorite()
                } label: {
                    Image(systemName: "star")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(L10n.text("收藏地點"))
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
