import Combine
import Foundation

enum PlaybackRunState: Equatable {
    case stopped
    case running
    case reconnecting
    case completed
    case error(String)

    var label: String {
        switch self {
        case .stopped: return L10n.text("已停止")
        case .running: return L10n.text("模擬中")
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
        }
    }
    static func lapNumber(traveled: Double, total: Double) -> Int {
        guard total > 0 else { return 1 }
        return max(1, Int(floor(max(0, traveled) / total)) + 1)
    }
}

enum PlaybackReconnectPolicy {
    static func shouldRetry(_ error: Error) -> Bool {
        (error as? LocationSimulationError)?.isRetryable ?? true
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
    private var cancellables: Set<AnyCancellable> = []

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
        self.speedKmh = speedKmh
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
        task?.cancel()
        task = nil
        transportHealthTask?.cancel()
        transportHealthTask = nil
        reconnectInProgress = false
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

    private func runLoop() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(updateInterval)) } catch { return }
            guard !Task.isCancelled else { return }
            updateDerivedState(now: uptime())
            guard let coordinate = currentCoordinate else { return }
            do {
                try await sink.setCoordinate(coordinate)
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
                    handleReconnectFailure()
                    return
                }
            }
            if mode == .once, traveledDistance >= (geometry?.totalDistance ?? .infinity) {
                state = .completed
                task = nil
                releaseKeepAlive()
                return
            }
        }
    }

    private func reconnect() async -> Bool {
        guard !reconnectInProgress else { return false }
        reconnectInProgress = true
        lastReconnectError = nil
        lastReconnectWasPermanent = false
        defer { reconnectInProgress = false }
        state = .reconnecting
        for (index, delay) in reconnectDelays.enumerated() {
            guard !Task.isCancelled else { return false }
            reportConnection(.reconnecting(attempt: index + 1))
            reconnectAction()
            do { try await Task.sleep(for: .seconds(delay)) } catch { return false }
            updateDerivedState(now: uptime())
            guard let currentCoordinate else { return false }
            do {
                try await sink.setCoordinate(currentCoordinate)
                consecutiveCommandFailures = 0
                state = .running
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
        guard geometry != nil, state == .running || state == .reconnecting || isWaitingForConnection else { return }
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
        guard geometry != nil, !reconnectInProgress else { return }
        updateDerivedState(now: uptime())
        guard let currentCoordinate else { return }
        do {
            try await sink.setCoordinate(currentCoordinate)
            consecutiveCommandFailures = 0
            reportConnection(.connected)
            state = .running
            if task == nil { task = Task { [weak self] in await self?.runLoop() } }
        } catch {
            consecutiveCommandFailures += 1
            TunnelManager.shared.reportLocationFailure(error, transport: connectionMonitor.currentTransport)
            guard PlaybackReconnectPolicy.shouldRetry(error) else {
                state = .error(error.localizedDescription)
                reportConnection(.error(error.localizedDescription))
                return
            }
            guard LocationRecoveryPolicy.shouldRecover(consecutiveFailures: consecutiveCommandFailures), !reconnectInProgress else {
                state = .running
                return
            }
            if await reconnect() {
                if task == nil { task = Task { [weak self] in await self?.runLoop() } }
            } else {
                handleReconnectFailure()
            }
        }
    }

    private func updateDerivedState(now: TimeInterval) {
        guard let geometry else { return }
        elapsedTime = max(0, now - startTime)
        traveledDistance = PlaybackMath.traveledDistance(startingOffset: startingOffset, elapsed: elapsedTime, speedKmh: speedKmh)
        distanceWithinLap = PlaybackMath.distanceOnRoute(traveled: traveledDistance, total: geometry.totalDistance, mode: mode)
        lapNumber = PlaybackMath.lapNumber(traveled: traveledDistance, total: geometry.totalDistance)
        currentCoordinate = geometry.coordinate(atDistance: distanceWithinLap).map(RouteCoordinate.init)
    }

    private func reportConnection(_ status: DeviceSessionStatus) {
        connectionStatus = status
        connectionMonitor.reportSession(status)
    }
}

enum RouteLocationError: LocalizedError {
    case insufficientWaypoints
    case emptyGeometry
    case invalidSpeed
    case navigationNeedsRecalculation
    case loopRequiresClosedRoute

    var errorDescription: String? {
        switch self {
        case .insufficientWaypoints: return L10n.text("請至少加入兩個航點。")
        case .emptyGeometry: return L10n.text("這條路線沒有可播放的幾何資料。")
        case .invalidSpeed: return L10n.text("請輸入大於 0 km/h 的速度。")
        case .navigationNeedsRecalculation: return L10n.text("導航路線已變更，請先重新計算再儲存或播放。")
        case .loopRequiresClosedRoute: return L10n.text("無限循環需要封閉路線，才能沿著實際路徑回到起點。")
        }
    }
}
