//
//  TunnelManager.swift
//  StikDebug
//

import Foundation

final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var isConnected = false
    @Published private(set) var isStarting = false
    @Published private(set) var lastErrorMessage: String?

    private init() {}

    func markDisconnected() {
        runOnMain {
            self.isConnected = false
        }
    }

    func start(showErrorUI: Bool = true) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.start(showErrorUI: showErrorUI)
            }
            return
        }

        let pairingFileURL = PairingFileStore.prepareURL()
        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
            isConnected = false
            return
        }

        guard !isStarting else {
            return
        }

        isStarting = true

        DispatchQueue.global(qos: .userInteractive).async { [showErrorUI] in
            let result: Result<Void, NSError>
            do {
                try JITEnableContext.shared.startTunnel()
                result = .success(())
            } catch {
                result = .failure(error as NSError)
            }

            DispatchQueue.main.async {
                self.finishStart(result, showErrorUI: showErrorUI)
            }
        }
    }

    private func finishStart(_ result: Result<Void, NSError>, showErrorUI: Bool) {
        isStarting = false

        switch result {
        case .success:
            isConnected = true
            lastErrorMessage = nil
            LogManager.shared.addInfoLog("Tunnel connected successfully")
            mountDeveloperDiskImageIfNeeded()
        case .failure(let error):
            isConnected = false
            lastErrorMessage = error.localizedDescription
            handleStartFailure(error, showErrorUI: showErrorUI)
        }
    }

    private func mountDeveloperDiskImageIfNeeded() {
        let trustcachePath = URL.documentsDirectory.appendingPathComponent("DDI/Image.dmg.trustcache").path
        guard FileManager.default.fileExists(atPath: trustcachePath),
              !MountingProgress.shared.coolisMounted,
              MountingProgress.shared.mountingThread == nil else {
            return
        }
        MountingProgress.shared.pubMount()
    }

    private func handleStartFailure(_ error: NSError, showErrorUI: Bool) {
        LogManager.shared.addErrorLog(tunnelConnectionLogMessage(for: error))
        guard showErrorUI else {
            return
        }

        if error.code == -9 {
            handleInvalidPairingFile()
            return
        }

        showAlert(
            title: L10n.text("連線錯誤"),
            message: tunnelConnectionAlertMessage(for: error),
            showOk: false,
            showTryAgain: true
        ) { shouldTryAgain in
            if shouldTryAgain {
                startTunnelInBackground()
            }
        }
    }

    private func handleInvalidPairingFile() {
        LogManager.shared.addInfoLog("Pairing file reported invalid; keeping existing file")

        showAlert(
            title: L10n.text("配對檔案無效"),
            message: L10n.text("配對檔案可能無效或已過期。你可以匯入新的配對檔案來取代它。"),
            showOk: true,
            showTryAgain: false,
            primaryButtonText: L10n.text("選擇新檔案")
        ) { _ in
            NotificationCenter.default.post(name: NSNotification.Name("ShowPairingFilePicker"), object: nil)
        }
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

func startTunnelInBackground(showErrorUI: Bool = true) {
    TunnelManager.shared.start(showErrorUI: showErrorUI)
}

func markTunnelDisconnected() {
    TunnelManager.shared.markDisconnected()
}

private func tunnelConnectionLogMessage(for error: NSError) -> String {
    let target = "\(DeviceConnectionContext.targetIPAddress):49152"
    return "Tunnel connection failed for \(target): \(error.localizedDescription) (Domain: \(error.domain), Code: \(error.code), Raw: \(String(describing: error)))"
}

private func tunnelConnectionAlertMessage(for error: NSError) -> String {
    let targetIP = DeviceConnectionContext.targetIPAddress
    let rawMessage = error.localizedDescription
    let lowercasedMessage = rawMessage.lowercased()

    let likelyCause: String
    let recoverySteps: [String]

    if error.code == 48 || lowercasedMessage.contains("address already in use") || lowercasedMessage.contains("port already in use") {
        likelyCause = L10n.text("裝置通道所需的連接埠已被使用。")
        recoverySteps = [
            L10n.text("關閉可能正在使用通道的其他 JIT、除錯、Proxy 或 VPN App。"),
            L10n.text("中斷後重新連接 LocalDevVPN。"),
            L10n.format("重新啟動 %@，然後再試一次。", ProductIdentity.name),
            L10n.text("如果問題持續發生，請重新啟動裝置以釋放卡住的連接埠。")
        ]
    } else if error.code == 54 || lowercasedMessage.contains("connection reset") {
        likelyCause = L10n.text("裝置或 VPN 在設定完成前關閉了通道連線。")
        recoverySteps = [
            L10n.text("開啟 LocalDevVPN，確認 VPN 已連線。"),
            L10n.format("確認 LocalDevVPN 使用預設位址 %@。", DeviceConnectionContext.defaultTargetIPAddress),
            L10n.text("重新連接 Wi-Fi 與 LocalDevVPN，然後再試一次。"),
            L10n.text("如果問題持續發生，請匯入這台裝置的新配對檔案。")
        ]
    } else if error.code == -18 || lowercasedMessage.contains("parse target ip") {
        likelyCause = L10n.text("設定的目標 IP 位址無效。")
        recoverySteps = [
            L10n.text("開啟設定並檢查目標 IP 位址。"),
            L10n.format("請使用預設位址 %@。", DeviceConnectionContext.defaultTargetIPAddress)
        ]
    } else if lowercasedMessage.contains("timed out") || lowercasedMessage.contains("timeout") {
        likelyCause = L10n.text("連線逾時前無法連接裝置。")
        recoverySteps = [
            L10n.text("確認 Wi-Fi 與 LocalDevVPN 都已連線。"),
            L10n.text("喚醒並解鎖目標裝置。"),
            L10n.format("確認 LocalDevVPN 在 %@ 提供裝置連線。", targetIP)
        ]
    } else if lowercasedMessage.contains("network is unreachable") || lowercasedMessage.contains("no route") {
        likelyCause = L10n.text("目前沒有可連接裝置的 VPN 路徑。")
        recoverySteps = [
            L10n.text("中斷後重新連接 LocalDevVPN。"),
            L10n.text("確認 iOS 顯示 VPN 圖示。"),
            L10n.text("嘗試關閉再開啟 Wi-Fi。")
        ]
    } else {
        likelyCause = L10n.text("無法建立裝置通道。")
        recoverySteps = [
            L10n.text("確認 Wi-Fi 與 LocalDevVPN 都已連線。"),
            L10n.text("喚醒並解鎖目標裝置。"),
            L10n.text("重新連接 LocalDevVPN，然後再試一次。")
        ]
    }

    let steps = recoverySteps.enumerated()
        .map { "\($0.offset + 1). \($0.element)" }
        .joined(separator: "\n")

    return """
    \(likelyCause)

    \(L10n.text("目標"))：\(targetIP):49152
    \(L10n.text("預期的 LocalDevVPN IP"))：\(DeviceConnectionContext.defaultTargetIPAddress)

    \(L10n.text("請依序嘗試"))：
    \(steps)

    \(L10n.text("技術資訊"))：
    \(L10n.text("錯誤碼")) \(error.code)：\(rawMessage)
    """
}
