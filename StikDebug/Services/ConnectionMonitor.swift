import Combine
import Foundation
import Network

enum NetworkInterfaceKind: String {
    case wifi = "Wi-Fi"
    case cellular = "行動網路"
    case wired = "乙太網路"
    case other = "其他"
    case offline = "離線"
}

enum DeviceSessionStatus: Equatable {
    case idle
    case connected
    case reconnecting(attempt: Int)
    case error(String)

    var label: String {
        switch self {
        case .idle: return "閒置"
        case .connected: return "已連線"
        case .reconnecting(let attempt): return "重新連線中（第 \(attempt) 次）"
        case .error(let message): return "錯誤：\(message)"
        }
    }
}

@MainActor
final class ConnectionMonitor: ObservableObject {
    static let shared = ConnectionMonitor()

    @Published private(set) var networkInterface: NetworkInterfaceKind = .offline
    @Published private(set) var internetReachable = false
    @Published private(set) var usesVPNInterface = false
    @Published private(set) var tunnelConnected = false
    @Published private(set) var deviceSession: DeviceSessionStatus = .idle

    private let pathMonitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.routelocation.network-path", qos: .utility)
    private var started = false
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        TunnelManager.shared.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.tunnelConnected = $0 }
            .store(in: &cancellables)
    }

    func start() {
        guard !started else { return }
        started = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.apply(path) }
        }
        pathMonitor.start(queue: queue)
    }

    func reportSession(_ status: DeviceSessionStatus) { deviceSession = status }

    private func apply(_ path: NWPath) {
        internetReachable = path.status == .satisfied
        usesVPNInterface = path.availableInterfaces.contains { $0.type == .other }
        guard path.status == .satisfied else { networkInterface = .offline; return }
        if path.usesInterfaceType(.wifi) { networkInterface = .wifi }
        else if path.usesInterfaceType(.cellular) { networkInterface = .cellular }
        else if path.usesInterfaceType(.wiredEthernet) { networkInterface = .wired }
        else { networkInterface = .other }
        if !TunnelManager.shared.isConnected { startTunnelInBackground(showErrorUI: false) }
    }
}
