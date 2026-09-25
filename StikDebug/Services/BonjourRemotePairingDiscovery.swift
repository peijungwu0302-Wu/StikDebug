import Combine
import Foundation
import Network

struct RemotePairingDiscoveredService: Identifiable, Codable, Equatable {
    let id: UUID
    let serviceName: String
    let serviceType: String
    let domain: String
    var port: UInt16?
    var resolvedAddresses: [String]
    var interfaceName: String?
    var resolveDurationMs: Double?
    var addressResolutionUnavailable: Bool
    let discoveredAt: Date

    init(
        id: UUID = UUID(),
        serviceName: String,
        serviceType: String = "_remotepairing._tcp",
        domain: String = "local.",
        port: UInt16? = nil,
        resolvedAddresses: [String] = [],
        interfaceName: String? = nil,
        resolveDurationMs: Double? = nil,
        addressResolutionUnavailable: Bool = false,
        discoveredAt: Date = .now
    ) {
        self.id = id
        self.serviceName = serviceName
        self.serviceType = serviceType
        self.domain = domain
        self.port = port
        self.resolvedAddresses = resolvedAddresses
        self.interfaceName = interfaceName
        self.resolveDurationMs = resolveDurationMs
        self.addressResolutionUnavailable = addressResolutionUnavailable
        self.discoveredAt = discoveredAt
    }

    var redactedServiceName: String {
        guard serviceName.count > 4 else { return "RP••••" }
        let prefix = serviceName.prefix(3)
        return "\(prefix)••••••••"
    }

    var summaryText: String {
        let portStr = port.map { ":\($0)" } ?? ""
        let addrs = resolvedAddresses.isEmpty
            ? (addressResolutionUnavailable ? "位址無法解析 (Unavailable)" : "解析中...")
            : resolvedAddresses.joined(separator: ", ")
        let iface = interfaceName.map { " (\($0))" } ?? ""
        let dur = resolveDurationMs.map { String(format: " [%.0fms]", $0) } ?? ""
        return "\(redactedServiceName)\(portStr) - \(addrs)\(iface)\(dur)"
    }
}

private final class NetServiceResolveSession: NSObject, NetServiceDelegate {
    private let netService: NetService
    private let completion: @Sendable (UInt16?, [String], Bool) -> Void
    private var isDone = false
    private let timer: DispatchSourceTimer

    init(netService: NetService, completion: @escaping @Sendable (UInt16?, [String], Bool) -> Void) {
        self.netService = netService
        self.completion = completion
        self.timer = DispatchSource.makeTimerSource(queue: .main)
        super.init()
        self.netService.delegate = self
    }

    func start() {
        netService.resolve(withTimeout: 2.5)
        timer.schedule(deadline: .now() + 2.8)
        timer.setEventHandler { [weak self] in
            self?.finish(port: nil, addresses: [], unavailable: true)
        }
        timer.resume()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        var addrs: [String] = []
        if let addresses = sender.addresses {
            for addrData in addresses {
                addrData.withUnsafeBytes { raw in
                    guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return }
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let len: socklen_t = sa.pointee.sa_family == sa_family_t(AF_INET)
                        ? socklen_t(MemoryLayout<sockaddr_in>.size)
                        : socklen_t(MemoryLayout<sockaddr_in6>.size)
                    if getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: host)
                        if !ip.isEmpty && !addrs.contains(ip) {
                            addrs.append(ip)
                        }
                    }
                }
            }
        }
        let port = sender.port > 0 ? UInt16(sender.port) : nil
        finish(port: port, addresses: addrs, unavailable: addrs.isEmpty && port == nil)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        finish(port: nil, addresses: [], unavailable: true)
    }

    private func finish(port: UInt16?, addresses: [String], unavailable: Bool) {
        guard !isDone else { return }
        isDone = true
        timer.cancel()
        netService.stop()
        completion(port, addresses, unavailable)
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
    private var activeResolvers: [NetServiceResolveSession] = []

    private init() {}

    func startDiscovery() {
        guard !isSearching else { return }
        discoveredServices.removeAll()
        activeResolvers.removeAll()
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

        // Automatically stop after 5 seconds to conserve battery and avoid stalling
        Task {
            try? await Task.sleep(for: .seconds(5))
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
        activeResolvers.removeAll()

        BootstrapTraceStore.shared.recordEvent(
            .peerDiscoveryCompleted,
            details: [
                "foundCount": String(discoveredServices.count),
                "services": discoveredServices.map(\.summaryText).joined(separator: " | ")
            ]
        )
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
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

            // Check if already in discovered list
            if let existingIdx = discoveredServices.firstIndex(where: { $0.serviceName == sName && $0.domain == sDomain }) {
                if ifaceName != nil && discoveredServices[existingIdx].interfaceName == nil {
                    discoveredServices[existingIdx].interfaceName = ifaceName
                }
                continue
            }

            var service = RemotePairingDiscoveredService(
                serviceName: sName,
                serviceType: sType,
                domain: sDomain,
                port: nil,
                resolvedAddresses: [],
                interfaceName: ifaceName,
                resolveDurationMs: nil,
                addressResolutionUnavailable: false
            )
            discoveredServices.append(service)
            self.lastStatus = "發現 \(discoveredServices.count) 個服務，正在解析 IP/Port..."

            // Initiate real NetService resolution
            let serviceIndex = discoveredServices.count - 1
            let startTime = ProcessInfo.processInfo.systemUptime
            let ns = NetService(domain: sDomain, type: sType, name: sName)
            let session = NetServiceResolveSession(netService: ns) { [weak self] port, addresses, unavailable in
                Task { @MainActor [weak self] in
                    guard let self, serviceIndex < self.discoveredServices.count else { return }
                    let duration = (ProcessInfo.processInfo.systemUptime - startTime) * 1000.0
                    self.discoveredServices[serviceIndex].port = port
                    self.discoveredServices[serviceIndex].resolvedAddresses = addresses
                    self.discoveredServices[serviceIndex].resolveDurationMs = duration
                    self.discoveredServices[serviceIndex].addressResolutionUnavailable = unavailable
                    self.lastStatus = "已解析 \(self.discoveredServices.count) 個 RemotePairing 服務"
                }
            }
            activeResolvers.append(session)
            session.start()
        }
    }

    func summaryForTrace() -> String {
        if discoveredServices.isEmpty {
            return isSearching ? "Bonjour 搜尋中..." : "未發現 _remotepairing._tcp"
        }
        return discoveredServices.map(\.summaryText).joined(separator: " ; ")
    }

    #if DEBUG
    func injectServicesForTesting(_ services: [RemotePairingDiscoveredService]) {
        self.discoveredServices = services
        self.lastStatus = "測試注入: \(services.count) 個"
    }
    #endif
}
