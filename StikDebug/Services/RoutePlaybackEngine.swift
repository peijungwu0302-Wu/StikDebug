import Combine
import Foundation

enum PlaybackRunState: Equatable {
    case stopped
    case running
    case paused
    case reconnecting
    case completed
    case error(String)

    var label: String {
        switch self {
        case .stopped: return L10n.text("已停止")
        case .running: return L10n.text("模擬中")
        case .paused: return L10n.text("已暫停")
        case .reconnecting: return L10n.text("重新連線中")
        case .completed: return L10n.text("已完成")
        case .error(let message): return L10n.format("錯誤：%@", message)
        }
    }
}

enum PlaybackMath {
    static func metersPerSecond(kmh: Double) -> Double { max(kmh, 0) / 3.6 }
    static func traveledDistance(startingOffset: Double, elapsed: TimeInterval, speedKmh: Double) -> Double {
        max(0, startingOffset) + max(0, elapsed) * metersPerSecond(kmh: speedKmh)
    }
    static func distanceOnRoute(traveled: Double, total: Double, mode: RoutePlaybackMode) -> Double {
        guard total > 0 else { return 0 }
        switch mode {
        case .once: return min(max(traveled, 0), total)
        case .infiniteLoop: return max(traveled, 0).truncatingRemainder(dividingBy: total)
        case .finite(let count):
            let limit = total * Double(min(RoutePlaybackMode.maximumFiniteCount, max(1, count)))
            let value = max(traveled, 0)
            if value >= limit { return total }
            return value.truncatingRemainder(dividingBy: total)
        }
    }
    static func lapNumber(traveled: Double, total: Double) -> Int {
        guard total > 0 else { return 1 }
        return max(1, Int(floor(max(0, traveled) / total)) + 1)
    }

    static func lapNumber(traveled: Double, total: Double, mode: RoutePlaybackMode) -> Int {
        let value = lapNumber(traveled: traveled, total: total)
        guard let limit = mode.finiteCount else { return value }
        return min(value, limit)
    }

    static func completionDistance(total: Double, mode: RoutePlaybackMode) -> Double {
        guard total > 0 else { return 0 }
        guard let count = mode.finiteCount else { return .infinity }
        return total * Double(min(RoutePlaybackMode.maximumFiniteCount, max(1, count)))
    }

    static func isComplete(traveled: Double, total: Double, mode: RoutePlaybackMode) -> Bool {
        let limit = completionDistance(total: total, mode: mode)
        return limit.isFinite && traveled >= limit
    }
}

enum PlaybackReconnectPolicy {
    static func shouldRetry(_ error: Error) -> Bool {
        (error as? LocationSimulationError)?.isRetryable ?? true
    }
}

enum PlaybackSpeedPolicy {
    static let minimum: Double = 0.1
    static let maximum: Double = 300.0

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return minimum }
        return min(max(value, minimum), maximum)
    }

    static func adjusted(_ value: Double, by delta: Double) -> Double {
        clamp((value.isFinite ? value : minimum) + delta)
    }
}

@MainActor
final class RoutePlaybackEngine: ObservableObject {
    @Published private(set) var state: PlaybackRunState = .stopped
    @Published private(set) var routeName = ""
    @Published private(set) var speedKmh: Double = 0
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var traveledDistance: Double = 0
    @Published private(set) var distanceWithinLap: Double = 0
    @Published private(set) var lapNumber = 1
    @Published private(set) var currentCoordinate: RouteCoordinate?
    @Published private(set) var connectionStatus: DeviceSessionStatus = .idle

    let updateInterval: TimeInterval
    private let sink: any LocationSimulationSink
    private let connectionMonitor: ConnectionMonitor
    private let uptime: @Sendable () -> TimeInterval
    private let acquireKeepAlive: @MainActor () -> Void
    private let releaseKeepAlive: @MainActor () -> Void
    private let reconnectAction: @MainActor () -> Void
    private let reconnectDelays: [TimeInterval]
    private let transportDebounce: TimeInterval
    private var task: Task<Void, Never>?
    private var transportHealthTask: Task<Void, Never>?
    private var geometry: RouteGeometry?
    private var mode: RoutePlaybackMode = .once
    private var startTime: TimeInterval = 0
    private var startingOffset: Double = 0
    private var reconnectInProgress = false
    private var lastReconnectError: Error?
    private var lastReconnectWasPermanent = false
    private var consecutiveCommandFailures = 0
    private var pausedOffset: Double = 0
    private var cancellables: Set<AnyCancellable> = []
    @MainActor var assistedRecoveryAction: (@MainActor (_ coordinate: RouteCoordinate?) async -> Bool)?
    private var assistedRecoveryInProgress = false
    private var recoveryGeneration = 0

