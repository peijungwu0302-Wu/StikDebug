//
//  TunnelManager.swift
//  StikDebug
//

import Foundation

enum TunnelConnectionStage: String, Equatable, Sendable {
    case idle, pairing, localDevVPN, targetConfiguration, tunnelStartup, healthCheck, rsdDiscovery, dvt, timeout, connected, error

    var label: String {
        switch self {
        case .idle: return L10n.text("閒置")
        case .pairing: return L10n.text("檢查配對檔案")
        case .localDevVPN: return L10n.text("檢查 LocalDevVPN")
        case .targetConfiguration: return L10n.text("檢查目標位址")
        case .tunnelStartup: return L10n.text("建立裝置通道")
        case .healthCheck: return L10n.text("檢查通道健康狀態")
        case .rsdDiscovery: return L10n.text("連接 RSD 裝置服務")
        case .dvt: return L10n.text("建立 DVT 工作階段")
        case .timeout: return L10n.text("連線逾時")
        case .connected: return L10n.text("已連線")
        case .error: return L10n.text("錯誤")
        }
    }
}

enum TunnelRetryPolicy {
    static let delays: [TimeInterval] = [0.5, 1, 2]

    static func isPermanent(_ error: NSError) -> Bool {
        if [-9, -17, -18].contains(error.code) { return true }
        let message = error.localizedDescription.lowercased()
        return message.contains("parse target ip")
            || message.contains("pairing file not found")
            || message.contains("invalid pairing")
    }

    static func shouldOfferCellularCompatibility(for error: NSError, transport: NetworkTransport) -> Bool {
        guard transport == .cellular, !isPermanent(error) else { return false }
        let message = error.localizedDescription.lowercased()
        return error.code == -19
            || message.contains("timed out")
            || message.contains("timeout")
            || message.contains("network is unreachable")
            || message.contains("no route")
            || message.contains("failed to create tunnel")
    }

    static func failureStage(for error: NSError) -> TunnelConnectionStage {
        if [-9, -17].contains(error.code) { return .pairing }
        if error.code == -18 { return .targetConfiguration }
        let message = error.localizedDescription.lowercased()
        if error.code == -19 || message.contains("timed out") || message.contains("timeout") { return .timeout }
        if message.contains("network is unreachable") || message.contains("no route") || message.contains("connection reset") {
            return .localDevVPN
        }
        return .tunnelStartup
    }
}

enum AuxiliaryProbePolicy {
    static func shouldRetainActiveSession(dvtConnected: Bool, locationActive: Bool, recentLocationSuccess: Bool) -> Bool {
        dvtConnected || locationActive || recentLocationSuccess
    }
}

