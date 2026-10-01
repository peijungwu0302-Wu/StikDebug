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

        HStack(spacing: 8) {
            Button(L10n.text("開始路線")) { onStartRoute() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel(L10n.text("開始路線"))

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
            if isReconnecting {
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

        let progressTotal = PlaybackMath.completionDistance(total: model.geometry.totalDistance, mode: model.playbackMode)
        let progressValue = progressTotal.isFinite ? playback.traveledDistance : playback.distanceWithinLap
        VStack(alignment: .leading, spacing: 4) {
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
            // Keep distance and progress clear of the speed control, while the
            // coordinate row can use the full card width. The left-side lines
            // keep their 4pt rhythm; the outer 56pt minimum preserves the
            // previous speed-control height and the action row's position.
            .padding(.trailing, 174)

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
        .overlay(alignment: .topTrailing) {
            activeSpeedControl(isReconnecting: isReconnecting)
        }

        HStack {
            if isRunning {
                Button(L10n.text("暫停移動")) { playback.pause() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel(L10n.text("暫停移動"))
            } else if isPaused {
                Button(L10n.text("繼續")) { Task { await playback.resume() } }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel(L10n.text("繼續"))
            } else if isReconnecting {
                Text(L10n.text("重新連線中…"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

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
                Button(L10n.text("停止並停留目前位置"), role: .destructive, action: onEndRoute)
                Button(L10n.text("停止路線並恢復真實位置"), role: .destructive, action: onRestoreRealLocation)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(L10n.text("更多路線操作"))
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

private extension CLLocationDistance {
    var formattedCardDistance: String {
        self >= 1000 ? String(format: "%.2f km", self / 1000) : String(format: "%.0f m", self)
    }
}
