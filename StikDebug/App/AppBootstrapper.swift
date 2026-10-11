//
//  AppBootstrapper.swift
//  StikDebug
//

import Foundation
import ObjectiveC.runtime
import UIKit

enum AppBootstrapper {
    static func configure() {
        registerDefaultSettings()
        applyDocumentPickerCopyWorkaround()
        #if DEBUG && targetEnvironment(simulator)
        // Screenshot fixtures never initialize real transport observation.
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--guide-demo=") }) { return }
        #endif
        Task { @MainActor in ConnectionMonitor.shared.start() }
    }

    private static func registerDefaultSettings() {
        // Register UI preferences at app startup, never during view construction:
        // defaults notifications must not invalidate the view being created.
        S2GridPreferences.registerDefaults(in: .standard)
        UserDefaults.standard.register(defaults: [
            "keepAliveAudio": true,
            "keepAliveLocation": true
        ])
    }

    private static func applyDocumentPickerCopyWorkaround() {
        let fixedSelector = NSSelectorFromString("fix_initForOpeningContentTypes:asCopy:")
        let originalSelector = #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:))

        guard let fixedMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, fixedSelector),
              let originalMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, originalSelector) else {
            return
        }

        method_exchangeImplementations(originalMethod, fixedMethod)
    }
}
