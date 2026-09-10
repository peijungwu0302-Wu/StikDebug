import Foundation

@MainActor
final class BackgroundKeepAliveService {
    static let shared = BackgroundKeepAliveService()
    private var lease: DebugKeepAliveLease?

    private init() {}

    func acquire() {
        guard lease == nil else { return }
        lease = DebugKeepAliveLease()
    }

    func release() {
        lease?.invalidate()
        lease = nil
    }
}
