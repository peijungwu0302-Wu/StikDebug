//
//  SelfRefreshCoordinator.swift
//  StikDebug
//

import Combine
import Foundation
import SwiftUI
import UIKit

enum SelfRefreshState: Equatable, Sendable {
    case idle
    case preflight
    case authenticationRequired
    case authenticating
    case preparingProfile
    case preparingPayload
    case signing
    case staging
    case installing
    case waitingForReplacement
    case verificationPending
    case success(message: String)
    case failed(reason: String)

    var isBusy: Bool {
        switch self {
        case .idle, .success, .failed, .authenticationRequired:
            return false
        default:
            return true
        }
    }

    var statusText: String {
        switch self {
        case .idle:
            return L10n.text("閒置")
        case .preflight:
            return L10n.text("正在檢查環境…")
        case .authenticationRequired:
            return L10n.text("需要簽名認證設定")
        case .authenticating:
            return L10n.text("正在驗證 Apple 開發者帳號…")
        case .preparingProfile:
            return L10n.text("正在準備描述檔…")
        case .preparingPayload:
            return L10n.text("正在準備應用程式內容…")
        case .signing:
            return L10n.text("正在重新簽名 RouteLocation…")
        case .staging:
            return L10n.text("正在準備安裝…")
        case .installing:
            return L10n.text("正在重新安裝…")
        case .waitingForReplacement:
            return L10n.text("等待 App 覆蓋重啟…")
        case .verificationPending:
            return L10n.text("等待下次啟動確認…")
        case .success(let msg):
            return msg
        case .failed(let reason):
            return L10n.format("失敗：%@", reason)
        }
    }
}

struct SelfRefreshPendingVerification: Codable, Equatable, Sendable {
    let operationId: String
    let beforeExpiration: Date
    let expectedVersion: String
    let requestedAt: Date
}

@MainActor
final class SelfRefreshCoordinator: ObservableObject {
    static let shared = SelfRefreshCoordinator()

    @Published private(set) var state: SelfRefreshState = .idle
    @Published var showSimulationStopPrompt = false
    @Published var showCellularBlockedAlert = false
    @Published var showMissingVPNAlert = false
    @Published var showActionableErrorAlert = false
    @Published var lastErrorMessage: String?

    private static let pendingVerificationKey = "RouteLocation.selfRefreshPendingVerification"

    private init() {
        checkPendingVerificationOnLaunch()
    }

    func startSelfRefresh(model: RouteLocationModel) {
        DeveloperDiagnosticsStore.shared.record(
            category: .lifecycle,
            action: "self_refresh_requested",
            details: [
                "transport": model.connectionMonitor.currentTransport.rawValue,
                "isSimulating": "\(model.simulationMode.isSimulating)"
            ]
        )

        // Preflight Check 1: Transport
        let transport = model.connectionMonitor.currentTransport
        if transport != .wifi {
            // Cellular-only or non-Wi-Fi refresh is NOT supported
            DeveloperDiagnosticsStore.shared.record(
                category: .decision,
                action: "self_refresh_preflight_result",
                details: ["decision": "BLOCKED_CELLULAR_ONLY"]
            )
            state = .failed(reason: L10n.text("目前需要 Wi-Fi。行動網路單獨重新整理尚未支援。"))
            showCellularBlockedAlert = true
            return
        }

        // Preflight Check 2: LocalDevVPN
        guard model.connectionMonitor.usesVPNInterface || LocationDataPathHealth.shared.hasRecentSuccess else {
            DeveloperDiagnosticsStore.shared.record(
                category: .decision,
                action: "self_refresh_preflight_result",
                details: ["decision": "MISSING_LOCALDEVVPN"]
            )
            state = .failed(reason: L10n.text("請先啟動 LocalDevVPN。"))
            showMissingVPNAlert = true
            return
        }

        // Preflight Check 3: Active Simulation Protection
        if model.simulationMode.isSimulating {
            showSimulationStopPrompt = true
            return
        }

        proceedWithPreflight(model: model)
    }

