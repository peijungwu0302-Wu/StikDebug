//
//  MountingProgress.swift
//  StikDebug
//

import Foundation
#if !targetEnvironment(simulator)
import idevice
#endif

final class MountingProgress: ObservableObject {
    static let shared = MountingProgress()

    @Published private(set) var mountProgress: Double = 0.0
    @Published private(set) var mountingThread: Thread?
    @Published private(set) var coolisMounted: Bool = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isPreparing = false
    @Published private(set) var isDownloading = false

    private let mountCheckLock = NSLock()
    private var mountCheckInProgress = false
    private let mountAttemptLock = NSLock()
    private var mountAttemptInProgress = false

    private init() {}

    func checkforMounted() {
        guard TunnelManager.shared.isConnected else { return }

        mountCheckLock.lock()
        guard !mountCheckInProgress else {
            mountCheckLock.unlock()
            return
        }
        mountCheckInProgress = true
        mountCheckLock.unlock()

        DispatchQueue.global(qos: .utility).async {
            let mounted = isMounted()

            self.mountCheckLock.lock()
            self.mountCheckInProgress = false
            self.mountCheckLock.unlock()

            DispatchQueue.main.async {
                self.coolisMounted = mounted
            }
        }
    }

    func progressCallback(progress: size_t, total: size_t, context: UnsafeMutableRawPointer?) {
        let percentage = Double(progress) / Double(total) * 100.0
        DispatchQueue.main.async {
            self.mountProgress = percentage
        }
    }

    var isMounting: Bool { isPreparing || isDownloading || mountingThread != nil }

    @MainActor
    func pubMount() {
        guard TunnelManager.shared.isConnected else { return }

        mountAttemptLock.lock()
        guard OptionalDDIReadinessPolicy.shouldStartAttempt(
            isMounted: coolisMounted,
            isMounting: mountAttemptInProgress || isPreparing || isDownloading
        ) else {
            mountAttemptLock.unlock()
            return
        }
        mountAttemptInProgress = true
        mountAttemptLock.unlock()
        isPreparing = true
        lastErrorMessage = nil

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.mount()
        }
    }

    @MainActor
    func beginOptionalDDIDownload() {
        isDownloading = true
    }

    @MainActor
    func finishOptionalDDIDownload() {
        isDownloading = false
    }

    private func mount() {
        let currentlyMounted = isMounted()
        DispatchQueue.main.async {
            self.coolisMounted = currentlyMounted
        }

        guard isPairing(), !currentlyMounted else {
            finishMountAttempt()
            return
        }

        let thread = Thread { [weak self] in
            guard let self else { return }
            let mountError = mountPersonalDDI(
                imagePath: URL.documentsDirectory.appendingPathComponent("DDI/Image.dmg").path,
                trustcachePath: URL.documentsDirectory.appendingPathComponent("DDI/Image.dmg.trustcache").path,
                manifestPath: URL.documentsDirectory.appendingPathComponent("DDI/BuildManifest.plist").path
            )

            DispatchQueue.main.async {
                if let mountError {
                    self.lastErrorMessage = mountError
                    LogManager.shared.addWarningLog("Optional DDI preparation failed: \(mountError)")
                } else {
                    self.lastErrorMessage = nil
                    self.coolisMounted = true
                    self.checkforMounted()
                }
                self.mountingThread = nil
                self.finishMountAttempt()
            }
        }

        thread.qualityOfService = .background
        thread.name = "mounting"
        DispatchQueue.main.async {
            self.mountingThread = thread
            thread.start()
        }
    }

    @MainActor
    func recordOptionalPreparationFailure(_ message: String) {
        lastErrorMessage = message
        LogManager.shared.addWarningLog("Optional DDI download/preparation failed: \(message)")
    }

    private func finishMountAttempt() {
        mountAttemptLock.lock()
        mountAttemptInProgress = false
        mountAttemptLock.unlock()
        DispatchQueue.main.async {
            self.isPreparing = false
            self.mountingThread = nil
        }
    }
}

enum OptionalDDIReadinessPolicy {
    static func shouldStartAttempt(isMounted: Bool, isMounting: Bool) -> Bool {
        !isMounted && !isMounting
    }
}

func isPairing() -> Bool {
#if targetEnvironment(simulator)
    // Simulator tests validate persistence and route logic only. Parsing the
    // device trust record requires the physical-device idevice archive.
    return FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path)
#else
    let pairingPath = PairingFileStore.prepareURL().path
    var pairingFile: RpPairingFileHandle?
    let error = rp_pairing_file_read(pairingPath, &pairingFile)
    if error != nil {
        return false
    }
    rp_pairing_file_free(pairingFile)
    return true
#endif
}
