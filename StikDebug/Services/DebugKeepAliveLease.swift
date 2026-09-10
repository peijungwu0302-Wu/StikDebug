//
//  DebugKeepAliveLease.swift
//  StikDebug
//

import Foundation
import UIKit

final class DebugKeepAliveLease {
    private let stateLock = NSLock()
    private var isActive = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init() {
        activate()
    }

    func invalidate() {
        stateLock.lock()
        guard isActive else {
            stateLock.unlock()
            return
        }
        isActive = false
        stateLock.unlock()

        runOnMain {
            BackgroundAudioManager.shared.requestStop(force: true)
            BackgroundLocationManager.shared.requestStop(force: true)
            self.endBackgroundTask()
        }
    }

    private func activate() {
        stateLock.lock()
        guard !isActive else {
            stateLock.unlock()
            return
        }
        isActive = true
        stateLock.unlock()

        runOnMain {
            BackgroundAudioManager.shared.requestStart(force: true)
            BackgroundLocationManager.shared.requestStart(force: true)
            self.beginBackgroundTask()
        }
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "RouteLocationPlayback") { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let active = self.isActive
            self.stateLock.unlock()
            if active { self.beginBackgroundTask() } else { self.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }
}
