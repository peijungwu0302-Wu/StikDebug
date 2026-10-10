import SwiftUI
import CoreLocation
import UIKit

enum RouteFloatingCardMode {
    case preview(SavedRoute)
    case active
}

struct RouteFloatingCard: View {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var playback: RoutePlaybackEngine

    let mode: RouteFloatingCardMode
    let onStartRoute: () -> Void
    let onEdit: () -> Void
    let onCancelPreview: () -> Void
    let onEndRoute: () -> Void
    let onRestoreRealLocation: () -> Void
    let onFavoriteUnsavedRoute: () -> Void

    @State private var isEditingSpeed = false
    @State private var editedSpeed = ""
    @FocusState private var speedFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch mode {
            case .preview(let route):
                previewContent(route: route)
            case .active:
                activeContent
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onChange(of: playback.state) { _, state in
            guard state == .reconnecting else { return }
            isEditingSpeed = false
            speedFieldFocused = false
        }
        .onChange(of: speedFieldFocused) { _, focused in
            guard !focused, isEditingSpeed else { return }
            editedSpeed = String(format: "%.1f", playback.speedKmh)
            isEditingSpeed = false
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.text("完成")) { commitSpeedEdit() }
            }
        }
    }

    // MARK: - Preview Mode

    @ViewBuilder
    private func previewContent(route: SavedRoute) -> some View {
        let geometryText = route.isClosedLoop ? L10n.text("封閉") : L10n.text("開放")
        let repeatText = playbackRepeatText(route.playbackMode, isClosedLoop: route.isClosedLoop)

        HStack {
            Image(systemName: "eye.fill").foregroundStyle(.blue)
            Text(route.name)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Text(L10n.text("預覽中"))
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.blue.opacity(0.15), in: Capsule())
                .foregroundStyle(.blue)
        }

        Text("\(route.totalDistance.formattedCardDistance) · \(route.preferredSpeedKmh.formatted(.number.precision(.fractionLength(1)))) km/h · \(geometryText) · \(repeatText)")
            .font(.caption)
            .foregroundStyle(.secondary)

        RouteEndpointTimeZoneSummary(route: route)

        HStack(spacing: 8) {
            Button(L10n.text("開始路線")) { onStartRoute() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel(L10n.text("開始路線"))
                .tutorialTarget(.startRoute)

            Button(L10n.text("編輯")) { onEdit() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(L10n.text("編輯"))

            Spacer()

            Button(L10n.text("取消預覽"), role: .cancel) { onCancelPreview() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(L10n.text("取消預覽"))
        }
    }

    private func playbackRepeatText(_ mode: RoutePlaybackMode, isClosedLoop: Bool) -> String {
        switch mode {
        case .once: return L10n.text(isClosedLoop ? "1 圈" : "1 次")
        case .infiniteLoop: return "∞"
        case .finite(let count): return L10n.format("%d 圈", count)
        }
    }

    // MARK: - Active Mode

    @ViewBuilder
    private var activeContent: some View {
        let isRunning = playback.state == .running
        let isPaused = playback.state == .paused
        let isReconnecting = playback.state == .reconnecting

        HStack {
            if playback.state.interruptionMessage != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if isReconnecting {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: isRunning ? "play.fill" : "pause.fill")
                    .foregroundStyle(isRunning ? .green : .orange)
            }
            Text(playback.routeName)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 8)
            if isReconnecting {
                Text(L10n.text("重新連線中…"))
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            } else if let lapText = playbackLapText {
                Text(lapText)
                    .font(.caption.bold())
            }
        }

        if let message = playback.state.interruptionMessage {
            Text(message).font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        let progressTotal = PlaybackMath.completionDistance(total: model.geometry.totalDistance, mode: model.playbackMode)
        let progressValue = progressTotal.isFinite ? playback.traveledDistance : playback.distanceWithinLap
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                Text("\(playback.traveledDistance.formattedCardDistance) / \(model.geometry.totalDistance.formattedCardDistance)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ProgressView(
                    value: min(max(progressValue, 0), progressTotal.isFinite ? progressTotal : model.geometry.totalDistance),
                    total: progressTotal.isFinite ? progressTotal : model.geometry.totalDistance
                )
                .tint(.blue)
                .frame(minWidth: 120)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                activeSpeedControl(isReconnecting: !playback.state.allowsSpeedEditing)
            }

            if let current = model.activeSimulatedCoordinate {
                CoordinateValueText(coordinate: current)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 0.5) {
                        CoordinateClipboard.copy(current, toastKey: "已複製目前座標")
                    }
                    .accessibilityLabel(L10n.text("目前模擬座標"))
                    .accessibilityHint(L10n.text("長按以複製目前座標"))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)

        RouteEndpointTimeZoneSummary(waypoints: model.waypoints, isClosedLoop: model.isClosedLoop)

        HStack {
            if isRunning {
                Button(L10n.text("暫停移動")) { playback.pause() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel(L10n.text("暫停移動"))
                    .tutorialTarget(.pauseRoute)
            } else if isPaused {
                Button(L10n.text("繼續")) { Task { await playback.resume() } }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel(L10n.text("繼續"))
                    .tutorialTarget(.resumeRoute)
            } else if isReconnecting {
                Text(L10n.text("重新連線中…"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if playback.state.interruptionMessage != nil {
                Text(L10n.text("路線已中斷")).font(.footnote).foregroundStyle(.orange)
            }

            Spacer(minLength: 8)

            if playback.state.showsRouteControls {
                Button(action: onEndRoute) {
                    Image(systemName: "stop.fill")
                        .font(.caption.bold())
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("停止並停留目前位置"))
                .tutorialTarget(.stopAndHold)
            }

            Button(action: copyCurrentRoute) {
                Image(systemName: "doc.on.doc")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("複製路線"))

            Menu {
                if model.currentSavedRoute != nil {
                    Button(L10n.text(model.currentRouteIsFavorite ? "取消收藏目前路線" : "收藏目前路線")) {
                        Task { await model.toggleFavoriteCurrentRoute() }
                    }
                } else {
                    Button(L10n.text("收藏目前路線"), action: onFavoriteUnsavedRoute)
                }
                Button(L10n.text("停止並停留目前位置"), action: onEndRoute)
                Button(L10n.text("停止路線並恢復真實位置"), role: .destructive, action: onRestoreRealLocation)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(L10n.text("更多路線操作"))
            .tutorialTarget(.restore)
            .tutorialTarget(.recovery)
        }
    }

    private func copyCurrentRoute() {
        guard let value = model.currentRouteCopyText() else { return }
        UIPasteboard.general.string = value
        ToastManager.shared.show(L10n.text("已複製路線"), kind: .info)
    }

    private func beginSpeedEdit() {
        guard playback.state == .running || playback.state == .paused else { return }
        // Keep the committed speed in the model until a valid replacement is
        // submitted. Starting with an empty edit value lets users type over
        // the old number immediately.
        editedSpeed = ""
        isEditingSpeed = true
        speedFieldFocused = true
    }

    private func commitSpeedEdit() {
        if let value = PlaybackSpeedEntryPolicy.committedValue(editedSpeed, preserving: playback.speedKmh) {
            model.setPlaybackSpeed(value)
        }
        editedSpeed = String(format: "%.1f", playback.speedKmh)
        speedFieldFocused = false
        isEditingSpeed = false
    }

    private var playbackLapText: String? {
        guard model.isClosedLoop else { return nil }
        switch model.playbackMode {
        case .once: return L10n.format("第 %d 圈", playback.lapNumber)
        case .infiniteLoop: return L10n.format("第 %d 圈 · ∞", playback.lapNumber)
        case .finite(let count): return L10n.format("第 %d / %d 圈", playback.lapNumber, count)
        }
    }

    @ViewBuilder
    private func activeSpeedControl(isReconnecting: Bool) -> some View {
        HStack(spacing: 2) {
                Button { model.adjustPlaybackSpeed(by: -0.1) } label: { Image(systemName: "minus") }
                    .buttonStyle(.bordered)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(isReconnecting)
                    .accessibilityLabel(L10n.text("降低速度 0.1 公里每小時"))
                if isEditingSpeed && !isReconnecting {
                    TextField(L10n.text("速度"), text: $editedSpeed)
                        .keyboardType(.decimalPad)
                        .focused($speedFieldFocused)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .frame(width: 58)
                        .onSubmit { commitSpeedEdit() }
                        .accessibilityLabel(L10n.text("播放速度"))
                } else {
                    Button {
                        beginSpeedEdit()
                    } label: {
                        HStack(spacing: 3) {
                            Text(playback.speedKmh.formatted(.number.precision(.fractionLength(1))))
                                .monospacedDigit()
                            Text("km/h")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(minWidth: 70, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(isReconnecting)
                    .accessibilityLabel(L10n.text("播放速度"))
                    .accessibilityHint(L10n.text("點一下編輯速度"))
                }
                Button { model.adjustPlaybackSpeed(by: 0.1) } label: { Image(systemName: "plus") }
                    .buttonStyle(.bordered)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(isReconnecting)
                    .accessibilityLabel(L10n.text("提高速度 0.1 公里每小時"))
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Identity is limited to route endpoints, never a playback-frame coordinate.
struct RouteTimeZoneEndpoints: Hashable {
    let start: RouteCoordinate
    let end: RouteCoordinate
    let returnsToStart: Bool

    init?(waypoints: [RouteCoordinate], isClosedLoop: Bool) {
        guard let first = waypoints.first, let last = waypoints.last else { return nil }
        start = first
        end = isClosedLoop ? first : last
        returnsToStart = isClosedLoop
    }
}

enum RouteTimeZonePresentation {
    static func summary(start: PlaceInfo?, end: PlaceInfo?, at date: Date) -> String? {
        guard let startID = start?.timeZoneIdentifier, let endID = end?.timeZoneIdentifier,
              let startZone = TimeZone(identifier: startID),
              let endZone = TimeZone(identifier: endID) else { return nil }
        let first = "\(startID) · \(PlaceTimeFormatter.gmtOffsetText(for: startZone, at: date))"
        if startID == endID { return first }
        return L10n.format("%@ → %@", first, "\(endID) · \(PlaceTimeFormatter.gmtOffsetText(for: endZone, at: date))")
    }
}

struct RouteEndpointTimeZoneSummary: View {
    let waypoints: [RouteCoordinate]
    let isClosedLoop: Bool
    @State private var startInfo: PlaceInfo?
    @State private var endInfo: PlaceInfo?
    @State private var expanded = false
    @AppStorage("RouteLocation.timeZoneComparisonBaseline") private var baselineRawValue = TimeZoneComparisonBaseline.taiwan.rawValue

    init(route: SavedRoute) {
        waypoints = route.waypoints
        isClosedLoop = route.isClosedLoop
    }

    init(waypoints: [RouteCoordinate], isClosedLoop: Bool) {
        self.waypoints = waypoints
        self.isClosedLoop = isClosedLoop
    }

    private var endpoints: RouteTimeZoneEndpoints? {
        RouteTimeZoneEndpoints(waypoints: waypoints, isClosedLoop: isClosedLoop)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    endpointDetails(startInfo, title: L10n.text("起點"), date: context.date)
                    if endpoints?.returnsToStart == true {
                        Text(L10n.text("封閉路線返回起點，終點時區與起點相同。"))
                    } else if endpoints?.start != endpoints?.end {
                        endpointDetails(endInfo, title: L10n.text("終點"), date: context.date)
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(RouteTimeZonePresentation.summary(start: startInfo, end: endInfo, at: context.date) ?? L10n.text("路線時區"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .task(id: endpoints) {
            startInfo = nil
            endInfo = nil
            guard let endpoints else { return }
            if endpoints.start == endpoints.end {
                let info = await PlaceInfoResolver.shared.resolve(endpoints.start, scope: .general)
                guard !Task.isCancelled else { return }
                startInfo = info
                endInfo = info
            } else {
                async let start = PlaceInfoResolver.shared.resolve(endpoints.start, scope: .general)
                async let end = PlaceInfoResolver.shared.resolve(endpoints.end, scope: .general)
                let values = await (start, end)
                guard !Task.isCancelled else { return }
                startInfo = values.0
                endInfo = values.1
            }
        }
    }

    @ViewBuilder
    private func endpointDetails(_ info: PlaceInfo?, title: String, date: Date) -> some View {
        if let info, let identifier = info.timeZoneIdentifier, let zone = TimeZone(identifier: identifier) {
            Text(title).fontWeight(.semibold)
            Text([info.country, info.administrativeArea, info.locality, info.subLocality].compactMap { $0 }.joined(separator: " · "))
            Text("\(identifier) · \(PlaceTimeFormatter.gmtOffsetText(for: zone, at: date))")
            Text(localTime(date, zone: zone))
            Text(PlaceTimeFormatter.offsetText(for: zone, at: date, baseline: TimeZoneComparisonBaseline(rawValue: baselineRawValue) ?? .taiwan))
        } else {
            Text(L10n.format("%@：時區資訊暫時無法取得，不影響定位模擬。", title))
                .foregroundStyle(.secondary)
        }
    }

    private func localTime(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private extension CLLocationDistance {
    var formattedCardDistance: String {
        self >= 1000 ? String(format: "%.2f km", self / 1000) : String(format: "%.0f m", self)
    }
}
