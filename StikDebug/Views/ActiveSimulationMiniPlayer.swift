import SwiftUI

struct ActiveSimulationMiniPlayer: View {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var playback: RoutePlaybackEngine
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if case .singlePoint = model.simulationMode {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    Text(L10n.text("模擬位置 · 單點"))
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                } else if model.simulationMode == .routePlaying || model.simulationMode == .routePaused {
                    let isPlaying = model.simulationMode == .routePlaying
                    Image(systemName: isPlaying ? "play.fill" : "pause.fill")
                        .foregroundStyle(isPlaying ? .green : .orange)
                        .font(.caption)

                    Text(L10n.format("%@ · %.1f km/h", playback.routeName, playback.speedKmh))
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()

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
                            .padding(6)
                    }
                    .accessibilityLabel(L10n.text(isPlaying ? "暫停移動" : "繼續"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("執行中的模擬控制器"))
    }
}
