//
//  PairingFileStore.swift
//  StikDebug
//

import Foundation
import UniformTypeIdentifiers

public enum PairingValidationResult: Equatable, Sendable {
    case valid
    case invalid(reason: String)
    case parseError(reason: String)
    case unsupported

    public var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .valid: return L10n.text("已驗證")
        case .invalid(let reason): return L10n.format("驗證失敗：%@", reason)
        case .parseError(let reason): return L10n.format("解析錯誤：%@", reason)
        case .unsupported: return L10n.text("格式不受支援")
        }
    }
}

public enum PairingSource: String, Codable, Sendable {
    case manualImport = "manual_import"
    case externalPlacement = "external_placement"
    case legacyMigration = "legacy_migration"
    case unknown = "unknown"

    public var label: String {
        switch self {
        case .manualImport: return L10n.text("手動匯入")
        case .externalPlacement: return L10n.text("外部放置")
        case .legacyMigration: return L10n.text("舊版遷移")
        case .unknown: return L10n.text("未知")
        }
    }
}

public enum PairingError: LocalizedError {
    case fileNotFound
    case validationFailed(String)
    case unreadableContent

    public var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return L10n.text("找不到選取的配對檔案。")
        case .validationFailed(let reason):
            return L10n.format("配對檔案驗證失敗：%@。已保留原有的配對記錄。", reason)
        case .unreadableContent:
            return L10n.text("無法讀取檔案內容，請確認檔案格式是否正確。")
        }
    }
}

public enum PairingFileStore {
    public static let fileName = "pairingFile.plist"
    private static let legacyFileName = "rp_pairing_file.plist"
    private static let sourceDefaultsKey = "RouteLocation.pairingSource"

