import Combine
import Foundation

enum ToastKind: Equatable { case info, success, error, persistent }

struct ToastMessage: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let kind: ToastKind
}

@MainActor
final class ToastManager: ObservableObject {
    static let shared = ToastManager()
    @Published private(set) var current: ToastMessage?
    private var dismissTask: Task<Void, Never>?

    func show(_ text: String, kind: ToastKind = .info, duration: TimeInterval? = nil) {
        dismissTask?.cancel()
        current = ToastMessage(text: text, kind: kind)
        guard kind != .persistent else { return }
        let delay = duration ?? (kind == .error ? 4.5 : 2.5)
        let id = current?.id
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.current?.id == id else { return }
            self.current = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }
}