final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var isConnected = false
    @Published private(set) var isStarting = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var stage: TunnelConnectionStage = .idle
    @Published private(set) var reconnectAttempt = 0
    @Published private(set) var cellularCompatibilitySuggested = false
    @Published private(set) var bootstrapAvailable = true
    @Published private(set) var cellularBootstrapRequested = false

    private let workerQueue = DispatchQueue(label: "com.routelocation.device-tunnel", qos: .userInitiated)
    private var pathChangeWorkItem: DispatchWorkItem?
    private var healthCheckInProgress = false
    private var activeTransport: NetworkTransport = .other

    private init() {}

    func markDisconnected() {
        runOnMain {
            self.isConnected = false
            self.stage = .idle
        }
    }

    func noteNetworkUnavailable() {
        LogManager.shared.addWarningLog("Network path unavailable; preserving tunnel state until an actual device command fails")
    }

    @MainActor func locationDataPathReady() {
        guard cellularBootstrapRequested else { return }
        cellularBootstrapRequested = false
        cellularCompatibilitySuggested = false
        ToastManager.shared.show(L10n.text("定位通道已就緒，現在可以重新開啟行動數據。"), kind: .success, duration: 5)
    }

    func handleNetworkTransition(from previous: NetworkTransport, to current: NetworkTransport) {
        runOnMain {
            self.activeTransport = current
            if self.cellularBootstrapRequested, current != .cellular {
                self.start(showErrorUI: false)
                return
            }
            self.pathChangeWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.performHealthCheckOrConnect(transport: current)
            }
            self.pathChangeWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
            LogManager.shared.addInfoLog("Device tunnel health check scheduled for \(previous.rawValue)->\(current.rawValue)")
        }
    }

    func checkHealthNow(transport: NetworkTransport) {
        runOnMain {
            self.activeTransport = transport
            self.performHealthCheckOrConnect(transport: transport)
        }
    }

    func reportLocationFailure(_ error: Error, transport: NetworkTransport) {
        runOnMain {
            self.lastErrorMessage = error.localizedDescription
            guard let locationError = error as? LocationSimulationError else {
                self.stage = .error
                return
            }
            switch locationError {
            case .pairingFileMissing, .pairingFileInvalid:
                self.stage = .pairing
            case .invalidTargetAddress:
                self.stage = .targetConfiguration
            case .deviceTunnelUnavailable:
                self.stage = .localDevVPN
                self.cellularCompatibilitySuggested = transport == .cellular
            case .rsdDiscoveryFailure:
                self.stage = .rsdDiscovery
                self.cellularCompatibilitySuggested = transport == .cellular
            case .dvtSessionFailure, .updateFailure, .clearFailure:
                self.stage = .dvt
            case .invalidCoordinate:
                self.stage = .error
            }
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
            stage = .pairing
            lastErrorMessage = L10n.text("缺少配對檔案")
            return
        }

        guard !isStarting else {
            return
        }

        isStarting = true
        stage = .tunnelStartup
        reconnectAttempt = 0

        workerQueue.async { [weak self, showErrorUI] in
            guard let self else { return }
            let result = self.connectWithRetry()

            DispatchQueue.main.async {
                self.finishStart(result, showErrorUI: showErrorUI)
            }
        }
    }

    private func connectWithRetry() -> Result<Void, NSError> {
        var lastError: NSError?
        let totalAttempts = TunnelRetryPolicy.delays.count + 1
        for attempt in 1...totalAttempts {
            DispatchQueue.main.async { self.reconnectAttempt = attempt }
            do {
                try JITEnableContext.shared.startTunnel()
                return .success(())
            } catch let error as NSError {
                lastError = error
                if TunnelRetryPolicy.isPermanent(error) || attempt == totalAttempts { break }
                let delay = TunnelRetryPolicy.delays[attempt - 1]
                LogManager.shared.addWarningLog(
                    "Tunnel attempt \(attempt)/\(totalAttempts) failed (code=\(error.code)); retrying in \(delay)s"
                )
                Thread.sleep(forTimeInterval: delay)
            }
        }
        return .failure(lastError ?? NSError(
            domain: "RouteLocation.DeviceTunnel",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: L10n.text("無法建立裝置通道。")]
        ))
    }

    private func performHealthCheckOrConnect(transport: NetworkTransport) {
        guard transport != .offline else { return }
        guard isConnected else {
            start(showErrorUI: false)
            return
        }
        guard !isStarting, !healthCheckInProgress else { return }
        healthCheckInProgress = true
        stage = .healthCheck
        workerQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<Void, NSError>
            do {
                try JITEnableContext.shared.checkTunnelHealth()
                result = .success(())
            } catch let error as NSError {
                result = .failure(error)
            }
            DispatchQueue.main.async { self.finishHealthCheck(result, transport: transport) }
        }
    }

    @MainActor private func finishHealthCheck(_ result: Result<Void, NSError>, transport: NetworkTransport) {
        healthCheckInProgress = false
        switch result {
        case .success:
            LocationDataPathHealth.shared.recordProbe(success: true)
            bootstrapAvailable = true
            stage = .connected
            lastErrorMessage = nil
            LogManager.shared.addInfoLog("Device tunnel health check passed on \(transport.rawValue)")
        case .failure(let error):
            LocationDataPathHealth.shared.recordProbe(success: false, error: error)
            bootstrapAvailable = false
            lastErrorMessage = error.localizedDescription
            cellularCompatibilitySuggested = TunnelRetryPolicy.shouldOfferCellularCompatibility(for: error, transport: transport)
            let activeDataPath = AuxiliaryProbePolicy.shouldRetainActiveSession(
                dvtConnected: ConnectionMonitor.shared.deviceSession == .connected,
                locationActive: LocationDataPathHealth.shared.status == .healthy,
                recentLocationSuccess: LocationDataPathHealth.shared.hasRecentSuccess
            )
            if activeDataPath {
                stage = .connected
                LogManager.shared.addWarningLog("Bootstrap probe unavailable on \(transport.rawValue) (code=\(error.code)); active DVT data path retained")
                return
            }
            isConnected = false
            stage = TunnelRetryPolicy.failureStage(for: error)
            LogManager.shared.addWarningLog("Bootstrap probe failed without a healthy DVT data path; rebuilding")
            start(showErrorUI: false)
        }
    }

    @MainActor private func finishStart(_ result: Result<Void, NSError>, showErrorUI: Bool) {
        isStarting = false

        switch result {
        case .success:
            isConnected = true
            bootstrapAvailable = true
            stage = .connected
            lastErrorMessage = nil
            reconnectAttempt = 0
            cellularCompatibilitySuggested = false
            LogManager.shared.addInfoLog("Tunnel connected successfully")
            mountDeveloperDiskImageIfNeeded()
        case .failure(let error):
            isConnected = false
            stage = TunnelRetryPolicy.failureStage(for: error)
            lastErrorMessage = error.localizedDescription
            cellularCompatibilitySuggested = TunnelRetryPolicy.shouldOfferCellularCompatibility(
                for: error,
                transport: activeTransport
            )
            cellularBootstrapRequested = activeTransport == .cellular && cellularCompatibilitySuggested
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
            L10n.text("重新連接 LocalDevVPN，然後再試一次；Wi-Fi 或行動網路皆可。"),
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
            L10n.text("確認 Wi-Fi 或行動網路可用，並且 LocalDevVPN 已連線。"),
            L10n.text("喚醒並解鎖目標裝置。"),
            L10n.format("確認 LocalDevVPN 在 %@ 提供裝置連線。", targetIP)
        ]
    } else if lowercasedMessage.contains("network is unreachable") || lowercasedMessage.contains("no route") {
        likelyCause = L10n.text("目前沒有可連接裝置的 VPN 路徑。")
        recoverySteps = [
            L10n.text("中斷後重新連接 LocalDevVPN。"),
            L10n.text("確認 iOS 顯示 VPN 圖示。"),
            L10n.text("如果目前只使用行動網路，請嘗試下方的「行動網路相容模式」。")
        ]
    } else {
        likelyCause = L10n.text("無法建立裝置通道。")
        recoverySteps = [
            L10n.text("確認 Wi-Fi 或行動網路可用，並且 LocalDevVPN 已連線。"),
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
