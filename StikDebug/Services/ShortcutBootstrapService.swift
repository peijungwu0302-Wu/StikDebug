import Foundation
import UIKit

enum ShortcutPhase: String, Codable, CaseIterable {
    case dataOff = "data-off"
    case dataOn = "data-on"

    var label: String {
        switch self {
        case .dataOff: return "關閉行動數據 (DataOff)"
        case .dataOn: return "恢復行動數據 (DataOn)"
        }
    }
}

@MainActor
final class ShortcutBootstrapService: ObservableObject {
    static let shared = ShortcutBootstrapService()

    @Published var isShortcutAssistedEnabled: Bool {
        didSet { UserDefaults.standard.set(isShortcutAssistedEnabled, forKey: Self.enabledKey) }
    }
    @Published var cellularBootstrapPolicy: CellularBootstrapPolicy {
        didSet { UserDefaults.standard.set(cellularBootstrapPolicy.rawValue, forKey: Self.policyKey) }
    }
    @Published var shortcutPromptMode: ShortcutExecutionPrompt {
        didSet { UserDefaults.standard.set(shortcutPromptMode.rawValue, forKey: Self.promptKey) }
    }
    @Published var shortcutDataOffName: String {
        didSet { UserDefaults.standard.set(shortcutDataOffName, forKey: Self.dataOffNameKey) }
    }
    @Published var shortcutDataOnName: String {
        didSet { UserDefaults.standard.set(shortcutDataOnName, forKey: Self.dataOnNameKey) }
    }

    /// Backwards-compatibility alias for single shortcut name
    var shortcutName: String {
        get { shortcutDataOffName }
        set { shortcutDataOffName = newValue }
    }

    @Published private(set) var activeTransaction: BootstrapTransaction?
    @Published private(set) var activePhase: ShortcutPhase?
    @Published private(set) var lastTransactionStatus: String?

    private var pendingCompletion: ((Bool) -> Void)?
    private var timeoutTimer: Task<Void, Never>?

    private static let enabledKey = "RouteLocation.isShortcutAssistedEnabled"
    private static let policyKey = "RouteLocation.cellularBootstrapPolicy"
    private static let promptKey = "RouteLocation.shortcutPromptMode"
    private static let dataOffNameKey = "RouteLocation.shortcutDataOffName"
    private static let dataOnNameKey = "RouteLocation.shortcutDataOnName"
    private static let legacyNameKey = "RouteLocation.shortcutName"

