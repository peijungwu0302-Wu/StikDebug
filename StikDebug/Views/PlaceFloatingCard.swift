import SwiftUI
import UIKit

enum MapBottomCardExpansion: String {
    case collapsed
    case expanded

    mutating func snap(for translation: CGFloat) {
        if translation < -36 { self = .expanded }
        if translation > 36 { self = .collapsed }
    }
}

/// A fixed two-detent map card. It is not a modal sheet, so the map remains
/// visible and interactive behind it.
struct MapBottomCardShell: View {
    @Binding var expansion: MapBottomCardExpansion
    let content: (_ expanded: Bool) -> AnyView

    var body: some View {
        VStack(spacing: 4) {
            Capsule().fill(.secondary.opacity(0.45)).frame(width: 36, height: 4).padding(.top, 4)
            content(expansion == .expanded)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture {
            guard expansion == .collapsed else { return }
            withAnimation(.snappy(duration: 0.22)) { expansion = .expanded }
        }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onEnded { value in
                    var next = expansion
                    next.snap(for: value.translation.height)
                    guard next != expansion else { return }
                    withAnimation(.snappy(duration: 0.22)) { expansion = next }
                }
        )
        .accessibilityValue(expansion == .expanded ? L10n.text("已展開") : L10n.text("已收起"))
    }
}

enum CoordinateClipboard {
    @MainActor static func copy(_ coordinate: RouteCoordinate) {
        UIPasteboard.general.string = String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
        ToastManager.shared.show(L10n.text("已複製座標"), kind: .info)
    }
}

struct PlaceFloatingCard: View {
    @EnvironmentObject private var model: RouteLocationModel
    let coordinate: RouteCoordinate
    let onSaveFavorite: () -> Void
    @State private var placeInfo: PlaceInfo?
    @State private var isResolving = false
    @State private var expansion: MapBottomCardExpansion = .collapsed
    @AppStorage("RouteLocation.timeZoneComparisonBaseline") private var baselineRawValue = TimeZoneComparisonBaseline.taiwan.rawValue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            MapBottomCardShell(expansion: $expansion) { expanded in
                AnyView(cardContent(now: context.date, expanded: expanded))
            }
        }
        .task(id: coordinate.id) {
            isResolving = true
            let resolved = await PlaceInfoResolver.shared.resolve(coordinate, scope: .selected)
            guard !Task.isCancelled else { return }
            placeInfo = resolved
            isResolving = false
        }
    }

    @ViewBuilder
    private func cardContent(now: Date, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: expanded ? 9 : 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let flag = CountryFlagFormatter.flag(for: placeInfo?.countryCode) { Text(flag) }
                Text(placeInfo?.bestDisplayName ?? (isResolving ? L10n.text("正在取得地點資訊…") : L10n.text("已選位置")))
                    .font(expanded ? .headline : .subheadline.bold()).lineLimit(1)
                Spacer(minLength: 4)
            }
            if expanded, let placeInfo {
                let hierarchy = [placeInfo.country, placeInfo.administrativeArea, placeInfo.locality, placeInfo.subLocality]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !hierarchy.isEmpty { Text(hierarchy).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            }
            coordinateRow
            if expanded, let details = timeZoneDetails(at: now) {
                Text(details.local).font(.footnote)
                Text(details.gmt).font(.caption).foregroundStyle(.secondary)
                Text(details.offset).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: expanded ? 14 : 10) {
                Button { model.requestSinglePointSimulation(at: coordinate) } label: {
                    Text(L10n.text("在此模擬")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).accessibilityLabel(L10n.text("在此模擬"))
                Button { model.addWaypoint(coordinate) } label: { Image(systemName: "plus") }
                    .buttonStyle(.bordered).frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(L10n.text("加入路線"))
                Button(action: onSaveFavorite) { Image(systemName: "star") }
                    .buttonStyle(.bordered).frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(L10n.text("收藏地點"))
            }
        }
    }

    private var coordinateRow: some View {
        HStack(spacing: 6) {
            Text(String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude))
                .font(.footnote.monospaced()).textSelection(.enabled).lineLimit(1)
            Spacer(minLength: 2)
            Button { CoordinateClipboard.copy(coordinate) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(L10n.text("複製座標"))
        }
    }

    private func timeZoneDetails(at now: Date) -> (local: String, gmt: String, offset: String)? {
        guard let identifier = placeInfo?.timeZoneIdentifier, let timezone = TimeZone(identifier: identifier) else { return nil }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"; formatter.timeZone = timezone
        let baseline = TimeZoneComparisonBaseline(rawValue: baselineRawValue) ?? .taiwan
        return (
            L10n.format("當地時間 %@", formatter.string(from: now)),
            L10n.format("%@ · %@", identifier, PlaceTimeFormatter.gmtOffsetText(for: timezone, at: now)),
            PlaceTimeFormatter.offsetText(for: timezone, at: now, baseline: baseline)
        )
    }
}

