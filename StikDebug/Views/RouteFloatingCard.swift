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
        .confirmationDialog(L10n.text("更多操作"), isPresented: $showMoreActions, titleVisibility: .hidden) {
            Button(L10n.text("結束路線"), role: .destructive) {
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

        let loopText = route.isClosedLoop ? L10n.text("循環") : L10n.text("單次")
        Text("\(route.totalDistance.formattedCardDistance) · \(route.preferredSpeedKmh.formatted(.number.precision(.fractionLength(1)))) km/h · \(loopText)")
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
            } else if playback.lapNumber > 1 {
                Text(L10n.format("第 %d 圈", playback.lapNumber))
                    .font(.caption.bold())
            }
        }

        Text("\(playback.traveledDistance.formattedCardDistance) / \(model.geometry.totalDistance.formattedCardDistance) · \(playback.speedKmh.formatted(.number.precision(.fractionLength(1)))) km/h")
            .font(.footnote)
            .foregroundStyle(.secondary)

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
}

private extension CLLocationDistance {
    var formattedCardDistance: String {
        self >= 1000 ? String(format: "%.2f km", self / 1000) : String(format: "%.0f m", self)
    }
}
