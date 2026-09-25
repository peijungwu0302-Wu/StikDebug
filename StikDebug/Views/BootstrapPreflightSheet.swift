import SwiftUI

struct BootstrapPreflightSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var stateMachine = CellularAssistedBootstrapStateMachine.shared
    @ObservedObject private var shortcutService = ShortcutBootstrapService.shared

    let onStartAssisted: () -> Void
    let onRecheck: () -> Void
    let onForceConnect: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 46))
                    .foregroundStyle(.orange)
                    .padding(.top, 20)

                Text(L10n.text("定位通道初始化"))
                    .font(.title2.bold())

                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("目前正在使用行動網路。"))
                        .font(.body)

                    Text(L10n.text("為了提高首次建立定位通道的成功率，\n建議暫時關閉「行動數據」，或暫時開啟「飛航模式」。"))
                        .font(.body)

                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.blue)
                        Text(L10n.text("請保持 LocalDevVPN 已連線。"))
                            .font(.subheadline.bold())
                            .foregroundStyle(.blue)
                    }

                    Text(L10n.text("定位通道建立並驗證定位後，即可重新開啟行動數據。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)

                if stateMachine.state.isRunning {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(stateMachine.state.label)
                            .font(.subheadline.bold())
                            .foregroundStyle(.indigo)
                    }
                    .padding(.vertical, 4)
                }

                if stateMachine.requiresManualDataOnAlert {
                    Text(L10n.text("⚠️ 無法自動恢復行動數據，請至控制中心手動重新開啟。"))
                        .font(.footnote.bold())
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                VStack(spacing: 12) {
                    if shortcutService.isShortcutAssistedEnabled {
                        Button {
                            onStartAssisted()
                        } label: {
                            Label(L10n.text("啟動捷徑輔助切換 (Beta)"), systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                        .disabled(stateMachine.state.isRunning)
                    }

                    Button {
                        dismiss()
                        onRecheck()
                    } label: {
                        Text(L10n.text("我已手動切換，重新檢查"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(stateMachine.state.isRunning)

                    Button {
                        dismiss()
                        onForceConnect()
                    } label: {
                        Text(L10n.text("仍要嘗試直接連線 (實驗性)"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(stateMachine.state.isRunning)

                    Button(L10n.text("取消"), role: .cancel) {
                        stateMachine.cancel()
                        dismiss()
                        onCancel()
                    }
                    .font(.footnote)
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("取消")) {
                        stateMachine.cancel()
                        dismiss()
                        onCancel()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
