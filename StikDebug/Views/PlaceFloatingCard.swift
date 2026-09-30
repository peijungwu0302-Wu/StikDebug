import SwiftUI
import UIKit

struct PlaceFloatingCard: View {
    @EnvironmentObject private var model: RouteLocationModel
    
    let coordinate: RouteCoordinate
    let onSaveFavorite: () -> Void
    @State private var placeInfo: PlaceInfo?
    @State private var isResolving = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let placeInfo {
                if let name = placeInfo.bestDisplayName { Text(name).font(.headline) }
                if let country = placeInfo.country {
                    Text("\(country)\(placeInfo.countryCode == \"TW\" ? \" 🇹🇼\" : placeInfo.countryCode == \"JP\" ? \" 🇯🇵\" : \"\")")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else if isResolving {
                Text(L10n.text("正在取得地點資訊…")).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack {
            Text(String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude))
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                Spacer()
                Button { UIPasteboard.general.string = String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude); ToastManager.shared.show(L10n.text("已複製座標"), kind: .info) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("複製座標"))
            }
            if let identifier = placeInfo?.timeZoneIdentifier, let timezone = TimeZone(identifier: identifier) {
                let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"; formatter.timeZone = timezone
                Text(L10n.format("當地時間 %@", formatter.string(from: .now))).font(.footnote)
                Text(L10n.format("%@ · GMT%+d", identifier, timezone.secondsFromGMT() / 3600)).font(.caption).foregroundStyle(.secondary)
                Text(PlaceTimeFormatter.offsetText(for: timezone)).font(.caption).foregroundStyle(.secondary)
            }
            
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
        .task(id: coordinate.id) {
            isResolving = true
            placeInfo = await PlaceInfoResolver.shared.resolve(coordinate)
            isResolving = false
        }
    }
}
