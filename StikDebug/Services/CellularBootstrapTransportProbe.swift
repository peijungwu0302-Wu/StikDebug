//
//  CellularBootstrapTransportProbe.swift
//  StikDebug
//
//  Created for RouteLocation Cellular Bootstrap Transport Spike.
//

import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

public struct NetworkInterfaceInfo: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let index: Int
    public let nwInterfaceType: String
    public let addresses: [String]
    public let destinationAddresses: [String]
    public let isPointToPoint: Bool
    public let isUp: Bool
    public let isLoopback: Bool
    public let isTunnelLike: Bool

    public init(
        id: String,
        name: String,
        index: Int,
        nwInterfaceType: String,
        addresses: [String],
        destinationAddresses: [String] = [],
        isPointToPoint: Bool = false,
        isUp: Bool = true,
        isLoopback: Bool = false,
        isTunnelLike: Bool = false
    ) {
        self.id = id
        self.name = name
        self.index = index
        self.nwInterfaceType = nwInterfaceType
        self.addresses = addresses
        self.destinationAddresses = destinationAddresses
        self.isPointToPoint = isPointToPoint
        self.isUp = isUp
        self.isLoopback = isLoopback
        self.isTunnelLike = isTunnelLike
    }

    public var displaySummary: String {
        let addrs = addresses.isEmpty ? "no-ip" : addresses.joined(separator: ", ")
        return "\(name) (idx: \(index), type: \(nwInterfaceType), \(addrs))"
    }
}

public enum VPNInterfaceConfidence: String, Equatable {
    case confident = "Confident"
    case ambiguous = "Ambiguous"
    case none = "None"
}

public enum PeerSource: String, CaseIterable, Equatable {
    case P2P_DSTADDR
    case HEURISTIC_10_7
    case UNKNOWN
}

public struct VPNInterfaceCandidate: Equatable {
    public let interface: NetworkInterfaceInfo?
    public let confidence: VPNInterfaceConfidence
    public let detectedPeer: String?
    public let peerSource: PeerSource
    public let reason: String

    public init(
        interface: NetworkInterfaceInfo?,
        confidence: VPNInterfaceConfidence,
        detectedPeer: String?,
        peerSource: PeerSource = .UNKNOWN,
        reason: String
    ) {
        self.interface = interface
        self.confidence = confidence
        self.detectedPeer = detectedPeer
        self.peerSource = peerSource
        self.reason = reason
    }
}

public enum CellularProbeType: String, CaseIterable, Equatable {
    case baseline = "PROBE A — Baseline"
    case cellularProhibited = "PROBE B — Cellular-Prohibited TCP"
    case requiredInterface = "PROBE C — Required VPN Interface"
}

public enum InterfacePolicy: String, CaseIterable, Equatable {
    case DEFAULT
    case CELLULAR_PROHIBITED
    case REQUIRED_INTERFACE
}

public enum ProbeStatus: String, Equatable {
    case success = "SUCCESS"
    case failure = "FAIL"
    case notRun = "NOT RUN"
}

public struct CellularPathProbeResult: Identifiable, Equatable {
    public let id: UUID
    public let probeType: CellularProbeType
    public let status: ProbeStatus
    public let interfacePolicy: InterfacePolicy
    public let requestedInterfaceName: String?
    public let requiredInterfaceApplied: Bool
    public let targetIP: String
    public let targetPort: Int
    public let localEndpoint: String?
    public let remoteEndpoint: String?
    public let elapsedMs: Int
    public let nwErrorDomain: String?
    public let nwErrorCode: Int?
    public let posixErrno: Int32?
    public let errorDescription: String?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        probeType: CellularProbeType,
        status: ProbeStatus,
        interfacePolicy: InterfacePolicy = .DEFAULT,
        requestedInterfaceName: String? = nil,
        requiredInterfaceApplied: Bool = false,
        targetIP: String = "",
        targetPort: Int = 49152,
        localEndpoint: String? = nil,
        remoteEndpoint: String? = nil,
        elapsedMs: Int = 0,
        nwErrorDomain: String? = nil,
        nwErrorCode: Int? = nil,
        posixErrno: Int32? = nil,
        errorDescription: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.probeType = probeType
        self.status = status
        self.interfacePolicy = interfacePolicy
        self.requestedInterfaceName = requestedInterfaceName
        self.requiredInterfaceApplied = requiredInterfaceApplied
        self.targetIP = targetIP
        self.targetPort = targetPort
        self.localEndpoint = localEndpoint
        self.remoteEndpoint = remoteEndpoint
        self.elapsedMs = elapsedMs
        self.nwErrorDomain = nwErrorDomain
        self.nwErrorCode = nwErrorCode
        self.posixErrno = posixErrno
        self.errorDescription = errorDescription
        self.timestamp = timestamp
    }
}

