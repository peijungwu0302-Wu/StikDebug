//
//  UtunTopologyCollector.swift
//  StikDebug
//
//  Created for RouteLocation v1.2.11 Research Topology Analysis.
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct UtunInterfaceEntry: Identifiable, Codable, Equatable {
    var id: String { "\(interfaceName)_\(addressFamily)_\(observedInterfaceAddress ?? "none")" }
    let interfaceName: String
    let addressFamily: String // "IPv4" or "IPv6"
    let ifaFlags: UInt32
    let isPointToPoint: Bool
    let isUp: Bool
    let isRunning: Bool
    let observedInterfaceAddress: String? // Neutral naming
    let observedP2PLocalAddress: String?   // Local / source address
    let observedP2PDestination: String?    // Destination address (ifa_dstaddr)
    let observedNetmask: String?

    init(
        interfaceName: String,
        addressFamily: String,
        ifaFlags: UInt32,
        isPointToPoint: Bool,
        isUp: Bool,
        isRunning: Bool,
        observedInterfaceAddress: String?,
        observedP2PLocalAddress: String?,
        observedP2PDestination: String?,
        observedNetmask: String?
    ) {
        self.interfaceName = interfaceName
        self.addressFamily = addressFamily
        self.ifaFlags = ifaFlags
        self.isPointToPoint = isPointToPoint
        self.isUp = isUp
        self.isRunning = isRunning
        self.observedInterfaceAddress = observedInterfaceAddress
        self.observedP2PLocalAddress = observedP2PLocalAddress
        self.observedP2PDestination = observedP2PDestination
        self.observedNetmask = observedNetmask
    }
}

struct UtunTopologyReport: Codable, Equatable {
    let timestamp: Date
    let interfaces: [UtunInterfaceEntry]
    let hasPointToPointUtun: Bool
    let summary: String

    init(
        timestamp: Date = Date(),
        interfaces: [UtunInterfaceEntry],
        hasPointToPointUtun: Bool,
        summary: String
    ) {
        self.timestamp = timestamp
        self.interfaces = interfaces
        self.hasPointToPointUtun = hasPointToPointUtun
        self.summary = summary
    }
}

final class UtunTopologyCollector {

    #if DEBUG
    static var testMockEntries: [UtunInterfaceEntry]?
    #endif

    static func collectTopology() -> UtunTopologyReport {
        #if DEBUG
        if let mock = testMockEntries {
            let hasP2P = mock.contains { $0.isPointToPoint }
            return UtunTopologyReport(
                interfaces: mock,
                hasPointToPointUtun: hasP2P,
                summary: "Mock Topology (\(mock.count) utun entries)"
            )
        }
        #endif

        var entries: [UtunInterfaceEntry] = []

        #if canImport(Darwin)
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return UtunTopologyReport(
                interfaces: [],
                hasPointToPointUtun: false,
                summary: "getifaddrs() failed or no interfaces returned"
            )
        }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let name = String(cString: current.pointee.ifa_name)
            if name.hasPrefix("utun") {
                let flags = current.pointee.ifa_flags
                let isUp = (flags & UInt32(IFF_UP)) != 0
                let isRunning = (flags & UInt32(IFF_RUNNING)) != 0
                let isP2P = (flags & UInt32(IFF_POINTOPOINT)) != 0

                if let addrPtr = current.pointee.ifa_addr {
                    let family = addrPtr.pointee.sa_family
                    if family == UInt8(AF_INET) {
                        let ip = formatIPv4(addrPtr)
                        let netmask = current.pointee.ifa_netmask != nil ? formatIPv4(current.pointee.ifa_netmask) : nil
                        let dst = (isP2P && current.pointee.ifa_dstaddr != nil) ? formatIPv4(current.pointee.ifa_dstaddr) : nil

                        let entry = UtunInterfaceEntry(
                            interfaceName: name,
                            addressFamily: "IPv4",
                            ifaFlags: flags,
                            isPointToPoint: isP2P,
                            isUp: isUp,
                            isRunning: isRunning,
                            observedInterfaceAddress: ip,
                            observedP2PLocalAddress: ip,
                            observedP2PDestination: dst,
                            observedNetmask: netmask
                        )
                        entries.append(entry)
                    } else if family == UInt8(AF_INET6) {
                        let ip = formatIPv6(addrPtr)
                        let netmask = current.pointee.ifa_netmask != nil ? formatIPv6(current.pointee.ifa_netmask) : nil
                        let dst = (isP2P && current.pointee.ifa_dstaddr != nil) ? formatIPv6(current.pointee.ifa_dstaddr) : nil

                        let entry = UtunInterfaceEntry(
                            interfaceName: name,
                            addressFamily: "IPv6",
                            ifaFlags: flags,
                            isPointToPoint: isP2P,
                            isUp: isUp,
                            isRunning: isRunning,
                            observedInterfaceAddress: ip,
                            observedP2PLocalAddress: ip,
                            observedP2PDestination: dst,
                            observedNetmask: netmask
                        )
                        entries.append(entry)
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        #endif

        let hasP2P = entries.contains { $0.isPointToPoint }
        let summaryText: String
        if entries.isEmpty {
            summaryText = "未偵測到任何 utun 介面"
        } else {
            let p2pCount = entries.filter { $0.isPointToPoint }.count
            summaryText = "已偵測 \(entries.count) 個 utun 介面記錄 (P2P: \(p2pCount))"
        }

        return UtunTopologyReport(
            interfaces: entries,
            hasPointToPointUtun: hasP2P,
            summary: summaryText
        )
    }

    #if canImport(Darwin)
    private static func formatIPv4(_ sa: UnsafePointer<sockaddr>) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = sa.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
            getnameinfo(ptr, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        }
        return result == 0 ? String(cString: host) : "unknown"
    }

    private static func formatIPv6(_ sa: UnsafePointer<sockaddr>) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = sa.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
            getnameinfo(ptr, socklen_t(MemoryLayout<sockaddr_in6>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        }
        return result == 0 ? String(cString: host) : "unknown"
    }
    #endif
}
