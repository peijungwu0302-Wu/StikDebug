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
                    #if DEBUG && targetEnvironment(simulator)
                    if GuideScreenshotFixture.scenario != nil { return }
                    #endif
                    CellularAssistedBootstrapStateMachine.shared.beginForegroundRecoveryCycle()
                    CellularAssistedBootstrapStateMachine.shared.handleStaleRecoveryIfNeeded()
                    OptionalDDIPreparationCoordinator.shared.ensureReadinessBestEffort()
                    LocationSessionCoordinator.shared.prewarmIfAppropriate()
                }
                .onOpenURL { url in
                    _ = ShortcutBootstrapService.shared.handleCallback(url: url)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    handleScenePhaseChange(newPhase)
                }
        }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        #if DEBUG && targetEnvironment(simulator)
        if GuideScreenshotFixture.scenario != nil { return }
        #endif
        switch newPhase {
        case .active:
            CellularAssistedBootstrapStateMachine.shared.beginForegroundRecoveryCycle()
            CellularAssistedBootstrapStateMachine.shared.handleStaleRecoveryIfNeeded()
            LocationSessionCoordinator.shared.prewarmIfAppropriate()
        case .background:
            Task { await HealthStepSyncService.shared.flush() }
        default:
            break
        }
    }

}