    func confirmStopSimulationAndContinue(model: RouteLocationModel) {
        showSimulationStopPrompt = false
        state = .preflight
        Task {
            await model.returnToRealLocation()
            if model.simulationMode != .idle {
                // Restore Real Location failed!
                let errorDesc = model.presentedError ?? "Restore Real Location Failed"
                DeveloperDiagnosticsStore.shared.record(
                    category: .error,
                    action: "self_refresh_restore_failed_abort",
                    details: ["error": errorDesc]
                )
                self.state = .failed(reason: L10n.format("無法恢復真實位置，已取消重新整理：%@。", errorDesc))
                self.lastErrorMessage = errorDesc
                self.showActionableErrorAlert = true
                return
            }

            self.proceedWithPreflight(model: model)
        }
    }

    private func proceedWithPreflight(model: RouteLocationModel) {
        state = .preflight
        DeveloperDiagnosticsStore.shared.record(
            category: .lifecycle,
            action: "self_refresh_preflight_begin",
            details: [:]
        )

        // Check Pairing File
        guard FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path) else {
            state = .failed(reason: L10n.text("缺少配對檔案，請先匯入配對檔案。"))
            lastErrorMessage = state.statusText
            showActionableErrorAlert = true
            return
        }

        DeveloperDiagnosticsStore.shared.record(
            category: .lifecycle,
            action: "self_refresh_preflight_result",
            details: ["result": "PASSED"]
        )

        // Because SideStore and RouteLocation reside in separate app sandboxes without shared keychain,
        // RouteLocation requires its own signing setup or local signing service.
        state = .authenticationRequired
        DeveloperDiagnosticsStore.shared.record(
            category: .lifecycle,
            action: "self_refresh_auth_begin",
            details: ["status": "AUTHENTICATION_SETUP_REQUIRED"]
        )
    }

    public func openSideStoreRefresh() {
        if let url = URL(string: "sidestore://") {
            UIApplication.shared.open(url) { success in
                if !success {
                    ToastManager.shared.show(L10n.text("無法開啟 SideStore，請手動打開 SideStore App 進行刷新。"), kind: .info)
                }
            }
        }
    }

    public func persistPendingVerification(currentExpiration: Date) {
        let expectedVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.8"
        let pending = SelfRefreshPendingVerification(
            operationId: UUID().uuidString,
            beforeExpiration: currentExpiration,
            expectedVersion: expectedVersion,
            requestedAt: .now
        )
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: Self.pendingVerificationKey)
        }
        DeveloperDiagnosticsStore.shared.record(
            category: .lifecycle,
            action: "self_refresh_pending_verification",
            details: ["operationId": pending.operationId]
        )
    }

    public func checkPendingVerificationOnLaunch() {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingVerificationKey),
              let pending = try? JSONDecoder().decode(SelfRefreshPendingVerification.self, from: data) else {
            return
        }

        DeveloperDiagnosticsStore.shared.record(
            category: .lifecycle,
            action: "self_refresh_next_launch_verification",
            details: ["operationId": pending.operationId]
        )

        SigningStatusService.shared.refreshSigningStatus()
        guard let currentInfo = SigningStatusService.shared.profileInfo else {
            state = .failed(reason: L10n.text("重新整理未確認成功：無法讀取新簽名。"))
            UserDefaults.standard.removeObject(forKey: Self.pendingVerificationKey)
            return
        }

        if currentInfo.expirationDate > pending.beforeExpiration {
            let msg = L10n.format("✓ RouteLocation 已成功重新整理！新期限：%@。", SigningStatusService.shared.remainingFormatted)
            state = .success(message: msg)
            DeveloperDiagnosticsStore.shared.record(
                category: .lifecycle,
                action: "self_refresh_verified",
                details: [
                    "operationId": pending.operationId,
                    "newExpiration": ISO8601DateFormatter().string(from: currentInfo.expirationDate)
                ]
            )
            ToastManager.shared.show(msg, kind: .success)
        } else {
            let msg = L10n.text("重新整理未確認成功：目前的簽名期限沒有更新。")
            state = .failed(reason: msg)
            DeveloperDiagnosticsStore.shared.record(
                category: .error,
                action: "self_refresh_failed",
                details: [
                    "operationId": pending.operationId,
                    "reason": "EXPIRATION_NOT_EXTENDED"
                ]
            )
        }

        UserDefaults.standard.removeObject(forKey: Self.pendingVerificationKey)
    }

    public func resetState() {
        state = .idle
        lastErrorMessage = nil
    }
}
