import SwiftUI

struct SetupDiagnosticsView: View {
    @EnvironmentObject private var model: RouteLocationModel
    @EnvironmentObject private var playback: RoutePlaybackEngine
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mounting = MountingProgress.shared
    @ObservedObject private var backgroundLocation = BackgroundLocationManager.shared
    @State private var showPairingImporter = false
    @State private var importStatus: String?
    @State private var pairingState = "Checking"

    private var pairingPresent: Bool { FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path) }

    var body: some View {
        NavigationStack {
            List {
                Section("Setup Status") {
                    status("Pairing File", pairingState, pairingState == "Present" ? .green : .orange)
                    status("Device Tunnel", tunnelStatus, tunnel.isConnected ? .green : .orange)
                    status("Developer Disk Image", ddiStatus, mounting.coolisMounted ? .green : .orange)
                    status("Location Simulation", playback.state.label, playback.state == .running ? .green : .gray)
                    status("DVT Session", model.connectionMonitor.deviceSession.label, .gray)
                    status("Network", model.connectionMonitor.networkInterface.rawValue, model.connectionMonitor.internetReachable ? .green : .orange)
                    status("Internet Reachability", model.connectionMonitor.internetReachable ? "Reachable path" : "Offline", model.connectionMonitor.internetReachable ? .green : .orange)
                    status("VPN Interface", model.connectionMonitor.usesVPNInterface ? "Detected" : "Not detected", .gray)
                }
                Section("Pairing File") {
                    Text("A pairing file is a sensitive device-trust credential. Keep it private; RouteLocation stores it locally and never uploads its contents.")
                        .font(.footnote)
                    Button(pairingPresent ? "Replace Pairing File" : "Import Pairing File") { showPairingImporter = true }
                    if let importStatus { Text(importStatus).font(.footnote).foregroundStyle(.secondary) }
                }
                Section("Connection") {
                    Button("Retry Device Tunnel") { startTunnelInBackground() }
                    Button("Check / Mount DDI") { MountingProgress.shared.pubMount() }
                    Text("Start LocalDevVPN, keep the device awake and unlocked during setup, and confirm the pairing file belongs to this iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Background Playback") {
                    Text(backgroundGuidance).font(.footnote)
                    Text("Background execution is best-effort. Force-quitting RouteLocation, rebooting, iOS process termination, or a system-level failure stops playback.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Privacy") {
                    Text("No account, analytics, telemetry, backend, CloudKit, or route uploads. Apple services are contacted only for MapKit tiles, searches, and navigation calculations you request.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Setup & Settings")
        }
        .fileImporter(isPresented: $showPairingImporter, allowedContentTypes: PairingFileStore.supportedContentTypes) { result in
            do {
                let url = try result.get()
                try PairingFileStore.importFromPicker(url)
                importStatus = "Imported successfully."
                NotificationCenter.default.post(name: .pairingFileImported, object: nil)
                startTunnelInBackground()
                refreshPairingState()
            } catch { importStatus = "Import failed: \(error.localizedDescription)" }
        }
        .task { refreshPairingState() }
    }

    private var ddiStatus: String {
        if mounting.coolisMounted { return "Mounted" }
        if mounting.mountingThread != nil { return "Preparing" }
        if let error = mounting.lastErrorMessage { return "Error: \(error)" }
        return "Not Mounted"
    }

    private var tunnelStatus: String {
        if tunnel.isConnected { return "Connected" }
        if tunnel.isStarting { return "Connecting" }
        if let error = tunnel.lastErrorMessage { return "Error: \(error)" }
        return "Disconnected"
    }

    private func refreshPairingState() {
        guard pairingPresent else { pairingState = "Missing"; return }
        pairingState = "Checking"
        Task.detached {
            let valid = isPairing()
            await MainActor.run { pairingState = valid ? "Present" : "Invalid / Error" }
        }
    }

    private var backgroundGuidance: String {
        switch backgroundLocation.authorizationStatus {
        case .authorizedAlways: return "Always location access is enabled. Playback acquires silent-audio, low-accuracy location, and background-task keep-alives only while active."
        case .authorizedWhenInUse: return "Set Location access to Always for the strongest best-effort background playback."
        case .denied, .restricted: return "Background location access is unavailable; playback may be suspended after switching apps."
        case .notDetermined: return "Starting playback requests location access needed for best-effort background operation."
        @unknown default: return "Check Location access in iOS Settings."
        }
    }

    private func status(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack { Text(title); Spacer(); Circle().fill(color).frame(width: 8, height: 8); Text(value).foregroundStyle(.secondary) }
    }
}
