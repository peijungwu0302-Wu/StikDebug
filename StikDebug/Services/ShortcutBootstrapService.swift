import Foundation
import UIKit

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
    @Published var shortcutName: String {
        didSet { UserDefaults.standard.set(shortcutName, forKey: Self.nameKey) }
    }

    @Published private(set) var activeTransaction: BootstrapTransaction?
    @Published private(set) var lastTransactionStatus: String?

    private var pendingCompletion: ((Bool) -> Void)?
    private var timeoutTimer: Task<Void, Never>?

    private static let enabledKey = "RouteLocation.isShortcutAssistedEnabled"
    private static let policyKey = "RouteLocation.cellularBootstrapPolicy"
    private static let promptKey = "RouteLocation.shortcutPromptMode"
    private static let nameKey = "RouteLocation.shortcutName"

    private init() {
        self.isShortcutAssistedEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey) // default false
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

        let savedName = UserDefaults.standard.string(forKey: Self.nameKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.shortcutName = (savedName != nil && !savedName!.isEmpty) ? savedName! : "RouteLocationBootstrap"
    }

    func startShortcutBootstrapTransaction(completion: @escaping (Bool) -> Void) -> Bool {
        guard isShortcutAssistedEnabled else {
            completion(false)
            return false
        }

        let txId = UUID().uuidString
        let transaction = BootstrapTransaction(
            id: txId,
            createdAt: Date(),
            completedAt: nil,
            status: "pending"
        )
        activeTransaction = transaction
        pendingCompletion = completion

        DeveloperDiagnosticsStore.shared.record(
            category: .bootstrap,
            action: "SHORTCUT_TRANSACTION_STARTED",
            details: ["txId": txId, "shortcutName": shortcutName]
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
                    self.lastTransactionStatus = L10n.text("捷徑執行逾時（15 秒）")
                    DeveloperDiagnosticsStore.shared.record(
                        category: .bootstrap,
                        action: "SHORTCUT_TRANSACTION_TIMEOUT",
                        details: ["txId": txId]
                    )
                    self.pendingCompletion?(false)
                    self.pendingCompletion = nil
                }
            }
        }

        guard let encodedName = shortcutName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
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
        let status = components?.queryItems?.first(where: { $0.name == "status" })?.value ?? "success"

        DeveloperDiagnosticsStore.shared.record(
            category: .bootstrap,
            action: "SHORTCUT_CALLBACK_RECEIVED",
            details: ["txId": txId ?? "none", "status": status]
        )

        guard let activeTx = activeTransaction, activeTx.id == txId else {
            DeveloperDiagnosticsStore.shared.record(
                category: .bootstrap,
                action: "SHORTCUT_CALLBACK_MISMATCH",
                details: ["receivedTx": txId ?? "none", "activeTx": activeTransaction?.id ?? "none"]
            )
            return false
        }

        timeoutTimer?.cancel()
        timeoutTimer = nil

        let success = status.lowercased() == "success"
        activeTransaction?.completedAt = Date()
        activeTransaction?.status = success ? "completed" : "failed"
        lastTransactionStatus = success ? L10n.text("捷徑回呼成功") : L10n.text("捷徑回報失敗")

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
        pendingCompletion?(false)
        pendingCompletion = nil
    }

    static let shortcutSetupGuide: String = """
    【Apple 捷徑自動切換設定教學】
    1. 打開 iOS 內建「捷徑」App，按「+」建立新捷徑，命名為「RouteLocationBootstrap」。
    2. 新增以下 3 個動作：
       (1) 「設定行動數據」-> 設為「關閉」
       (2) 「等待」-> 設為「2 秒」
       (3) 「打開 URL」-> 填入以下網址：
           routelocation://bootstrap-callback?tx=[捷徑輸入]&status=success
    3. 完成儲存。執行時將自動關閉行動網路並立即回呼 RouteLocation 完成通道建立。
    ※ 捷徑為完全選用功能，若關閉此設定或不建立捷徑，隨時可使用手動流程。
    """
}
