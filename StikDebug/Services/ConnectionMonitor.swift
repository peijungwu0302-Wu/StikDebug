import Combine
import Foundation
import Network

enum NetworkTransport: String, Equatable, Sendable {
    case wifi, cellular, other, offline

    var label: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .cellular: return L10n.text("行動網路")
        case .other: return L10n.text("其他")
        case .offline: return L10n.text("離線")
        }
    }

    static func classify(
        isSatisfied: Bool,
        usesWiFi: Bool,
        usesCellular: Bool,
        wifiAvailable: Bool = false,
        cellularAvailable: Bool = false,
        isExpensive: Bool = false
    ) -> NetworkTransport {
        guard isSatisfied else { return .offline }
        if usesWiFi { return .wifi }
        if usesCellular { return .cellular }
        // A split/local VPN can become the path's `.other` interface and hide
        // its bearer. Under that condition, availability plus cost identifies
        // cellular-only startup without treating Wi-Fi as a prerequisite.
        if cellularAvailable, isExpensive || !wifiAvailable { return .cellular }
        if wifiAvailable { return .wifi }
        return .other
    }
}

enum NetworkTransitionPolicy {
    static func needsDeviceHealthCheck(previous: NetworkTransport, current: NetworkTransport) -> Bool {
        current != .offline && previous != current
    }
}

enum DeviceSessionStatus: Equatable {
    case idle
    case connected
    case reconnecting(attempt: Int)
    case error(String)

    var label: String {
        switch self {
        case .idle: return L10n.text("未連線")
        case .connected: return L10n.text("已連線")
        case .reconnecting(let attempt): return L10n.format("重新連線中（第 %d 次）", attempt)
        case .error(let message): return L10n.format("錯誤：%@", message)
        }
    }
}

@MainActor
final class ConnectionMonitor: ObservableObject {
    static let shared = ConnectionMonitor()

    @Published private(set) var previousTransport: NetworkTransport = .offline
    @Published private(set) var currentTransport: NetworkTransport = .offline
    @Published private(set) var internetReachable = false
    @Published private(set) var usesVPNInterface = false
    @Published private(set) var pathIsExpensive = false
    @Published private(set) var tunnelConnected = false
    @Published private(set) var deviceSession: DeviceSessionStatus = .idle
    @Published private(set) var transportRevision: UInt = 0

    var networkInterface: NetworkTransport { currentTransport }

    var localDevVPNAvailable: Bool {
        usesVPNInterface || tunnelConnected
    }

    var activeDVTSessionAvailable: Bool {
        deviceSession == .connected || LocationDataPathHealth.shared.hasRecentSuccess
    }

    var locationDataPathHealthy: Bool {
        LocationDataPathHealth.shared.status == .healthy || LocationDataPathHealth.shared.hasRecentSuccess
    }

    var newBootstrapAvailable: Bool {
        TunnelManager.shared.bootstrapAvailable
    }

    var effectiveTunnelHealthy: Bool {
        activeDVTSessionAvailable || locationDataPathHealthy || localDevVPNAvailable
    }

    var connectionBannerText: String {
        if activeDVTSessionAvailable || locationDataPathHealthy {
            return L10n.text("裝置通道已連線")
        } else if localDevVPNAvailable {
            if currentTransport == .cellular && !newBootstrapAvailable {
                return L10n.text("LocalDevVPN 已連線，但目前無法建立新的定位通道")
            } else {
                return L10n.text("LocalDevVPN 已連線")
            }
        } else {
            return L10n.text("請先連接 LocalDevVPN")
        }
    }

    private let pathMonitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.routelocation.network-path", qos: .utility)
    private var started = false
    private var hasReceivedInitialPath = false
    private var lastPathSignature: String?
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
        let satisfied = path.status == .satisfied
        let transport = NetworkTransport.classify(
            isSatisfied: satisfied,
            usesWiFi: path.usesInterfaceType(.wifi),
            usesCellular: path.usesInterfaceType(.cellular),
            wifiAvailable: path.availableInterfaces.contains { $0.type == .wifi },
            cellularAvailable: path.availableInterfaces.contains { $0.type == .cellular },
            isExpensive: path.isExpensive
        )
        let vpnDetected = path.availableInterfaces.contains { $0.type == .other }
        let signature = "\(satisfied)|\(transport.rawValue)|\(vpnDetected)|\(path.isExpensive)"
        guard signature != lastPathSignature else { return }
        lastPathSignature = signature

        let oldTransport = currentTransport
        let vpnAvailabilityChanged = usesVPNInterface != vpnDetected
        previousTransport = oldTransport
        currentTransport = transport
        internetReachable = satisfied
        usesVPNInterface = vpnDetected
        pathIsExpensive = path.isExpensive
        LogManager.shared.addInfoLog(
            "Network path changed: transport=\(transport.rawValue), satisfied=\(satisfied), vpn=\(vpnDetected), expensive=\(path.isExpensive)"
        )

        if activeDVTSessionAvailable || locationDataPathHealthy {
            hasReceivedInitialPath = true
            LogManager.shared.addInfoLog(
                "NWPath changed: \(transport.rawValue). Recovery decision: SKIPPED. Reason: Recent successful location update / active DVT session"
            )
            return
        }

        let shouldCheck = !hasReceivedInitialPath
            ? transport != .offline
            : NetworkTransitionPolicy.needsDeviceHealthCheck(previous: oldTransport, current: transport)
                || (transport != .offline && vpnAvailabilityChanged)
        hasReceivedInitialPath = true
        guard shouldCheck else {
            if transport == .offline {
                if TunnelManager.shared.cellularBootstrapRequested {
                    TunnelManager.shared.handleNetworkTransition(from: oldTransport, to: transport)
                } else {
                    TunnelManager.shared.noteNetworkUnavailable()
                }
            }
            return
        }

        transportRevision &+= 1
        TunnelManager.shared.handleNetworkTransition(from: oldTransport, to: transport)
    }
}
