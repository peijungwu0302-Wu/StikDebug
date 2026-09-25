import Combine
import Foundation
import Network

struct RemotePairingDiscoveredService: Identifiable, Codable, Equatable {
    let id: UUID
    let serviceName: String
    let serviceType: String
    let domain: String
    let port: UInt16?
    let resolvedAddresses: [String]
    let interfaceName: String?
    let discoveredAt: Date

    init(
        id: UUID = UUID(),
        serviceName: String,
        serviceType: String = "_remotepairing._tcp",
        domain: String = "local.",
        port: UInt16? = nil,
        resolvedAddresses: [String] = [],
        interfaceName: String? = nil,
        discoveredAt: Date = .now
    ) {
        self.id = id
        self.serviceName = serviceName
        self.serviceType = serviceType
        self.domain = domain
        self.port = port
        self.resolvedAddresses = resolvedAddresses
        self.interfaceName = interfaceName
        self.discoveredAt = discoveredAt
    }

    var redactedServiceName: String {
        guard serviceName.count > 4 else { return "RP••••" }
        let prefix = serviceName.prefix(3)
        return "\(prefix)••••••••"
    }

    var summaryText: String {
        let portStr = port.map { ":\($0)" } ?? ""
        let addrs = resolvedAddresses.isEmpty ? "未解析位址" : resolvedAddresses.joined(separator: ", ")
        let iface = interfaceName.map { " (\($0))" } ?? ""
        return "\(redactedServiceName)\(portStr) - \(addrs)\(iface)"
    }
}

@MainActor
final class BonjourRemotePairingDiscovery: ObservableObject {
    static let shared = BonjourRemotePairingDiscovery()

    @Published private(set) var isSearching = false
    @Published private(set) var discoveredServices: [RemotePairingDiscoveredService] = []
    @Published private(set) var lastStatus: String = "未啟動"
    @Published private(set) var lastDiscoveryTime: Date?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.routelocation.bonjour-discovery", qos: .utility)
    private var resolvingConnections: [NWConnection] = []

    private init() {}

    func startDiscovery() {
        guard !isSearching else { return }
        discoveredServices.removeAll()
        isSearching = true
        lastStatus = "正在搜尋 _remotepairing._tcp 服務..."
        lastDiscoveryTime = Date()

        BootstrapTraceStore.shared.recordEvent(.peerDiscoveryStarted, details: ["service": "_remotepairing._tcp"])

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_remotepairing._tcp", domain: nil)
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let newBrowser = NWBrowser(for: descriptor, using: parameters)
        self.browser = newBrowser

        newBrowser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor [weak self] in
                self?.handleBrowseResults(results)
            }
        }

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.lastStatus = "Bonjour 探索進行中..."
                case .failed(let error):
                    self.lastStatus = "探索失敗: \(error.localizedDescription)"
                    self.isSearching = false
                    BootstrapTraceStore.shared.recordEvent(.peerDiscoveryCompleted, details: ["error": error.localizedDescription])
                case .cancelled:
                    self.lastStatus = "已停止探索"
                    self.isSearching = false
                default:
                    break
                }
            }
        }

        newBrowser.start(queue: queue)

        // Automatically stop after 6 seconds to conserve battery and resources
        Task {
            try? await Task.sleep(for: .seconds(6))
            await MainActor.run { [weak self] in
                if self?.isSearching == true {
                    self?.stopDiscovery()
                }
            }
        }
    }

    func stopDiscovery() {
        guard isSearching else { return }
        browser?.cancel()
        browser = nil
        isSearching = false
        lastStatus = discoveredServices.isEmpty ? "探索完成，未發現 RemotePairing 服務" : "探索完成，發現 \(discoveredServices.count) 個服務"
        for conn in resolvingConnections { conn.cancel() }
        resolvingConnections.removeAll()

        BootstrapTraceStore.shared.recordEvent(
            .peerDiscoveryCompleted,
            details: [
                "foundCount": String(discoveredServices.count),
                "services": discoveredServices.map(\.summaryText).joined(separator: " | ")
            ]
        )
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var updated: [RemotePairingDiscoveredService] = []

        for result in results {
            var sName = "Unknown"
            var sType = "_remotepairing._tcp"
            var sDomain = "local."
            var ifaceName: String?

            if case let .service(name, type, domain, interface) = result.endpoint {
                sName = name
                sType = type
                sDomain = domain
                ifaceName = interface?.name
            }

            let service = RemotePairingDiscoveredService(
                serviceName: sName,
                serviceType: sType,
                domain: sDomain,
                port: nil,
                resolvedAddresses: [],
                interfaceName: ifaceName
            )
            updated.append(service)
        }

        self.discoveredServices = updated
        self.lastStatus = "發現 \(updated.count) 個 RemotePairing 服務"
    }

    #if DEBUG
    func injectServicesForTesting(_ services: [RemotePairingDiscoveredService]) {
        self.discoveredServices = services
        self.lastStatus = "測試注入: \(services.count) 個"
    }
    #endif
}
