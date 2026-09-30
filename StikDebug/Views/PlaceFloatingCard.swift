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
                    Text(country + countryFlag)
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
            if let timeZoneDetails {
                Text(timeZoneDetails.local).font(.footnote)
                Text(timeZoneDetails.gmt).font(.caption).foregroundStyle(.secondary)
                Text(timeZoneDetails.offset).font(.caption).foregroundStyle(.secondary)
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

    private var countryFlag: String {
        switch placeInfo?.countryCode {
        case "TW": return " 🇹🇼"
        case "JP": return " 🇯🇵"
        default: return ""
        }
    }

    private var timeZoneDetails: (local: String, gmt: String, offset: String)? {
        guard let identifier = placeInfo?.timeZoneIdentifier,
              let timezone = TimeZone(identifier: identifier) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = timezone
        return (
            L10n.format("當地時間 %@", formatter.string(from: .now)),
            L10n.format("%@ · GMT%+d", identifier, timezone.secondsFromGMT() / 3600),
            PlaceTimeFormatter.offsetText(for: timezone)
        )
    }
}
