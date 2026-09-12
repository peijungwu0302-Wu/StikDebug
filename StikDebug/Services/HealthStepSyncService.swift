import Combine
import Foundation
import HealthKit

struct StepAccumulator {
    private(set) var pendingSteps = 0
    private(set) var fractionalSteps = 0.0

    mutating func addDistance(distanceMeters: Double, strideLengthMeters: Double, isRunning: Bool) {
        guard isRunning, distanceMeters > 0, strideLengthMeters > 0 else { return }
        let total = fractionalSteps + distanceMeters / strideLengthMeters
        let whole = Int((total + 1e-9).rounded(.down))
        pendingSteps += whole
        fractionalSteps = max(0, total - Double(whole))
    }

    mutating func add(distanceMeters: Double, strideLengthMeters: Double, isRunning: Bool) {
        addDistance(distanceMeters: distanceMeters, strideLengthMeters: strideLengthMeters, isRunning: isRunning)
    }

    mutating func addCadence(elapsedSeconds: Double, cadencePerMinute: Double, isRunning: Bool) {
        guard isRunning, elapsedSeconds > 0, cadencePerMinute > 0 else { return }
        let total = fractionalSteps + (cadencePerMinute * (elapsedSeconds / 60.0))
        let whole = Int((total + 1e-9).rounded(.down))
        pendingSteps += whole
        fractionalSteps = max(0, total - Double(whole))
    }