    private init() {
        self.isShortcutAssistedEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if let policyRaw = UserDefaults.standard.string(forKey: Self.policyKey),
           let policy = CellularBootstrapPolicy(rawValue: policyRaw) {
            self.cellularBootstrapPolicy = policy
        } else {
            self.cellularBootstrapPolicy = .auto
        }

        if let promptRaw = UserDefaults.standard.string(forKey: Self.promptKey),
           let prompt = ShortcutExecutionPrompt(rawValue: promptRaw) {
            self.shortcutPromptMode = prompt
        } else {
            self.shortcutPromptMode = .alwaysAsk
        }

        let savedDataOff = UserDefaults.standard.string(forKey: Self.dataOffNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyName = UserDefaults.standard.string(forKey: Self.legacyNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let savedDataOff, !savedDataOff.isEmpty {
            self.shortcutDataOffName = savedDataOff
        } else if let legacyName, !legacyName.isEmpty {
            self.shortcutDataOffName = legacyName
        } else {
            self.shortcutDataOffName = "RouteLocationDataOff"
        }

        let savedDataOn = UserDefaults.standard.string(forKey: Self.dataOnNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.shortcutDataOnName = (savedDataOn != nil && !savedDataOn!.isEmpty) ? savedDataOn! : "RouteLocationDataOn"
    }

    func runDataOffShortcut(txId: String, completion: @escaping (Bool) -> Void) -> Bool {
        return runShortcut(name: shortcutDataOffName, phase: .dataOff, txId: txId, completion: completion)
    }

    func runDataOnShortcut(txId: String, completion: @escaping (Bool) -> Void) -> Bool {
        return runShortcut(name: shortcutDataOnName, phase: .dataOn, txId: txId, completion: completion)
    }

    /// Legacy single-phase starter (delegates to DataOff)
    func startShortcutBootstrapTransaction(completion: @escaping (Bool) -> Void) -> Bool {
        let txId = UUID().uuidString
        return runDataOffShortcut(txId: txId, completion: completion)
    }

    private func runShortcut(name: String, phase: ShortcutPhase, txId: String, completion: @escaping (Bool) -> Void) -> Bool {
        let transaction = BootstrapTransaction(
            id: txId,
            createdAt: Date(),
            completedAt: nil,
            status: "pending"
        )
        activeTransaction = transaction
        activePhase = phase
        pendingCompletion = completion

        DeveloperDiagnosticsStore.shared.record(
            category: .bootstrap,
            action: "SHORTCUT_INVOCATION_STARTED",
            details: ["txId": txId, "phase": phase.rawValue, "shortcutName": name]
        )

        timeoutTimer?.cancel()
        timeoutTimer = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
            } catch { return }
            guard let self else { return }
            await MainActor.run {
                if self.activeTransaction?.id == txId && self.activeTransaction?.status == "pending" {
                    self.activeTransaction?.status = "timed_out"
                    self.lastTransactionStatus = L10n.format("捷徑 %@ 執行逾時（15 秒）", name)
                    DeveloperDiagnosticsStore.shared.record(
                        category: .bootstrap,
                        action: "SHORTCUT_TIMEOUT",
                        details: ["txId": txId, "phase": phase.rawValue]
                    )
                    let comp = self.pendingCompletion
                    self.pendingCompletion = nil
                    comp?(false)
                }
            }
        }

        guard let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "shortcuts://run-shortcut?name=\(encodedName)&input=text&text=\(txId)") else {
            cancelActiveTransaction()
            completion(false)
            return false
        }

        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url) { success in
                if !success {
                    Task { @MainActor [weak self] in
                        self?.cancelActiveTransaction()
                        completion(false)
                    }
                }
            }
            return true
        } else {
            cancelActiveTransaction()
            completion(false)
            return false
        }
    }

    func handleCallback(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "routelocation",
              url.host?.lowercased() == "bootstrap-callback" else {
            return false
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let txId = components?.queryItems?.first(where: { $0.name == "tx" })?.value
        let phaseStr = components?.queryItems?.first(where: { $0.name == "phase" })?.value
        let status = components?.queryItems?.first(where: { $0.name == "status" })?.value ?? "success"

        DeveloperDiagnosticsStore.shared.record(
            category: .bootstrap,
            action: "SHORTCUT_CALLBACK_RECEIVED",
            details: ["txId": txId ?? "none", "phase": phaseStr ?? "none", "status": status]
        )

        guard let activeTx = activeTransaction, activeTx.id == txId else {
            DeveloperDiagnosticsStore.shared.record(
                category: .bootstrap,
                action: "SHORTCUT_CALLBACK_MISMATCH",
                details: ["receivedTx": txId ?? "none", "activeTx": activeTransaction?.id ?? "none"]
            )
            return false
        }

        // Validate phase if provided
        if let phaseStr, let expectedPhase = activePhase, phaseStr != expectedPhase.rawValue {
            DeveloperDiagnosticsStore.shared.record(
                category: .bootstrap,
                action: "SHORTCUT_PHASE_MISMATCH",
                details: ["receivedPhase": phaseStr, "expectedPhase": expectedPhase.rawValue]
            )
            return false
        }

        timeoutTimer?.cancel()
        timeoutTimer = nil

        let success = status.lowercased() == "success"
        activeTransaction?.completedAt = Date()
        activeTransaction?.status = success ? "completed" : "failed"
        let phaseLabel = activePhase?.label ?? "捷徑"
        lastTransactionStatus = success ? L10n.format("%@ 回呼成功", phaseLabel) : L10n.format("%@ 回報失敗", phaseLabel)

        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(success)

        return true
    }

    func cancelActiveTransaction() {
        timeoutTimer?.cancel()
        timeoutTimer = nil
        if let txId = activeTransaction?.id {
            DeveloperDiagnosticsStore.shared.record(
                category: .bootstrap,
                action: "SHORTCUT_TRANSACTION_CANCELLED",
                details: ["txId": txId]
            )
        }
        activeTransaction?.status = "cancelled"
        let comp = pendingCompletion
        pendingCompletion = nil
        comp?(false)
    }

    // MARK: - Testing Triggers

    func runSafeRoundTripTest(completion: @escaping (Bool, String) -> Void) {
        let testTx = "rt-\(UUID().uuidString.prefix(6))"
        lastTransactionStatus = "正在發起安全雙向測試 (DataOff -> DataOn)..."

        let openedOff = runDataOffShortcut(txId: testTx) { [weak self] offSuccess in
            guard let self else { return }
            guard offSuccess else {
                _ = self.runDataOnShortcut(txId: testTx) { _ in }
                completion(false, "DataOff 捷徑回呼失敗或逾時，已嘗試自動恢復行動數據")
                return
            }

            Task {
                let deadline = Date().addingTimeInterval(3.0)
                while Date() < deadline {
                    if !ConnectionMonitor.shared.isCellularAvailable { break }
                    try? await Task.sleep(for: .milliseconds(300))
                }

                await MainActor.run {
                    self.lastTransactionStatus = "DataOff 成功，正在立即發起 DataOn 恢復..."
                    let openedOn = self.runDataOnShortcut(txId: testTx) { [weak self] onSuccess in
                        guard let self else { return }
                        if onSuccess {
                            self.lastTransactionStatus = "安全雙向測試完成：已確認關閉並已成功恢復行動數據"
                            completion(true, "安全測試成功：已確認關閉並已成功恢復行動數據")
                        } else {
                            self.lastTransactionStatus = "⚠️ DataOn 回呼未確認，請檢查控制中心"
                            completion(false, "DataOn 回呼未確認，請手動檢查行動數據")
                        }
                    }
                    if !openedOn {
                        completion(false, "無法開啟 DataOn 捷徑 URL，請至控制中心手動開啟行動數據")
                    }
                }
            }
        }

        if !openedOff {
            completion(false, "無法開啟 DataOff 捷徑 URL")
        }
    }

    func testDataOffShortcut() {
        let testTx = "test-off-\(UUID().uuidString.prefix(6))"
        lastTransactionStatus = "發起 DataOff 測試..."
        _ = runDataOffShortcut(txId: testTx) { success in
            ToastManager.shared.show(success ? "DataOff 捷徑測試成功" : "DataOff 捷徑測試失敗或逾時", kind: success ? .success : .error)
        }
    }

    func testDataOnShortcut() {
        let testTx = "test-on-\(UUID().uuidString.prefix(6))"
        lastTransactionStatus = "發起 DataOn 測試..."
        _ = runDataOnShortcut(txId: testTx) { success in
            ToastManager.shared.show(success ? "DataOn 捷徑測試成功" : "DataOn 捷徑測試失敗或逾時", kind: success ? .success : .error)
        }
    }

    static let shortcutSetupGuide: String = """
    【Apple 捷徑二階段自動切換設定教學】
    在純行動網路環境下，透過兩組獨立捷徑完成無縫通道初始化：

    一、捷徑 1：關閉行動數據（命名：「RouteLocationDataOff」）
    1. 打開 iOS「捷徑」App，按「+」建立新捷徑。
    2. 新增以下動作：
       (1) 「設定行動數據」-> 設為「關閉」
       (2) 「打開 URL」-> 填入以下網址：
           routelocation://bootstrap-callback?tx=[捷徑輸入]&phase=data-off&status=success
    3. 儲存捷徑。

    二、捷徑 2：恢復行動數據（命名：「RouteLocationDataOn」）
    1. 建立另一新捷徑，命名為「RouteLocationDataOn」。
    2. 新增以下動作：
       (1) 「設定行動數據」-> 設為「開啟」
       (2) 「打開 URL」-> 填入以下網址：
           routelocation://bootstrap-callback?tx=[捷徑輸入]&phase=data-on&status=success
    3. 儲存捷徑。

    ※ 系統在完成通道建立並驗證首次定位寫入後，會自動觸發 RouteLocationDataOn 恢復行動數據。若中途失敗亦具備自動 Rollback 機制。
    """
}