public struct NetworkEnvironmentSnapshot: Equatable {
    public let timestamp: Date
    public let primaryTransport: String
    public let isWifiAvailable: Bool
    public let isCellularAvailable: Bool
    public let isInternetSatisfied: Bool
    public let isExpensive: Bool
    public let vpnDetectedByNWPath: Bool
    public let allInterfaces: [NetworkInterfaceInfo]
    public let vpnCandidate: VPNInterfaceCandidate
    public let configuredTargetIP: String
    public let configuredTargetPort: Int
    public let detectedCandidatePeer: String?
    public let peerSource: PeerSource
    public let activeDVTSession: Bool
    public let recentLocationSuccess: Bool
    public let tunnelConnected: Bool

    public init(
        timestamp: Date = Date(),
        primaryTransport: String,
        isWifiAvailable: Bool,
        isCellularAvailable: Bool,
        isInternetSatisfied: Bool,
        isExpensive: Bool,
        vpnDetectedByNWPath: Bool,
        allInterfaces: [NetworkInterfaceInfo],
        vpnCandidate: VPNInterfaceCandidate,
        configuredTargetIP: String,
        configuredTargetPort: Int = 49152,
        detectedCandidatePeer: String?,
        peerSource: PeerSource = .UNKNOWN,
        activeDVTSession: Bool,
        recentLocationSuccess: Bool,
        tunnelConnected: Bool
    ) {
        self.timestamp = timestamp
        self.primaryTransport = primaryTransport
        self.isWifiAvailable = isWifiAvailable
        self.isCellularAvailable = isCellularAvailable
        self.isInternetSatisfied = isInternetSatisfied
        self.isExpensive = isExpensive
        self.vpnDetectedByNWPath = vpnDetectedByNWPath
        self.allInterfaces = allInterfaces
        self.vpnCandidate = vpnCandidate
        self.configuredTargetIP = configuredTargetIP
        self.configuredTargetPort = configuredTargetPort
        self.detectedCandidatePeer = detectedCandidatePeer
        self.peerSource = peerSource
        self.activeDVTSession = activeDVTSession
        self.recentLocationSuccess = recentLocationSuccess
        self.tunnelConnected = tunnelConnected
    }
}

@MainActor
public final class CellularBootstrapTransportProbe: ObservableObject {
    public static let shared = CellularBootstrapTransportProbe()

    @Published public private(set) var latestSnapshot: NetworkEnvironmentSnapshot?
    @Published public private(set) var probeAResult: CellularPathProbeResult?
    @Published public private(set) var probeBResult: CellularPathProbeResult?
    @Published public private(set) var probeCResult: CellularPathProbeResult?
    @Published public private(set) var candidatePeerProbeResult: CellularPathProbeResult?
    @Published public private(set) var isProbing = false

