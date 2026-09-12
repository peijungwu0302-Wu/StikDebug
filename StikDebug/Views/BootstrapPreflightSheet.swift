import SwiftUI

struct BootstrapPreflightSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onRecheck: () -> Void
    let onForceConnect: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 50))
                    .foregroundStyle(.orange)
                    .padding(.top, 24)

                Text(L10n.text("定位通道初始化"))
                    .font(.title2.bold())

                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("目前正在使用行動網路。"))
                        .font(.body)

                    Text(L10n.text("為了提高首次建立定位通道的成功率，\n請暫時關閉「行動數據」，\n或暫時開啟「飛航模式」。"))
                        .font(.body)

                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.blue)
                        Text(L10n.text("請保持 LocalDevVPN 已連線。"))
                            .font(.subheadline.bold())
                            .foregroundStyle(.blue)
                    }

                    Text(L10n.text("定位通道建立完成後，\n即可重新開啟行動數據／關閉飛航模式。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)

                Spacer()

                VStack(spacing: 12) {
                    if ShortcutBootstrapService.shared.isShortcutAssistedEnabled {
                        Button {
                            _ = ShortcutBootstrapService.shared.startShortcutBootstrapTransaction { success in
                                if success {
                                    dismiss()
                                    onRecheck()
                                }
                            }
                        } label: {
                            Label(L10n.text("啟動捷徑自動切換 (Shortcut)"), systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
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

                    Button {
                        dismiss()
                        onForceConnect()
                    } label: {
                        Text(L10n.text("仍要嘗試直接連線"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button(L10n.text("取消"), role: .cancel) {
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
                        dismiss()
                        onCancel()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
