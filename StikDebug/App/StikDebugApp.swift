//
//  StikDebugApp.swift
//  StikDebug
//
//  Created by Stephen on 3/26/25.
//

import SwiftUI

@main
struct RouteLocationApp: App {
    @Environment(\.scenePhase) private var scenePhase
    init() {
        AppBootstrapper.configure()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .task {
                    await downloadMissingDeveloperDiskImageFiles()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    handleScenePhaseChange(newPhase)
                }
        }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            Task { await HealthStepSyncService.shared.flush() }
        default:
            break
        }
    }

    private func downloadMissingDeveloperDiskImageFiles() async {
        do {
            try await DeveloperDiskImageService.shared.downloadMissingFiles()
            MountingProgress.shared.pubMount()
        } catch {
            await MainActor.run {
                showAlert(
                    title: L10n.text("發生錯誤"),
                    message: L10n.format("下載開發者磁碟映像失敗：%@", error.localizedDescription),
                    showOk: true
                )
            }
        }
    }
}
