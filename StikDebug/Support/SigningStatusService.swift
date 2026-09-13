//
//  SigningStatusService.swift
//  StikDebug
//

import Combine
import Foundation
import SwiftUI
import UIKit

public struct ProvisioningProfileInfo: Equatable, Sendable {
    public let name: String?
    public let appIDName: String?
    public let teamName: String?
    public let teamIdentifier: [String]
    public let creationDate: Date?
    public let expirationDate: Date
    public let entitlements: [String: AnyHashable]
    public let uuid: String?
    public let isProvisionsAllDevices: Bool

    public var remainingTimeInterval: TimeInterval {
        expirationDate.timeIntervalSince(Date())
    }

    public var isExpired: Bool {
        remainingTimeInterval <= 0
    }

    public var isExpiringWithinTwoDays: Bool {
        remainingTimeInterval > 0 && remainingTimeInterval <= 2 * 86400
    }

    public var isExpiringWithinTwelveHours: Bool {
        remainingTimeInterval > 0 && remainingTimeInterval <= 12 * 3600
    }
}

public enum SigningStatus: Equatable, Sendable {
    case valid(ProvisioningProfileInfo)
    case expiringSoon(ProvisioningProfileInfo)
    case expired(ProvisioningProfileInfo)
    case unreadable(reason: String)
    case simulatorOrUnsigned

    public var label: String {
        switch self {
        case .valid:
            return L10n.text("有效")
        case .expiringSoon(let info):
            if info.isExpiringWithinTwelveHours {
                return L10n.text("簽名即將到期")
            }
            return L10n.text("建議近期重新整理")
        case .expired:
            return L10n.text("已過期")
        case .unreadable:
            return L10n.text("無法讀取簽名資訊")
        case .simulatorOrUnsigned:
            return L10n.text("未簽名／模擬器環境")
        }
    }

    public var color: Color {
        switch self {
        case .valid:
            return .green
        case .expiringSoon(let info):
            return info.isExpiringWithinTwelveHours ? .red : .orange
        case .expired:
            return .red
        case .unreadable, .simulatorOrUnsigned:
            return .gray
        }
    }
}

public enum SigningParseError: LocalizedError {
    case missingXMLHeader
    case missingPlistFooter
    case invalidPlistContent
    case missingExpirationDate
    case profileFileNotFound

    public var errorDescription: String? {
        switch self {
        case .missingXMLHeader: return "找不到 XML 開頭標籤"
        case .missingPlistFooter: return "找不到 Property List 結尾標籤"
        case .invalidPlistContent: return "無法解析 Property List 內容"
        case .missingExpirationDate: return "簽名描述檔中缺少到期日期"
        case .profileFileNotFound: return "找不到 embedded.mobileprovision 檔案"
        }
    }
}

public enum ProvisioningProfileParser {
    public static func parse(data: Data) throws -> ProvisioningProfileInfo {
        guard let xmlStartRange = data.range(of: Data("<?xml".utf8)) else {
            throw SigningParseError.missingXMLHeader
        }
        guard let plistEndRange = data.range(of: Data("</plist>".utf8), options: .backwards) else {
            throw SigningParseError.missingPlistFooter
        }

        let xmlData = data.subdata(in: xmlStartRange.lowerBound..<plistEndRange.upperBound)

        var format = PropertyListSerialization.PropertyListFormat.xml
        let plistObject: Any
        do {
            plistObject = try PropertyListSerialization.propertyList(from: xmlData, options: [], format: &format)
        } catch {
            throw SigningParseError.invalidPlistContent
        }

        guard let plist = plistObject as? [String: Any] else {
            throw SigningParseError.invalidPlistContent
        }

        guard let expirationDate = plist["ExpirationDate"] as? Date else {
            throw SigningParseError.missingExpirationDate
        }

        let name = plist["Name"] as? String
        let appIDName = plist["AppIDName"] as? String
        let teamName = plist["TeamName"] as? String
        let teamIdentifier = plist["TeamIdentifier"] as? [String] ?? []
        let creationDate = plist["CreationDate"] as? Date
        let uuid = plist["UUID"] as? String
        let provisionsAllDevices = plist["ProvisionsAllDevices"] as? Bool ?? false

        var entitlementsHashable: [String: AnyHashable] = [:]
        if let entitlements = plist["Entitlements"] as? [String: Any] {
            for (k, v) in entitlements {
                if let s = v as? String { entitlementsHashable[k] = s }
                else if let b = v as? Bool { entitlementsHashable[k] = b }
                else if let a = v as? [String] { entitlementsHashable[k] = a }
            }
        }

        return ProvisioningProfileInfo(
            name: name,
            appIDName: appIDName,
            teamName: teamName,
            teamIdentifier: teamIdentifier,
            creationDate: creationDate,
            expirationDate: expirationDate,
            entitlements: entitlementsHashable,
            uuid: uuid,
            isProvisionsAllDevices: provisionsAllDevices
        )
    }