    mutating func addDirect(_ count: Int) {
        guard count > 0 else { return }
        pendingSteps += count
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

enum HealthAuthorizationState: Equatable {
    case notDetermined
    case sharingAuthorized
    case sharingDenied
    case unavailable
    case unknown

    var label: String {
        switch self {
        case .notDetermined: return L10n.text("未要求")
        case .sharingAuthorized: return L10n.text("可寫入")
        case .sharingDenied: return L10n.text("拒絕")
        case .unavailable: return L10n.text("不可用")
        case .unknown: return L10n.text("狀態未知")
        }
    }
}

struct HealthKitLastError: Error, Equatable {
    let domain: String
    let code: Int
    let localizedDescription: String

    var formattedDetails: String {
        "\(domain) (\(code)): \(localizedDescription)"
    }
}

enum HealthKitLastWriteStatus: Equatable {
    case none
    case success(steps: Int, date: Date)
    case failure(error: HealthKitLastError, date: Date)

    var label: String {
        switch self {
        case .none:
            return L10n.text("尚未寫入")
        case .success(let steps, _):
            return L10n.format("成功（%d 步）", steps)
        case .failure(let error, _):
            return L10n.format("失敗（代碼 %d）", error.code)
        }
    }
}

@MainActor
final class HealthStepSyncService: ObservableObject {
    static let shared = HealthStepSyncService()

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    @Published var calculationMode: StepCalculationMode {
        didSet { UserDefaults.standard.set(calculationMode.rawValue, forKey: Self.modeKey) }
    }
    @Published var cadenceStepsPerMinute: Double {
        didSet {
            if cadenceStepsPerMinute > 0 {
                UserDefaults.standard.set(cadenceStepsPerMinute, forKey: Self.cadenceKey)
            }
        }
    }
    @Published var strideLengthMeters: Double {
        didSet {
            if strideLengthMeters > 0 {
                UserDefaults.standard.set(strideLengthMeters, forKey: Self.strideKey)
            }
        }
    }

    @Published private(set) var isHealthDataAvailable: Bool
    @Published private(set) var authorizationState: HealthAuthorizationState
    @Published private(set) var lastWriteStatus: HealthKitLastWriteStatus = .none
    @Published private(set) var lastError: HealthKitLastError?

    private static let enabledKey = "RouteLocation.healthStepSyncEnabled"
    private static let modeKey = "RouteLocation.stepCalculationMode"
    private static let cadenceKey = "RouteLocation.healthCadenceStepsPerMinute"
    private static let strideKey = "RouteLocation.healthStrideMeters"

    private let store = HKHealthStore()
    private var accumulator = StepAccumulator()
    private var lastActiveDistance: Double?
    private var lastActiveElapsedTime: Double?
    private var lastFlush = Date()
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)

        let savedStride = UserDefaults.standard.double(forKey: Self.strideKey)
        strideLengthMeters = savedStride > 0 ? savedStride : 0.80

        let savedCadence = UserDefaults.standard.double(forKey: Self.cadenceKey)
        cadenceStepsPerMinute = savedCadence > 0 ? savedCadence : 160

        if let savedModeRaw = UserDefaults.standard.string(forKey: Self.modeKey),
           let savedMode = StepCalculationMode(rawValue: savedModeRaw) {
            calculationMode = savedMode
        } else if UserDefaults.standard.object(forKey: Self.strideKey) != nil {
            calculationMode = .distance
        } else {
            calculationMode = .fixedCadence
        }

        let available = HKHealthStore.isHealthDataAvailable()
        isHealthDataAvailable = available
        if !available {
            authorizationState = .unavailable
        } else if let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) {
            switch store.authorizationStatus(for: stepType) {
            case .notDetermined: authorizationState = .notDetermined
            case .sharingAuthorized: authorizationState = .sharingAuthorized
            case .sharingDenied: authorizationState = .sharingDenied
            @unknown default: authorizationState = .unknown
            }
        } else {
            authorizationState = .unavailable
        }
    }

    func attach(to playback: RoutePlaybackEngine) {
        cancellables.removeAll()
        Publishers.CombineLatest3(playback.$traveledDistance, playback.$elapsedTime, playback.$state)
            .sink { [weak self] distance, elapsed, state in
                self?.consume(distance: distance, elapsed: elapsed, state: state)
            }
            .store(in: &cancellables)
    }

    func refreshAuthorizationStatus() {
        guard isHealthDataAvailable, let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            authorizationState = .unavailable
            return
        }
        switch store.authorizationStatus(for: stepType) {
        case .notDetermined: authorizationState = .notDetermined
        case .sharingAuthorized: authorizationState = .sharingAuthorized
        case .sharingDenied: authorizationState = .sharingDenied
        @unknown default: authorizationState = .unknown
        }
    }

    func requestAuthorization() async {
        guard isHealthDataAvailable, let steps = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            authorizationState = .unavailable
            return
        }
        do {
            try await store.requestAuthorization(toShare: [steps], read: [])
            refreshAuthorizationStatus()
        } catch {
            let nsError = error as NSError
            lastError = HealthKitLastError(
                domain: nsError.domain,
                code: nsError.code,
                localizedDescription: error.localizedDescription
            )
            refreshAuthorizationStatus()
        }
    }

    func flush() async {
        guard accumulator.pendingSteps > 0,
              isHealthDataAvailable,
              let type = HKObjectType.quantityType(forIdentifier: .stepCount) else { return }
        let count = accumulator.takePending()
        let end = Date()
        let start = lastFlush
        let sample = HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: .count(), doubleValue: Double(count)),
            start: start,
            end: end
        )
        do {
            try await store.save(sample)
            lastFlush = end
            lastWriteStatus = .success(steps: count, date: end)
            lastError = nil
            refreshAuthorizationStatus()
        } catch {
            accumulator.restorePending(count)
            let nsError = error as NSError
            let hkError = HealthKitLastError(
                domain: nsError.domain,
                code: nsError.code,
                localizedDescription: error.localizedDescription
            )
            lastError = hkError
            lastWriteStatus = .failure(error: hkError, date: end)
            refreshAuthorizationStatus()
        }
    }

    func testWriteTenSteps() async -> Result<String, HealthKitLastError> {
        guard isHealthDataAvailable, let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            let err = HealthKitLastError(
                domain: "com.apple.healthkit",
                code: -1,
                localizedDescription: L10n.text("HealthKit 在此裝置上不可用。")
            )
            lastError = err
            return .failure(err)
        }
        if authorizationState == .notDetermined {
            await requestAuthorization()
        }
        let now = Date()
        let start = now.addingTimeInterval(-10)
        let sample = HKQuantitySample(
            type: stepType,
            quantity: HKQuantity(unit: .count(), doubleValue: 10),
            start: start,
            end: now
        )
        do {
            try await store.save(sample)
            lastWriteStatus = .success(steps: 10, date: now)
            lastError = nil
            refreshAuthorizationStatus()
            return .success(L10n.text("測試成功：已由 RouteLocation 寫入 10 步"))
        } catch {
            let nsError = error as NSError
            let hkError = HealthKitLastError(
                domain: nsError.domain,
                code: nsError.code,
                localizedDescription: error.localizedDescription
            )
            lastError = hkError
            lastWriteStatus = .failure(error: hkError, date: now)
            refreshAuthorizationStatus()
            return .failure(hkError)
        }
    }

    func manualAddSteps(_ count: Int) async -> Result<String, HealthKitLastError> {
        guard count > 0 else {
            let err = HealthKitLastError(
                domain: "com.routelocation.health",
                code: -2,
                localizedDescription: L10n.text("請輸入大於 0 的有效步數。")
            )
            return .failure(err)
        }
        guard isHealthDataAvailable, let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            let err = HealthKitLastError(
                domain: "com.apple.healthkit",
                code: -1,
                localizedDescription: L10n.text("HealthKit 在此裝置上不可用。")
            )
            lastError = err
            return .failure(err)
        }
        if authorizationState == .notDetermined {
            await requestAuthorization()
        }
        let now = Date()
        let duration = max(Double(count) * 0.4, 1.0)
        let start = now.addingTimeInterval(-duration)
        let sample = HKQuantitySample(
            type: stepType,
            quantity: HKQuantity(unit: .count(), doubleValue: Double(count)),
            start: start,
            end: now
        )
        do {
            try await store.save(sample)
            lastWriteStatus = .success(steps: count, date: now)
            lastError = nil
            refreshAuthorizationStatus()
            return .success(L10n.format("已由 RouteLocation 新增 %d 步至 Apple 健康。", count))
        } catch {
            let nsError = error as NSError
            let hkError = HealthKitLastError(
                domain: nsError.domain,
                code: nsError.code,
                localizedDescription: error.localizedDescription
            )
            lastError = hkError
            lastWriteStatus = .failure(error: hkError, date: now)
            refreshAuthorizationStatus()
            return .failure(hkError)
        }
    }

    private func consume(distance: Double, elapsed: TimeInterval, state: PlaybackRunState) {
        let isPlaybackActive = state == .running || state == .reconnecting
        guard isEnabled, isPlaybackActive else {
            if !isPlaybackActive {
                lastActiveDistance = nil
                lastActiveElapsedTime = nil
                if accumulator.pendingSteps > 0 {
                    Task { await flush() }
                }
            }
            return
        }

        switch calculationMode {
        case .fixedCadence:
            if let prevElapsed = lastActiveElapsedTime {
                let deltaElapsed = max(0, elapsed - prevElapsed)
                accumulator.addCadence(
                    elapsedSeconds: deltaElapsed,
                    cadencePerMinute: cadenceStepsPerMinute,
                    isRunning: true
                )
            }
            lastActiveElapsedTime = elapsed

        case .distance:
            if let prevDistance = lastActiveDistance {
                let deltaDistance = max(0, distance - prevDistance)
                accumulator.addDistance(
                    distanceMeters: deltaDistance,
                    strideLengthMeters: strideLengthMeters,
                    isRunning: true
                )
            }
            lastActiveDistance = distance
        }

        if Date().timeIntervalSince(lastFlush) >= 30 {
            Task { await flush() }
        }
    }
}