struct ActiveSimulationFloatingCard: View {
    @EnvironmentObject private var model: RouteLocationModel
    let coordinate: RouteCoordinate
    let onSaveFavorite: () -> Void
    let onRestore: () -> Void
    @State private var placeInfo: PlaceInfo?
    @State private var expansion: MapBottomCardExpansion = .collapsed
    @AppStorage("RouteLocation.timeZoneComparisonBaseline") private var baselineRawValue = TimeZoneComparisonBaseline.taiwan.rawValue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            MapBottomCardShell(expansion: $expansion) { expanded in
                AnyView(cardContent(now: context.date, expanded: expanded))
            }
        }
        .task(id: coordinate.id) { placeInfo = await PlaceInfoResolver.shared.resolve(coordinate, scope: .general) }
    }

    @ViewBuilder
    private func cardContent(now: Date, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text(L10n.text("模擬位置中")).font(.subheadline.bold())
                Spacer()
            }
            HStack(spacing: 6) {
                if let flag = CountryFlagFormatter.flag(for: placeInfo?.countryCode) { Text(flag) }
                Text(placeInfo?.bestDisplayName ?? L10n.text("模擬位置")).font(expanded ? .subheadline : .caption.bold()).lineLimit(1)
            }
            if expanded, let placeInfo {
                let hierarchy = [placeInfo.country, placeInfo.administrativeArea, placeInfo.locality, placeInfo.subLocality]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !hierarchy.isEmpty { Text(hierarchy).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            HStack(spacing: 6) {
                Text(String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)).font(.footnote.monospaced()).lineLimit(1)
                Spacer()
                Button { CoordinateClipboard.copy(coordinate) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(L10n.text("複製座標"))
            }
            if expanded, let details = timeZoneDetails(at: now) {
                Text(details.local).font(.caption)
                Text(details.gmt).font(.caption2).foregroundStyle(.secondary)
                Text(details.offset).font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button(action: onSaveFavorite) { Label(L10n.text("收藏目前模擬位置"), systemImage: "star") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.text("收藏目前模擬位置"))
                Spacer()
                Button(L10n.text("恢復真實位置"), role: .destructive, action: onRestore)
                    .buttonStyle(.bordered).accessibilityLabel(L10n.text("恢復真實定位"))
            }
        }
    }

    private func timeZoneDetails(at now: Date) -> (local: String, gmt: String, offset: String)? {
        guard let identifier = placeInfo?.timeZoneIdentifier, let timezone = TimeZone(identifier: identifier) else { return nil }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"; formatter.timeZone = timezone
        let baseline = TimeZoneComparisonBaseline(rawValue: baselineRawValue) ?? .taiwan
        return (
            L10n.format("當地時間 %@", formatter.string(from: now)),
            L10n.format("%@ · %@", identifier, PlaceTimeFormatter.gmtOffsetText(for: timezone, at: now)),
            PlaceTimeFormatter.offsetText(for: timezone, at: now, baseline: baseline)
        )
    }
}