    public static func parseBundleProfile(bundle: Bundle = .main) throws -> ProvisioningProfileInfo {
        let profileURL = bundle.bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            if let resourceURL = bundle.url(forResource: "embedded", withExtension: "mobileprovision") {
                let data = try Data(contentsOf: resourceURL)
                return try parse(data: data)
            }
            throw SigningParseError.profileFileNotFound
        }
        let data = try Data(contentsOf: profileURL)
        return try parse(data: data)
    }
}

@MainActor
public final class SigningStatusService: ObservableObject {
    public static let shared = SigningStatusService()

    @Published public private(set) var currentStatus: SigningStatus = .simulatorOrUnsigned
    @Published public private(set) var profileInfo: ProvisioningProfileInfo?
    @Published public private(set) var lastRefreshedAt: Date = .now

    private var cancellables = Set<AnyCancellable>()

    private init() {
        refreshSigningStatus()
        setupNotificationObservers()
    }

    public func refreshSigningStatus() {
        lastRefreshedAt = .now
        do {
            let info = try ProvisioningProfileParser.parseBundleProfile()
            profileInfo = info

            if info.isExpired {
                currentStatus = .expired(info)
            } else if info.isExpiringWithinTwoDays {
                currentStatus = .expiringSoon(info)
            } else {
                currentStatus = .valid(info)
            }

            DeveloperDiagnosticsStore.shared.record(
                category: .lifecycle,
                action: "signing_profile_parse",
                details: [
                    "status": currentStatus.label,
                    "teamId": info.teamIdentifier.first ?? "none",
                    "appId": info.appIDName ?? "none"
                ]
            )
            DeveloperDiagnosticsStore.shared.record(
                category: .lifecycle,
                action: "signing_expiration_read",
                details: [
                    "expiration": ISO8601DateFormatter().string(from: info.expirationDate),
                    "remainingSeconds": "\(Int(info.remainingTimeInterval))"
                ]
            )
        } catch SigningParseError.profileFileNotFound {
            #if targetEnvironment(simulator)
            currentStatus = .simulatorOrUnsigned
            #else
            currentStatus = .unreadable(reason: L10n.text("未找到 embedded.mobileprovision"))
            #endif
            profileInfo = nil
        } catch {
            currentStatus = .unreadable(reason: error.localizedDescription)
            profileInfo = nil
        }
    }

    public var remainingFormatted: String {
        guard let info = profileInfo else {
            if case .simulatorOrUnsigned = currentStatus {
                return L10n.text("模擬器無簽名期限")
            }
            return L10n.text("未知")
        }
        let remaining = info.remainingTimeInterval
        if remaining <= 0 {
            return L10n.text("已過期")
        }

        let days = Int(remaining) / 86400
        let hours = (Int(remaining) % 86400) / 3600
        let minutes = (Int(remaining) % 3600) / 60

        if days > 0 {
            return L10n.format("%d 天 %d 小時", days, hours)
        } else if hours > 0 {
            return L10n.format("%d 小時 %d 分鐘", hours, minutes)
        } else {
            return L10n.format("%d 分鐘", max(minutes, 1))
        }
    }

    public var remainingTimeFormatted: String {
        remainingFormatted
    }

    public var expirationFormatted: String {
        guard let info = profileInfo else {
            return L10n.text("無")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateFormat = "M 月 d 日 HH:mm"
        return formatter.string(from: info.expirationDate)
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshSigningStatus()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshSigningStatus()
            }
            .store(in: &cancellables)
    }
}
