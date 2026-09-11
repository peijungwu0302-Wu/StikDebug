//
//  DeveloperDiskImageService.swift
//  StikDebug
//

import Foundation

final class DeveloperDiskImageService {
    static let shared = DeveloperDiskImageService()

    private let fileManager: FileManager
    private let session: URLSession

    init(fileManager: FileManager = .default, session: URLSession = .shared) {
        self.fileManager = fileManager
        self.session = session
    }

    func downloadMissingFiles() async throws {
        for item in Self.downloadItems {
            let destinationURL = URL.documentsDirectory.appendingPathComponent(item.relativePath)
            guard !fileManager.fileExists(atPath: destinationURL.path) else {
                continue
            }
            try await downloadFile(from: item.urlString, to: destinationURL)
        }
    }

    func downloadFile(from urlString: String, to destinationURL: URL) async throws {
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "https" else {
            throw DDIDownloadError.invalidURL(urlString)
        }

        let (temporaryURL, response) = try await session.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DDIDownloadError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DDIDownloadError.badStatus(httpResponse.statusCode)
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    func redownload(progressHandler: ((Double, String) -> Void)? = nil) async throws {
        let totalStages = Double(Self.downloadItems.count + 1)
        var completedStages = 0.0

        progressHandler?(0.0, L10n.text("正在移除現有 DDI 檔案…"))
        for item in Self.downloadItems {
            let fileURL = URL.documentsDirectory.appendingPathComponent(item.relativePath)
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        }

        completedStages += 1.0
        progressHandler?(completedStages / totalStages, L10n.text("準備開始下載…"))

        for item in Self.downloadItems {
            progressHandler?(completedStages / totalStages, L10n.format("正在下載%@…", item.name))
            let destinationURL = URL.documentsDirectory.appendingPathComponent(item.relativePath)
            try await downloadFile(from: item.urlString, to: destinationURL)
            completedStages += 1.0
            progressHandler?(completedStages / totalStages, L10n.format("%@已準備完成", item.name))
        }

        progressHandler?(1.0, L10n.text("DDI 下載完成。"))
    }

    private static let downloadItems: [DDIDownloadItem] = [
        .init(
            name: L10n.text("建置資訊檔"),
            relativePath: "DDI/BuildManifest.plist",
            urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/BuildManifest.plist"
        ),
        .init(
            name: L10n.text("磁碟映像"),
            relativePath: "DDI/Image.dmg",
            urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg"
        ),
        .init(
            name: L10n.text("信任快取"),
            relativePath: "DDI/Image.dmg.trustcache",
            urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg.trustcache"
        )
    ]
}

private struct DDIDownloadItem {
    let name: String
    let relativePath: String
    let urlString: String
}

enum DDIDownloadError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let string):
            return L10n.format("下載網址無效：%@", string)
        case .invalidResponse:
            return L10n.text("DDI 伺服器傳回無效回應。")
        case .badStatus(let statusCode):
            return L10n.format("DDI 伺服器傳回 HTTP %d。", statusCode)
        }
    }
}

func redownloadDDI(progressHandler: ((Double, String) -> Void)? = nil) async throws {
    try await DeveloperDiskImageService.shared.redownload(progressHandler: progressHandler)
}
