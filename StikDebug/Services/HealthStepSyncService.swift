import Combine
import Foundation
import HealthKit

struct StepAccumulator {
    private(set) var pendingSteps = 0
    private(set) var fractionalSteps = 0.0

    mutating func add(distanceMeters: Double, strideLengthMeters: Double, isRunning: Bool) {
        guard isRunning, distanceMeters > 0, strideLengthMeters > 0 else { return }
        let total = fractionalSteps + distanceMeters / strideLengthMeters
        // Avoid losing a whole step when binary floating-point represents an
        // exact boundary (for example 0.25 + 0.75) just below the integer.
        let whole = Int((total + 1e-9).rounded(.down))
        pendingSteps += whole
        fractionalSteps = max(0, total - Double(whole))
    }

    mutating func takePending() -> Int {
        defer { pendingSteps = 0 }
        return pendingSteps
    }

    mutating func restorePending(_ steps: Int) {
        guard steps > 0 else { return }
        pendingSteps += steps
    }
}

enum HealthStepStatus: Equatable {
    case available, unavailable, authorized, notAuthorized, error(String)
    var label: String {
        switch self {
        case .available: return L10n.text("可用")
        case .unavailable: return L10n.text("不可用")
        case .authorized: return L10n.text("已授權")
        case .notAuthorized: return L10n.text("未授權")
        case .error: return L10n.text("目前的簽名設定不支援 HealthKit，定位功能仍可正常使用。")
        }
    }
}

@MainActor
final class HealthStepSyncService: ObservableObject {
    static let shared = HealthStepSyncService()
    @Published var isEnabled: Bool { didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) } }
    @Published var strideLengthMeters: Double { didSet { if strideLengthMeters > 0 { UserDefaults.standard.set(strideLengthMeters, forKey: Self.strideKey) } } }
    @Published private(set) var status: HealthStepStatus

    private static let enabledKey = "RouteLocation.healthStepSyncEnabled"
    private static let strideKey = "RouteLocation.healthStrideMeters"
    private let store = HKHealthStore()
    private var accumulator = StepAccumulator()
    private var lastDistance: Double?
    private var lastFlush = Date()
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let savedStride = UserDefaults.standard.double(forKey: Self.strideKey)
        strideLengthMeters = savedStride > 0 ? savedStride : 0.80
        status = HKHealthStore.isHealthDataAvailable() ? .available : .unavailable
    }

    func attach(to playback: RoutePlaybackEngine) {
        cancellables.removeAll()
        playback.$traveledDistance.combineLatest(playback.$state)
            .sink { [weak self] distance, state in self?.consume(distance: distance, state: state) }
            .store(in: &cancellables)
    }

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable(), let steps = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            status = .unavailable; return
        }
        do {
            try await store.requestAuthorization(toShare: [steps], read: [])
            status = store.authorizationStatus(for: steps) == .sharingAuthorized ? .authorized : .notAuthorized
        } catch { status = .error(error.localizedDescription) }
    }

    func flush() async {
        guard accumulator.pendingSteps > 0,
              HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.quantityType(forIdentifier: .stepCount) else { return }
        let count = accumulator.takePending()
        let end = Date()
        let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: .count(), doubleValue: Double(count)), start: lastFlush, end: end)
        do {
            try await store.save(sample)
            lastFlush = end
            status = .authorized
        } catch {
            accumulator.restorePending(count)
            status = .error(error.localizedDescription)
            // HealthKit is optional: do not feed this failure back into playback.
        }
    }

    private func consume(distance: Double, state: PlaybackRunState) {
        let previous = lastDistance
        lastDistance = distance
        let playbackActive = state == .running || state == .reconnecting
        guard isEnabled, playbackActive, let previous else {
            if !playbackActive, accumulator.pendingSteps > 0 { Task { await flush() } }
            return
        }
        accumulator.add(distanceMeters: max(0, distance - previous), strideLengthMeters: strideLengthMeters, isRunning: true)
        if Date().timeIntervalSince(lastFlush) >= 30 { Task { await flush() } }
    }
}