    init(
        sink: any LocationSimulationSink,
        connectionMonitor: ConnectionMonitor? = nil,
        updateInterval: TimeInterval = 0.5,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        acquireKeepAlive: (@MainActor () -> Void)? = nil,
        releaseKeepAlive: (@MainActor () -> Void)? = nil,
        reconnectAction: (@MainActor () -> Void)? = nil,
        reconnectDelays: [TimeInterval] = [0.5, 1, 2, 4],
        transportDebounce: TimeInterval = 1.5
    ) {
        self.sink = sink
        self.connectionMonitor = connectionMonitor ?? ConnectionMonitor.shared
        self.updateInterval = updateInterval
        self.uptime = uptime
        self.acquireKeepAlive = acquireKeepAlive ?? { BackgroundKeepAliveService.shared.acquire() }
        self.releaseKeepAlive = releaseKeepAlive ?? { BackgroundKeepAliveService.shared.release() }
        self.reconnectAction = reconnectAction ?? {
            markTunnelDisconnected()
            startTunnelInBackground(showErrorUI: false)
        }
        self.reconnectDelays = reconnectDelays
        self.transportDebounce = transportDebounce
        self.connectionMonitor.$transportRevision
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleTransportHealthCheck() }
            .store(in: &cancellables)
    }

    func start(routeName: String, geometry: RouteGeometry, speedKmh: Double, mode: RoutePlaybackMode, startingOffset: Double = 0) async throws {
        stop(clearMarker: false)
        guard geometry.coordinates.count > 1, geometry.totalDistance > 0 else { throw RouteLocationError.emptyGeometry }
        guard speedKmh.isFinite, speedKmh > 0 else { throw RouteLocationError.invalidSpeed }
        self.routeName = routeName
        self.geometry = geometry
        self.speedKmh = PlaybackSpeedPolicy.clamp(speedKmh)
        self.mode = mode
        self.startingOffset = max(0, startingOffset)
        startTime = uptime()
        updateDerivedState(now: startTime)
        guard let coordinate = currentCoordinate else { throw RouteLocationError.emptyGeometry }
        acquireKeepAlive()
        do {
            try await sink.setCoordinate(coordinate)
            consecutiveCommandFailures = 0
            reportConnection(.connected)
        } catch {
            TunnelManager.shared.reportLocationFailure(error, transport: connectionMonitor.currentTransport)
            guard PlaybackReconnectPolicy.shouldRetry(error) else {
                releaseKeepAlive()
                throw error
            }
            guard await reconnect() else {
                releaseKeepAlive()
                throw lastReconnectError ?? error
            }
        }
        state = .running
        task = Task { [weak self] in await self?.runLoop() }
    }

    func stop(clearMarker: Bool = true) {
        recoveryGeneration &+= 1
        task?.cancel()
        task = nil
        transportHealthTask?.cancel()
        transportHealthTask = nil
        reconnectInProgress = false
        assistedRecoveryInProgress = false
        lastReconnectError = nil
        lastReconnectWasPermanent = false
        state = .stopped
        reportConnection(.idle)
        releaseKeepAlive()
        if clearMarker { currentCoordinate = nil }
    }

    func clearAndStop() async throws {
        stop()
        try await sink.clearSimulatedLocation()
    }

    /// Whether the playback engine is in a state that can be paused (only .running)
    var canPause: Bool {
        state == .running
    }

    /// Pause route progression. Keeps the last simulated coordinate active and keep-alive acquired.
    /// Does NOT trigger DVT/tunnel reconnect or restore real location.
    func pause() {
        guard canPause else { return }
        task?.cancel()
        task = nil
        transportHealthTask?.cancel()
        transportHealthTask = nil
        pausedOffset = traveledDistance
        state = .paused
    }

    /// Resume route from the paused offset. Does NOT trigger DVT/tunnel rebuild.
    func resume() async {
        guard state == .paused, let geometry else { return }
        startingOffset = pausedOffset
        startTime = uptime()
        state = .running
        task = Task { [weak self] in await self?.runLoop() }
    }

    /// Changes playback speed without changing the current route distance.
    /// The clock is rebased at the exact current distance so the next tick
    /// continues smoothly instead of jumping by the old/new speed delta.
    func setSpeed(_ newSpeed: Double) throws {
        guard newSpeed.isFinite, newSpeed > 0 else { throw RouteLocationError.invalidSpeed }
        guard state != .reconnecting else { throw RouteLocationError.speedChangeUnavailableDuringRecovery }
        let now = uptime()
        let currentDistance: Double
        switch state {
        case .running:
            updateDerivedState(now: now)
            currentDistance = traveledDistance
        case .paused:
            currentDistance = pausedOffset
        default:
            currentDistance = startingOffset
        }
        speedKmh = PlaybackSpeedPolicy.clamp(newSpeed)
        startingOffset = currentDistance
        pausedOffset = currentDistance
        startTime = now
        if state != .stopped { updateDerivedState(now: now) }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(updateInterval)) } catch { return }
            guard !Task.isCancelled else { return }
            let generation = recoveryGeneration
            updateDerivedState(now: uptime())
            guard let coordinate = currentCoordinate else { return }
            do {
                try await sink.setCoordinate(coordinate)
                guard recoveryGeneration == generation, !Task.isCancelled else { return }
                consecutiveCommandFailures = 0
                reportConnection(.connected)
                state = .running
            } catch {
                consecutiveCommandFailures += 1
                TunnelManager.shared.reportLocationFailure(error, transport: connectionMonitor.currentTransport)
                guard PlaybackReconnectPolicy.shouldRetry(error) else {
                    state = .error(error.localizedDescription)
                    reportConnection(.error(error.localizedDescription))
                    task = nil
                    releaseKeepAlive()
                    return
                }
                guard LocationRecoveryPolicy.shouldRecover(consecutiveFailures: consecutiveCommandFailures) else {
                    state = .running
                    continue
                }
                let recovered = await reconnect()
                if !recovered {
                    guard state != .stopped else { return }
                    handleReconnectFailure()
                    return
                }
            }
            if PlaybackMath.isComplete(traveled: traveledDistance, total: geometry?.totalDistance ?? 0, mode: mode) {
                state = .completed
                task = nil
                releaseKeepAlive()
                return
            }
        }
    }

    private func reconnect(returnState: PlaybackRunState = .running) async -> Bool {
        guard !reconnectInProgress else { return false }
        let generation = recoveryGeneration
        reconnectInProgress = true
        lastReconnectError = nil
        lastReconnectWasPermanent = false
        defer { reconnectInProgress = false }
        state = .reconnecting
        // Level 1: a retained/prepared session may only need one command
        // retry. This avoids toggling cellular data for transient writes.
        if let currentCoordinate {
            do {
                try await sink.setCoordinate(currentCoordinate)
                guard recoveryGeneration == generation, !Task.isCancelled else { return false }
                consecutiveCommandFailures = 0
                state = returnState
                reportConnection(.connected)
                return true
            } catch {
                lastReconnectError = error
            }
        }
        // Level 2: bounded normal transport/tunnel reconnect. This path never
        // toggles cellular data and must be exhausted before requesting the
        // user-consented Level 3 Assisted recovery.
        for (index, delay) in reconnectDelays.enumerated() {
            guard recoveryGeneration == generation, !Task.isCancelled else { return false }
            reportConnection(.reconnecting(attempt: index + 1))
            reconnectAction()
            do { try await Task.sleep(for: .seconds(delay)) } catch { return false }
            guard recoveryGeneration == generation, !Task.isCancelled else { return false }
            if returnState != .paused {
                updateDerivedState(now: uptime())
            }
            guard let currentCoordinate else { return false }
            do {
                try await sink.setCoordinate(currentCoordinate)
                guard recoveryGeneration == generation, !Task.isCancelled else { return false }
                consecutiveCommandFailures = 0
                state = returnState
                reportConnection(.connected)
                return true
            } catch {
                lastReconnectError = error
                TunnelManager.shared.reportLocationFailure(error, transport: connectionMonitor.currentTransport)
                guard PlaybackReconnectPolicy.shouldRetry(error) else {
                    lastReconnectWasPermanent = true
                    return false
                }
                continue
            }
        }

        // Level 3: cellular Assisted recovery. It owns DataOff/DataOn and the
        // first-location-write validation. If it succeeds, return directly;
        // never run the legacy reconnect loop a second time afterward.
        if connectionMonitor.currentTransport == .cellular,
           let assistedRecoveryAction,
           !assistedRecoveryInProgress {
            if returnState != .paused {
                updateDerivedState(now: uptime())
            }
            let assistedRecoveryDistance = returnState == .paused ? pausedOffset : traveledDistance
            startingOffset = assistedRecoveryDistance
            startTime = uptime()
            assistedRecoveryInProgress = true
            let recovered = await assistedRecoveryAction(currentCoordinate)
            assistedRecoveryInProgress = false
            guard recoveryGeneration == generation, !Task.isCancelled else { return false }
            guard recovered else {
                lastReconnectWasPermanent = false
                return false
            }
            startingOffset = assistedRecoveryDistance
            pausedOffset = assistedRecoveryDistance
            startTime = uptime()
            updateDerivedState(now: startTime)
            state = returnState
            reportConnection(.connected)
            consecutiveCommandFailures = 0
            return true
        }
        return false
    }

    private func enterWaitingForConnection() {
        let detail = lastReconnectError?.localizedDescription
            ?? L10n.text("裝置通道暫時無法使用；播放時間已保留，網路恢復時會再檢查。")
        state = .error(detail)
        reportConnection(.error(detail))
        task = nil
    }

    private func handleReconnectFailure() {
        guard lastReconnectWasPermanent else {
            enterWaitingForConnection()
            return
        }
        let detail = lastReconnectError?.localizedDescription ?? L10n.text("裝置連線設定無效。")
        state = .error(detail)
        reportConnection(.error(detail))
        task = nil
        releaseKeepAlive()
    }

    private func scheduleTransportHealthCheck() {
        guard geometry != nil, state == .running || state == .paused || state == .reconnecting || isWaitingForConnection else { return }
        transportHealthTask?.cancel()
        transportHealthTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(transportDebounce)) } catch { return }
            await self.verifyConnectionAfterTransportChange()
        }
    }

    private var isWaitingForConnection: Bool {
        if case .error = state { return task == nil && geometry != nil }
        return false
    }

    func verifyConnectionAfterTransportChange() async {
        guard geometry != nil, !reconnectInProgress, state != .stopped else { return }
        let generation = recoveryGeneration
        let isPaused = (state == .paused)
        if !isPaused {
            updateDerivedState(now: uptime())
        }
        guard let currentCoordinate else { return }
        do {
            try await sink.setCoordinate(currentCoordinate)
            guard recoveryGeneration == generation, !Task.isCancelled else { return }
            consecutiveCommandFailures = 0
            reportConnection(.connected)
            state = isPaused ? .paused : .running
            if !isPaused && task == nil { task = Task { [weak self] in await self?.runLoop() } }
        } catch {
            consecutiveCommandFailures += 1
            TunnelManager.shared.reportLocationFailure(error, transport: connectionMonitor.currentTransport)
            guard PlaybackReconnectPolicy.shouldRetry(error) else {
                state = .error(error.localizedDescription)
                reportConnection(.error(error.localizedDescription))
                return
            }
            guard LocationRecoveryPolicy.shouldRecover(consecutiveFailures: consecutiveCommandFailures), !reconnectInProgress else {
                state = isPaused ? .paused : .running
                return
            }
            if await reconnect(returnState: isPaused ? .paused : .running) {
                if !isPaused && task == nil { task = Task { [weak self] in await self?.runLoop() } }
            } else {
                guard state != .stopped else { return }
                handleReconnectFailure()
            }
        }
    }

    private func updateDerivedState(now: TimeInterval) {
        guard let geometry else { return }
        elapsedTime = max(0, now - startTime)
        traveledDistance = PlaybackMath.traveledDistance(startingOffset: startingOffset, elapsed: elapsedTime, speedKmh: speedKmh)
        distanceWithinLap = PlaybackMath.distanceOnRoute(traveled: traveledDistance, total: geometry.totalDistance, mode: mode)
        lapNumber = PlaybackMath.lapNumber(traveled: traveledDistance, total: geometry.totalDistance, mode: mode)
        currentCoordinate = geometry.coordinate(atDistance: distanceWithinLap).map(RouteCoordinate.init)
    }

    private func reportConnection(_ status: DeviceSessionStatus) {
        connectionStatus = status
        connectionMonitor.reportSession(status)
    }

    #if DEBUG
    func testSetStateForTesting(_ newState: PlaybackRunState) {
        state = newState
    }
    #endif
}

enum RouteLocationError: LocalizedError, Equatable {
    case insufficientWaypoints
    case emptyGeometry
    case invalidSpeed
    case speedChangeUnavailableDuringRecovery
    case navigationNeedsRecalculation
    case loopRequiresClosedRoute

    var errorDescription: String? {
        switch self {
        case .insufficientWaypoints: return L10n.text("請至少加入兩個航點。")
        case .emptyGeometry: return L10n.text("這條路線沒有可播放的幾何資料。")
        case .invalidSpeed: return L10n.text("請輸入大於 0 km/h 的速度。")
        case .speedChangeUnavailableDuringRecovery: return L10n.text("重新連線期間暫停調整速度，連線恢復後即可繼續。")
        case .navigationNeedsRecalculation: return L10n.text("導航路線已變更，請先重新計算再儲存或播放。")
        case .loopRequiresClosedRoute: return L10n.text("無限循環需要封閉路線，才能沿著實際路徑回到起點。")
        }
    }
}