    public static let supportedContentTypes: [UTType] = {
        var types: [UTType] = [
            UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data)!,
            UTType(filenameExtension: "mobiledevicepair", conformingTo: .data)!,
            .propertyList,
            .xml,
            .data,
            .item
        ]
        return types
    }()

    public static var url: URL {
        directoryURL.appendingPathComponent(fileName)
    }

    public static var currentSource: PairingSource {
        get {
            guard let raw = UserDefaults.standard.string(forKey: sourceDefaultsKey),
                  let source = PairingSource(rawValue: raw) else {
                return .unknown
            }
            return source
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: sourceDefaultsKey)
        }
    }

    @discardableResult
    public static func prepareURL(fileManager: FileManager = .default) -> URL {
        let destination = url
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        if let documentURL = documentSourceURL(fileManager: fileManager) {
            if !fileManager.fileExists(atPath: destination.path) ||
                !fileManager.contentsEqual(atPath: documentURL.path, andPath: destination.path) {
                // Validate before replacing
                if let docData = try? Data(contentsOf: documentURL), validatePairingData(docData).isValid {
                    try? replaceItem(at: destination, with: documentURL, fileManager: fileManager)
                    protectPairingFile(at: destination, fileManager: fileManager)
                    currentSource = .externalPlacement
                    DeveloperDiagnosticsStore.shared.record(
                        category: .bootstrap,
                        action: "pairing_external_placement_synced",
                        details: [:]
                    )
                }
            }
            return destination
        }

        if !fileManager.fileExists(atPath: destination.path) {
            migrateLegacyCopy(to: destination, fileManager: fileManager)
        }
        return destination
    }

    public static func validatePairingData(_ data: Data) -> PairingValidationResult {
        guard !data.isEmpty else {
            return .invalid(reason: "檔案內容為空")
        }

        var format = PropertyListSerialization.PropertyListFormat.xml
        let plistObject: Any
        do {
            plistObject = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        } catch {
            return .parseError(reason: error.localizedDescription)
        }

        guard let dict = plistObject as? [String: Any] else {
            return .invalid(reason: "Root 物件不是字典結構")
        }

        // Validate standard Apple pairing record keys
        let requiredKeys = ["DeviceCertificate", "HostCertificate", "HostID", "RootCertificate", "SystemBUID"]
        var missingKeys: [String] = []
        for key in requiredKeys {
            if dict[key] == nil {
                missingKeys.append(key)
            }
        }

        if !missingKeys.isEmpty {
            return .invalid(reason: "缺少必要欄位: \(missingKeys.joined(separator: ", "))")
        }

        // Verify that certificates are non-empty data
        if let devCert = dict["DeviceCertificate"] as? Data, devCert.isEmpty {
            return .invalid(reason: "DeviceCertificate 為空")
        }
        if let hostCert = dict["HostCertificate"] as? Data, hostCert.isEmpty {
            return .invalid(reason: "HostCertificate 為空")
        }
        if let rootCert = dict["RootCertificate"] as? Data, rootCert.isEmpty {
            return .invalid(reason: "RootCertificate 為空")
        }
        if let hostId = dict["HostID"] as? String, hostId.trimmingCharacters(in: .whitespaces).isEmpty {
            return .invalid(reason: "HostID 為空")
        }

        return .valid
    }

    public static func validateCurrentPairing() -> PairingValidationResult {
        let destination = prepareURL()
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return .invalid(reason: "配對檔案不存在")
        }
        guard let data = try? Data(contentsOf: destination) else {
            return .parseError(reason: "無法讀取現有配對檔案")
        }
        return validatePairingData(data)
    }

    public static func importFromPicker(_ sourceURL: URL, fileManager: FileManager = .default) throws {
        DeveloperDiagnosticsStore.shared.record(
            category: .bootstrap,
            action: "pairing_import_requested",
            details: [:]
        )

        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw PairingError.fileNotFound
        }

        DeveloperDiagnosticsStore.shared.record(
            category: .bootstrap,
            action: "pairing_file_selected",
            details: ["extension": sourceURL.pathExtension]
        )

        guard let data = try? Data(contentsOf: sourceURL) else {
            throw PairingError.unreadableContent
        }

        let validation = validatePairingData(data)
        switch validation {
        case .valid:
            DeveloperDiagnosticsStore.shared.record(
                category: .bootstrap,
                action: "pairing_parse_success",
                details: [:]
            )
            DeveloperDiagnosticsStore.shared.record(
                category: .bootstrap,
                action: "pairing_validation_success",
                details: [:]
            )
        case .invalid(let reason):
            DeveloperDiagnosticsStore.shared.record(
                category: .bootstrap,
                action: "pairing_validation_failure",
                details: ["reason": reason]
            )
            throw PairingError.validationFailed(reason)
        case .parseError(let reason):
            DeveloperDiagnosticsStore.shared.record(
                category: .bootstrap,
                action: "pairing_parse_failure",
                details: ["reason": reason]
            )
            throw PairingError.validationFailed(reason)
        case .unsupported:
            DeveloperDiagnosticsStore.shared.record(
                category: .bootstrap,
                action: "pairing_validation_failure",
                details: ["reason": "unsupported"]
            )
            throw PairingError.validationFailed(L10n.text("格式不受支援"))
        }

        try replace(with: sourceURL, fileManager: fileManager)
        currentSource = .manualImport
        DeveloperDiagnosticsStore.shared.record(
            category: .bootstrap,
            action: "pairing_replace_success",
            details: [:]
        )
    }

    public static func replace(with sourceURL: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let documentsDestination = documentsURL
        if sourceURL.standardizedFileURL != documentsDestination.standardizedFileURL {
            try replaceItem(at: documentsDestination, with: sourceURL, fileManager: fileManager)
        }

        try replaceItem(at: url, with: documentsDestination, fileManager: fileManager)
        protectPairingFile(at: url, fileManager: fileManager)
    }

    public static func remove(fileManager: FileManager = .default) throws {
        let destination = prepareURL(fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        removeLegacyCopies(fileManager: fileManager)
        UserDefaults.standard.removeObject(forKey: sourceDefaultsKey)
        DeveloperDiagnosticsStore.shared.record(
            category: .bootstrap,
            action: "pairing_removed",
            details: [:]
        )
    }

    public static var canonicalRelativePath: String {
        "Application Support/Pairing/\(fileName)"
    }

    private static var directoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pairing", isDirectory: true)
    }

    private static var legacyURLs: [URL] {
        [
            directoryURL.appendingPathComponent(legacyFileName),
            documentsURL,
            URL.documentsDirectory.appendingPathComponent(legacyFileName),
            directoryURL.appendingPathComponent("pairing.plist")
        ]
    }

    private static var documentsURL: URL {
        URL.documentsDirectory.appendingPathComponent(fileName)
    }

    private static func documentSourceURL(fileManager: FileManager) -> URL? {
        [documentsURL, URL.documentsDirectory.appendingPathComponent(legacyFileName)]
            .filter { fileManager.fileExists(atPath: .path) }
            .max {
                let firstDate = (try? .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let secondDate = (try? .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return firstDate < secondDate
            }
    }

    private static func migrateLegacyCopy(to destination: URL, fileManager: FileManager) {
        for legacyURL in legacyURLs where fileManager.fileExists(atPath: legacyURL.path) {
            guard let data = try? Data(contentsOf: legacyURL), validatePairingData(data).isValid else {
                continue
            }
            DeveloperDiagnosticsStore.shared.record(
                category: .bootstrap,
                action: "pairing_legacy_found",
                details: ["source": legacyURL.lastPathComponent]
            )
            do {
                try replaceItem(at: destination, with: legacyURL, fileManager: fileManager)
                protectPairingFile(at: destination, fileManager: fileManager)
                currentSource = .legacyMigration
                DeveloperDiagnosticsStore.shared.record(
                    category: .bootstrap,
                    action: "pairing_migration_success",
                    details: [:]
                )
                break
            } catch {
                if let data = try? Data(contentsOf: legacyURL) {
                    try? data.write(to: destination, options: .atomic)
                    protectPairingFile(at: destination, fileManager: fileManager)
                    currentSource = .legacyMigration
                    DeveloperDiagnosticsStore.shared.record(
                        category: .bootstrap,
                        action: "pairing_migration_success",
                        details: [:]
                    )
                    break
                }
            }
        }
    }

    private static func replaceItem(at destination: URL, with source: URL, fileManager: FileManager) throws {
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".tmp")
        try? fileManager.removeItem(at: temporary)
        try fileManager.copyItem(at: source, to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private static func removeLegacyCopies(fileManager: FileManager) {
        for legacyURL in legacyURLs where fileManager.fileExists(atPath: legacyURL.path) {
            try? fileManager.removeItem(at: legacyURL)
        }
    }

    private static func protectPairingFile(at url: URL, fileManager: FileManager) {
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
