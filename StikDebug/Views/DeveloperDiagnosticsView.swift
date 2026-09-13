import SwiftUI
import UIKit

struct DeveloperDiagnosticsView: View {
    @ObservedObject private var store = DeveloperDiagnosticsStore.shared
    @ObservedObject private var coordinator = LocationSessionCoordinator.shared
    @State private var showNewMarkerAlert = false
    @State private var markerText = ""
    @State private var selectedCategory: DiagnosticEventCategory? = nil
    @State private var shareURL: URL? = nil
    @State private var showShareSheet = false
    @State private var showClearConfirm = false
    @State private var showNewRunAlert = false
    @State private var newRunName = ""

    var body: some View {
        List {
            Section("目前測試回合 (Active Test Run)") {
                if let run = store.activeRun {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(run.name).font(.headline)
                            Spacer()
                            Text(L10n.format("%d 個事件", run.eventCount))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("ID: \(run.id)")
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        HStack {
                            Text("版本: \(run.appVersion) (\(run.buildNumber))")
                            Spacer()
                            Text("iOS: \(run.osVersion)")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        if let sid = coordinator.currentSessionId {
                            Text("目前 Session: \(String(sid.prefix(8)))")
                                .font(.caption.monospaced()).foregroundStyle(.green)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Button {
                    markerText = ""
                    showNewMarkerAlert = true
                } label: {
                    Label(L10n.text("新增測試標記 (Add Test Marker)"), systemImage: "bookmark.badge.plus")
                }

                Button {
                    newRunName = ""
                    showNewRunAlert = true
                } label: {
                    Label(L10n.text("建立新測試回合 (New Run)"), systemImage: "plus.circle")
                }
            }

            Section("安裝身分與容器 (Installation Identity)") {
                let identity = store.installationIdentity
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Bundle ID")
                        Spacer()
                        Text(identity.bundleIdentifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("App ID")
                        Spacer()
                        Text(identity.appIdentifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Team ID")
                        Spacer()
                        Text(identity.teamIdentifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("\(identity.version) (\(identity.build))").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("容器識別雜湊")
                        Spacer()
                        Text(identity.containerIdentityHash).font(.caption.monospaced().bold()).foregroundStyle(.blue)
                    }
                    HStack {
                        Text("配對檔狀態")
                        Spacer()
                        Text(identity.pairingFileStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("簽名設定檔")
                        Spacer()
                        Text(identity.provisioningProfileStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    if let exp = identity.signingExpirationDate {
                        HStack {
                            Text("簽名到期")
                            Spacer()
                            Text(exp).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Section("匯出與分享 (Export & Share)") {
                Button {
                    if let url = store.exportSafeReport() {
                        shareURL = url
                        showShareSheet = true
                    }
                } label: {
                    Label(L10n.text("匯出安全去識別化報告 (Safe JSON)"), systemImage: "shield.checkered")
                }

                Button {
                    if let url = store.exportFullLogs() {
                        shareURL = url
                        showShareSheet = true
                    }
                } label: {
                    Label(L10n.text("匯出完整開發者日誌 (Full JSONL)"), systemImage: "doc.text")
                }

                Text("安全報告會自動遮蔽敏感憑證、實際經緯度座標與搜尋關鍵字；完整日誌則供本機除錯。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("事件分類篩選") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button(action: { selectedCategory = nil }) {
                            Text("全部 (\(store.recentEvents.count))")
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(selectedCategory == nil ? Color.blue : Color(.systemGray5))
                                .foregroundColor(selectedCategory == nil ? .white : .primary)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        ForEach(DiagnosticEventCategory.allCases, id: \.self) { cat in
                            Button(action: { selectedCategory = cat }) {
                                Text(cat.displayName)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(selectedCategory == cat ? Color.blue : Color(.systemGray5))
                                    .foregroundColor(selectedCategory == cat ? .white : .primary)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("最近事件 (Recent Events)") {
                let filtered = filteredEvents
                if filtered.isEmpty {
                    Text("目前尚無符合篩選條件的事件記錄。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(filtered) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(event.action)
                                    .font(.subheadline.bold())
                                Spacer()
                                Text(event.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            HStack {
                                Text(event.category.displayName)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.15))
                                    .cornerRadius(4)
                                if let sid = event.sessionId {
                                    Text("sid:\(String(sid.prefix(6)))")
                                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                            if !event.details.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(event.details.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                                        Text("\(k): \(v)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.top, 2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section("管理") {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label(L10n.text("清除所有診斷紀錄"), systemImage: "trash")
                }
            }
        }
        .navigationTitle(L10n.text("開發者診斷"))
        .alert(L10n.text("新增測試標記"), isPresented: $showNewMarkerAlert) {
            TextField("例如：開啟飛航模式、開始繞圈測試...", text: $markerText)
            Button(L10n.text("新增")) {
                store.addUserMarker(note: markerText)
            }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text("輸入此時測試情境備忘，將存入 JSONL 事件流中。")
        }
        .alert(L10n.text("建立新測試回合"), isPresented: $showNewRunAlert) {
            TextField("回合名稱（留空使用時間戳記）", text: $newRunName)
            Button(L10n.text("建立")) {
                store.startNewRun(name: newRunName.isEmpty ? nil : newRunName)
            }
            Button(L10n.text("取消"), role: .cancel) {}
        }
        .alert(L10n.text("確認清除？"), isPresented: $showClearConfirm) {
            Button(L10n.text("全部清除"), role: .destructive) {
                store.clearAllDiagnostics()
            }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text("這將會移除本機所有測試回合與事件 JSONL 檔案。")
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                ShareActivityView(activityItems: [url])
            }
        }
    }

    private var filteredEvents: [DiagnosticEvent] {
        if let cat = selectedCategory {
            return store.recentEvents.filter { $0.category == cat }
        }
        return store.recentEvents
    }
}

private struct ShareActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