    private let pathMonitor = NWPathMonitor()
    private var currentNWPath: NWPath?

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.currentNWPath = path
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.routelocation.pathprobe", qos: .utility))
    }

    public func captureSnapshot() -> NetworkEnvironmentSnapshot {
        let monitor = ConnectionMonitor.shared
        let interfaces = Self.querySystemInterfaces()
        let vpnCandidate = Self.deriveVPNCandidate(interfaces: interfaces)
        let targetIP = DeviceConnectionContext.targetIPAddress

        let snapshot = NetworkEnvironmentSnapshot(
            primaryTransport: monitor.currentTransport.rawValue,
            isWifiAvailable: currentNWPath?.availableInterfaces.contains { $0.type == .wifi } ?? false,
            isCellularAvailable: currentNWPath?.availableInterfaces.contains { $0.type == .cellular } ?? false,
            isInternetSatisfied: currentNWPath?.status == .satisfied,
            isExpensive: currentNWPath?.isExpensive ?? false,
            vpnDetectedByNWPath: monitor.usesVPNInterface,
            allInterfaces: interfaces,
            vpnCandidate: vpnCandidate,
            configuredTargetIP: targetIP,
            configuredTargetPort: 49152,
            detectedCandidatePeer: vpnCandidate.detectedPeer,
            peerSource: vpnCandidate.peerSource,
            activeDVTSession: monitor.activeDVTSessionAvailable,
            recentLocationSuccess: LocationDataPathHealth.shared.hasRecentSuccess,
            tunnelConnected: TunnelManager.shared.isConnected
        )
        self.latestSnapshot = snapshot
        return snapshot
    }

    public func runAllProbes() async {
        guard !isProbing else { return }
        isProbing = true
        defer { isProbing = false }

        let snapshot = captureSnapshot()

        // 1. Probe A (Baseline)
        probeAResult = await executeSingleProbe(
            type: .baseline,
            targetIP: snapshot.configuredTargetIP,
            targetPort: snapshot.configuredTargetPort,
            candidateInterface: snapshot.vpnCandidate.interface
        )

        // 2. Probe B (Cellular-prohibited)
        probeBResult = await executeSingleProbe(
            type: .cellularProhibited,
            targetIP: snapshot.configuredTargetIP,
            targetPort: snapshot.configuredTargetPort,
            candidateInterface: snapshot.vpnCandidate.interface
        )

        // 3. Probe C (Required VPN interface)
        if snapshot.vpnCandidate.interface != nil {
            probeCResult = await executeSingleProbe(
                type: .requiredInterface,
                targetIP: snapshot.configuredTargetIP,
                targetPort: snapshot.configuredTargetPort,
                candidateInterface: snapshot.vpnCandidate.interface
            )
        } else {
            probeCResult = CellularPathProbeResult(
                probeType: .requiredInterface,
                status: .notRun,
                interfacePolicy: .REQUIRED_INTERFACE,
                requestedInterfaceName: nil,
                requiredInterfaceApplied: false,
                targetIP: snapshot.configuredTargetIP,
                targetPort: snapshot.configuredTargetPort,
                errorDescription: "未偵測到可用之 VPN 候選介面"
            )
        }

        // 4. Candidate Peer Controlled Confirmation Probe (only if distinct and P2P_DSTADDR)
        if let peer = snapshot.detectedCandidatePeer,
           peer != snapshot.configuredTargetIP,
           snapshot.vpnCandidate.peerSource == .P2P_DSTADDR {
            candidatePeerProbeResult = await executeSingleProbe(
                type: .baseline,
                targetIP: peer,
                targetPort: snapshot.configuredTargetPort,
                candidateInterface: snapshot.vpnCandidate.interface
            )
        } else {
            candidatePeerProbeResult = nil
        }
    }

    private func executeSingleProbe(
        type: CellularProbeType,
        targetIP: String,
        targetPort: Int,
        candidateInterface: NetworkInterfaceInfo?
    ) async -> CellularPathProbeResult {
        let policy: InterfacePolicy
        switch type {
        case .baseline: policy = .DEFAULT
        case .cellularProhibited: policy = .CELLULAR_PROHIBITED
        case .requiredInterface: policy = .REQUIRED_INTERFACE
        }

        DeveloperDiagnosticsStore.shared.record(
            category: .transport,
            action: "CELLULAR_PATH_PROBE_START",
            details: [
                "probeType": type.rawValue,
                "policy": policy.rawValue,
                "targetIP": targetIP,
                "targetPort": String(targetPort),
                "requestedInterface": candidateInterface?.name ?? "none"
            ]
        )

        let startTime = Date()
        let result = await performNWConnectionProbe(
            type: type,
            targetIP: targetIP,
            targetPort: targetPort,
            candidateInterface: candidateInterface
        )

        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let finalizedResult = CellularPathProbeResult(
            id: result.id,
            probeType: result.probeType,
            status: result.status,
            interfacePolicy: result.interfacePolicy,
            requestedInterfaceName: result.requestedInterfaceName,
            requiredInterfaceApplied: result.requiredInterfaceApplied,
            targetIP: result.targetIP,
            targetPort: result.targetPort,
            localEndpoint: result.localEndpoint,
            remoteEndpoint: result.remoteEndpoint,
            elapsedMs: elapsedMs,
            nwErrorDomain: result.nwErrorDomain,
            nwErrorCode: result.nwErrorCode,
            posixErrno: result.posixErrno,
            errorDescription: result.errorDescription,
            timestamp: Date()
        )

        var logDetails: [String: String] = [
            "probeType": type.rawValue,
            "policy": finalizedResult.interfacePolicy.rawValue,
            "result": finalizedResult.status.rawValue,
            "requiredInterfaceApplied": String(finalizedResult.requiredInterfaceApplied),
            "elapsedMs": String(elapsedMs),
            "targetIP": targetIP,
            "targetPort": String(targetPort)
        ]
        if let reqIf = finalizedResult.requestedInterfaceName {
            logDetails["requestedInterface"] = reqIf
        }
        if let errCode = finalizedResult.nwErrorCode {
            logDetails["nwErrorCode"] = String(errCode)
        }
        if let posixCode = finalizedResult.posixErrno {
            logDetails["posixErrno"] = String(posixCode)
        }

        DeveloperDiagnosticsStore.shared.record(
            category: .transport,
            action: "CELLULAR_PATH_PROBE_RESULT",
            details: logDetails
        )

        return finalizedResult
    }

    private func performNWConnectionProbe(
        type: CellularProbeType,
        targetIP: String,
        targetPort: Int,
        candidateInterface: NetworkInterfaceInfo?
    ) async -> CellularPathProbeResult {
        let policy: InterfacePolicy
        switch type {
        case .baseline: policy = .DEFAULT
        case .cellularProhibited: policy = .CELLULAR_PROHIBITED
        case .requiredInterface: policy = .REQUIRED_INTERFACE
        }

        guard let port = NWEndpoint.Port(rawValue: UInt16(targetPort)) else {
            return CellularPathProbeResult(
                probeType: type,
                status: .failure,
                interfacePolicy: policy,
                requestedInterfaceName: candidateInterface?.name,
                requiredInterfaceApplied: false,
                targetIP: targetIP,
                targetPort: targetPort,
                errorDescription: "Invalid destination port"
            )
        }

        let host = NWEndpoint.Host(targetIP)
        let endpoint = NWEndpoint.hostPort(host: host, port: port)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 3

        let params: NWParameters
        var requiredInterfaceApplied = false

        switch type {
        case .baseline:
            params = NWParameters(tls: nil, tcp: tcpOptions)
        case .cellularProhibited:
            params = NWParameters(tls: nil, tcp: tcpOptions)
            params.prohibitedInterfaceTypes = [.cellular]
        case .requiredInterface:
            guard let candidate = candidateInterface else {
                return CellularPathProbeResult(
                    probeType: .requiredInterface,
                    status: .notRun,
                    interfacePolicy: .REQUIRED_INTERFACE,
                    requestedInterfaceName: nil,
                    requiredInterfaceApplied: false,
                    targetIP: targetIP,
                    targetPort: targetPort,
                    errorDescription: "未指定或未偵測到 VPN 候選介面"
                )
            }

            let matchingNWInterface = currentNWPath?.availableInterfaces.first(where: {
                $0.name == candidate.name || (candidate.index > 0 && $0.index == candidate.index)
            })

            guard let nwInterface = matchingNWInterface else {
                // MUST NEVER SILENTLY FALL BACK!
                return CellularPathProbeResult(
                    probeType: .requiredInterface,
                    status: .notRun,
                    interfacePolicy: .REQUIRED_INTERFACE,
                    requestedInterfaceName: candidate.name,
                    requiredInterfaceApplied: false,
                    targetIP: targetIP,
                    targetPort: targetPort,
                    errorDescription: "CANDIDATE_INTERFACE_NOT_RESOLVABLE_TO_NWINTERFACE"
                )
            }

            params = NWParameters(tls: nil, tcp: tcpOptions)
            params.requiredInterface = nwInterface
            requiredInterfaceApplied = true
        }

        let connection = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "com.routelocation.probe-conn", qos: .userInitiated)

        return await withCheckedContinuation { continuation in
            var hasResponded = false
            let lock = NSLock()

            func replyOnce(_ res: CellularPathProbeResult) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResponded else { return }
                hasResponded = true
                connection.cancel()
                continuation.resume(returning: res)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let path = connection.currentPath
                    let localEP = path?.localEndpoint?.debugDescription
                    let remoteEP = path?.remoteEndpoint?.debugDescription

                    replyOnce(CellularPathProbeResult(
                        probeType: type,
                        status: .success,
                        interfacePolicy: policy,
                        requestedInterfaceName: candidateInterface?.name,
                        requiredInterfaceApplied: requiredInterfaceApplied,
                        targetIP: targetIP,
                        targetPort: targetPort,
                        localEndpoint: localEP,
                        remoteEndpoint: remoteEP
                    ))

                case .failed(let error):
                    var posixCode: Int32? = nil
                    var nwDomain: String? = nil
                    var nwCode: Int? = nil

                    if case .posix(let code) = error {
                        posixCode = code.rawValue
                    } else if case .dns(let dnsCode) = error {
                        nwCode = Int(dnsCode)
                        nwDomain = "kNWErrorDomainDNS"
                    } else if case .tls(let status) = error {
                        nwCode = Int(status)
                        nwDomain = "kNWErrorDomainTLS"
                    }

                    replyOnce(CellularPathProbeResult(
                        probeType: type,
                        status: .failure,
                        interfacePolicy: policy,
                        requestedInterfaceName: candidateInterface?.name,
                        requiredInterfaceApplied: requiredInterfaceApplied,
                        targetIP: targetIP,
                        targetPort: targetPort,
                        nwErrorDomain: nwDomain,
                        nwErrorCode: nwCode,
                        posixErrno: posixCode,
                        errorDescription: error.localizedDescription
                    ))

                case .cancelled:
                    replyOnce(CellularPathProbeResult(
                        probeType: type,
                        status: .failure,
                        interfacePolicy: policy,
                        requestedInterfaceName: candidateInterface?.name,
                        requiredInterfaceApplied: requiredInterfaceApplied,
                        targetIP: targetIP,
                        targetPort: targetPort,
                        posixErrno: 89, // ECANCELED
                        errorDescription: "連線探測已取消"
                    ))

                default:
                    break
                }
            }

            connection.start(queue: queue)

            // 3.5s safety timeout
            queue.asyncAfter(deadline: .now() + 3.5) {
                replyOnce(CellularPathProbeResult(
                    probeType: type,
                    status: .failure,
                    interfacePolicy: policy,
                    requestedInterfaceName: candidateInterface?.name,
                    requiredInterfaceApplied: requiredInterfaceApplied,
                    targetIP: targetIP,
                    targetPort: targetPort,
                    posixErrno: 60, // ETIMEDOUT
                    errorDescription: "探測超時 (3.5s)"
                ))
            }
        }
    }

    // MARK: - Interface Query & VPN Candidate Derivation

    public static func querySystemInterfaces() -> [NetworkInterfaceInfo] {
        #if canImport(Darwin)
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let firstAddr = ifaddrPointer else {
            return []
        }
        defer { freeifaddrs(ifaddrPointer) }

        var interfaceMap: [String: (index: Int, flags: UInt32, addresses: [String], dstAddresses: [String])] = [:]
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let current = ptr {
            let name = String(cString: current.pointee.ifa_name)
            let flags = current.pointee.ifa_flags
            let index = Int(if_nametoindex(current.pointee.ifa_name))

            var currentEntry = interfaceMap[name] ?? (index: index, flags: flags, addresses: [], dstAddresses: [])

            if let addr = current.pointee.ifa_addr {
                let family = addr.pointee.sa_family
                if family == sa_family_t(AF_INET) {
                    var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                    let ipStr = String(cString: buffer)
                    if !ipStr.isEmpty && !currentEntry.addresses.contains(ipStr) {
                        currentEntry.addresses.append(ipStr)
                    }
                } else if family == sa_family_t(AF_INET6) {
                    var sin6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    inet_ntop(AF_INET6, &sin6.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
                    let ipStr = String(cString: buffer)
                    if !ipStr.isEmpty && !currentEntry.addresses.contains(ipStr) {
                        currentEntry.addresses.append(ipStr)
                    }
                }
            }

            if let dstAddr = current.pointee.ifa_dstaddr {
                let family = dstAddr.pointee.sa_family
                if family == sa_family_t(AF_INET) {
                    var sin = dstAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                    let ipStr = String(cString: buffer)
                    if !ipStr.isEmpty && !currentEntry.dstAddresses.contains(ipStr) {
                        currentEntry.dstAddresses.append(ipStr)
                    }
                }
            }

            interfaceMap[name] = currentEntry
            ptr = current.pointee.ifa_next
        }

        return interfaceMap.map { name, entry in
            let isPointToPoint = (entry.flags & UInt32(IFF_POINTTOPOINT)) != 0
            let isUp = (entry.flags & UInt32(IFF_UP)) != 0
            let isLoopback = (entry.flags & UInt32(IFF_LOOPBACK)) != 0
            let isTunnelLike = isPointToPoint || name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")

            var typeStr = "other"
            if isLoopback {
                typeStr = "loopback"
            } else if name.hasPrefix("en") {
                typeStr = "wifi/ethernet"
            } else if name.hasPrefix("pdp_ip") {
                typeStr = "cellular"
            } else if isTunnelLike {
                typeStr = "tunnel/vpn"
            }

            return NetworkInterfaceInfo(
                id: "\(name)-\(entry.index)",
                name: name,
                index: entry.index,
                nwInterfaceType: typeStr,
                addresses: entry.addresses,
                destinationAddresses: entry.dstAddresses,
                isPointToPoint: isPointToPoint,
                isUp: isUp,
                isLoopback: isLoopback,
                isTunnelLike: isTunnelLike
            )
        }.sorted { $0.name < $1.name }
        #else
        return []
        #endif
    }

    public static func deriveVPNCandidate(interfaces: [NetworkInterfaceInfo]) -> VPNInterfaceCandidate {
        let activeTunnels = interfaces.filter { $0.isTunnelLike && $0.isUp && !$0.isLoopback }

        if activeTunnels.isEmpty {
            return VPNInterfaceCandidate(
                interface: nil,
                confidence: .none,
                detectedPeer: nil,
                peerSource: .UNKNOWN,
                reason: "未偵測到任何作用中之 utun / point-to-point 介面"
            )
        }

        // Subnet check for 10.7.x.x
        let tunnelsWith10_7 = activeTunnels.filter { iface in
            iface.addresses.contains { $0.hasPrefix("10.7.") } ||
            iface.destinationAddresses.contains { $0.hasPrefix("10.7.") }
        }

        if tunnelsWith10_7.count == 1, let target = tunnelsWith10_7.first {
            let (peer, source) = derivePeer(from: target)
            return VPNInterfaceCandidate(
                interface: target,
                confidence: .confident,
                detectedPeer: peer,
                peerSource: source,
                reason: "唯一比對到 10.7.x.x 子網域之介面 (\(target.name))"
            )
        }

        if activeTunnels.count == 1, let single = activeTunnels.first {
            let (peer, source) = derivePeer(from: single)
            let isP2PWithIP = single.isPointToPoint && !single.addresses.isEmpty
            return VPNInterfaceCandidate(
                interface: single,
                confidence: isP2PWithIP ? .confident : .ambiguous,
                detectedPeer: peer,
                peerSource: source,
                reason: isP2PWithIP
                    ? "單一作用中之 point-to-point 介面 (\(single.name))"
                    : "單一 utun 介面 (\(single.name))，但無明確 P2P IP 特徵"
            )
        }

        // Multiple tunnels
        let names = activeTunnels.map(\.name).joined(separator: ", ")
        return VPNInterfaceCandidate(
            interface: nil,
            confidence: .ambiguous,
            detectedPeer: nil,
            peerSource: .UNKNOWN,
            reason: "偵測到多個作用中介面 (\(names))，無法唯一辨識 LocalDevVPN"
        )
    }

    private static func derivePeer(from interface: NetworkInterfaceInfo) -> (String?, PeerSource) {
        if let dst = interface.destinationAddresses.first(where: { !$0.isEmpty }) {
            return (dst, .P2P_DSTADDR)
        }
        for addr in interface.addresses {
            if addr.hasPrefix("10.7.") {
                if addr != "10.7.0.1" {
                    return ("10.7.0.1", .HEURISTIC_10_7)
                }
            }
        }
        return (nil, .UNKNOWN)
    }
}
