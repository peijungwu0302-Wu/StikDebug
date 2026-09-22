import SwiftUI

struct ActiveSimulationMiniPlayer: View {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var playback: RoutePlaybackEngine
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    if case .singlePoint = model.simulationMode {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(.blue)
                            .font(.caption)
                        Text(L10n.text("模擬位置 · 單點"))
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    } else if model.simulationMode.isRouteSimulation {
                        let isReconnecting = playback.state == .reconnecting
                        let isPlaying = model.simulationMode == .routePlaying
                        if isReconnecting {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text(L10n.format("%@ · %@", playback.routeName, L10n.text("重新連線中…")))
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        } else {
                            Image(systemName: isPlaying ? "play.fill" : "pause.fill")
                                .foregroundStyle(isPlaying ? .green : .orange)
                                .font(.caption)
                            Text(L10n.format("%@ · %.1f km/h", playback.routeName, playback.speedKmh))
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("返回地圖並查看模擬狀態"))

            if model.simulationMode.isRouteSimulation && playback.state != .reconnecting {
                let isPlaying = model.simulationMode == .routePlaying
                Button {
                    if isPlaying {
                        playback.pause()
                    } else {
                        Task { await playback.resume() }
                    }
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .padding(8)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text(isPlaying ? "暫停移動" : "繼續"))
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, (model.simulationMode.isRouteSimulation && playback.state != .reconnecting) ? 8 : 16)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("執行中的模擬控制器"))
    }
}
