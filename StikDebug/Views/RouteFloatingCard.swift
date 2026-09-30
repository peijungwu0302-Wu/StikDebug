import SwiftUI
import CoreLocation

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

    @State private var showMoreActions = false
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
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.text("完成")) { commitSpeedEdit() }
            }
        }
        .confirmationDialog(L10n.text("更多操作"), isPresented: $showMoreActions, titleVisibility: .hidden) {
            if let current = model.activeSimulatedCoordinate {
                Button(L10n.text("收藏目前位置")) {
                    Task { await model.addFavorite(name: model.suggestedFavoriteName(), coordinate: current) }
                }
            }
            Button(L10n.text("停止並停留目前位置"), role: .destructive) {
                onEndRoute()
            }
            Button(L10n.text("恢復真實位置"), role: .destructive) {
                onRestoreRealLocation()
            }
            Button(L10n.text("取消"), role: .cancel) {}
        }
    }

    // MARK: - Preview Mode

    @ViewBuilder
    private func previewContent(route: SavedRoute) -> some View {
        let geometryText = route.isClosedLoop ? L10n.text("封閉") : L10n.text("開放")
        let repeatText: String
        switch route.playbackMode {
        case .once: repeatText = L10n.text("1 次")
        case .infiniteLoop: repeatText = "∞"
        case .finite(let count): repeatText = L10n.format("%d 圈", count)
        }

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

        Text("\(playback.traveledDistance.formattedCardDistance) / \(model.geometry.totalDistance.formattedCardDistance) · \(playback.speedKmh.formatted(.number.precision(.fractionLength(1)))) km/h")
            .font(.footnote)
            .foregroundStyle(.secondary)

        let progressTotal = PlaybackMath.completionDistance(total: model.geometry.totalDistance, mode: model.playbackMode)
        let progressValue = progressTotal.isFinite ? playback.traveledDistance : playback.distanceWithinLap
        ProgressView(value: min(max(progressValue, 0), progressTotal.isFinite ? progressTotal : model.geometry.totalDistance), total: progressTotal.isFinite ? progressTotal : model.geometry.totalDistance)
            .tint(.blue)

        HStack(spacing: 8) {
            Button { model.adjustPlaybackSpeed(by: -0.1) } label: { Image(systemName: "minus") }
                .buttonStyle(.bordered).frame(minWidth: 44, minHeight: 44)
                .disabled(isReconnecting)
                .accessibilityLabel(L10n.text("降低速度 0.1 公里每小時"))
            if isEditingSpeed && !isReconnecting {
                TextField(L10n.text("速度"), text: $editedSpeed)
                    .keyboardType(.decimalPad)
                    .focused($speedFieldFocused)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 68)
                    .onSubmit { commitSpeedEdit() }
                    .accessibilityLabel(L10n.text("播放速度"))
            } else {
                Button {
                    beginSpeedEdit()
                } label: {
                    Text(playback.speedKmh.formatted(.number.precision(.fractionLength(1))))
                        .monospacedDigit()
                        .frame(minWidth: 48, minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(isReconnecting)
                .accessibilityLabel(L10n.text("播放速度"))
                .accessibilityHint(L10n.text("點一下編輯速度"))
            }
            Button { model.adjustPlaybackSpeed(by: 0.1) } label: { Image(systemName: "plus") }
                .buttonStyle(.bordered).frame(minWidth: 44, minHeight: 44)
                .disabled(isReconnecting)
                .accessibilityLabel(L10n.text("提高速度 0.1 公里每小時"))
            Text("km/h").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        if let current = model.activeSimulatedCoordinate {
            HStack {
                Text(L10n.text("目前位置")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { CoordinateClipboard.copy(current) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(L10n.text("複製座標"))
            }
        }

        HStack {
            if isRunning {
                Button(L10n.text("暫停移動")) { playback.pause() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.text("暫停移動"))
            } else if isPaused {
                Button(L10n.text("繼續")) { Task { await playback.resume() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.text("繼續"))
            } else if isReconnecting {
                Text(L10n.text("重新連線中…"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(L10n.text("更多…")) { showMoreActions = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(L10n.text("更多操作"))
        }
    }

    private func beginSpeedEdit() {
        guard playback.state == .running || playback.state == .paused else { return }
        editedSpeed = String(format: "%.1f", playback.speedKmh)
        isEditingSpeed = true
        speedFieldFocused = true
    }

    private func commitSpeedEdit() {
        let normalized = editedSpeed.replacingOccurrences(of: ",", with: ".")
        if let value = Double(normalized), value.isFinite {
            model.setPlaybackSpeed(value)
        } else {
            editedSpeed = String(format: "%.1f", playback.speedKmh)
        }
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
}

private extension CLLocationDistance {
    var formattedCardDistance: String {
        self >= 1000 ? String(format: "%.2f km", self / 1000) : String(format: "%.0f m", self)
    }
}
