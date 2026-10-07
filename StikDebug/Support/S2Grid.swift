import Foundation
import MapKit
import SwiftUI

/// Small, isolated S2 cell implementation for map visualization only.
/// Projection, face orientation, and CellID encoding are adapted from Google's
/// public S2 specification/reference implementation (Apache-2.0); no external
/// library is linked. No location, route, or playback service imports this file.
struct S2GridCoordinate: Hashable, Sendable {
    let latitude: Double
    let longitude: Double
}

struct S2GridCell: Identifiable, Hashable, Sendable {
    let id: UInt64
    let face: Int
    let level: Int
    let vertices: [S2GridCoordinate]

    var token: String {
        String(id, radix: 16).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }

    func parentID(at targetLevel: Int) -> UInt64? {
        guard (0...level).contains(targetLevel) else { return nil }
        let leastSignificantBit = UInt64(1) << UInt64(2 * (30 - targetLevel))
        return (id & ~((leastSignificantBit << 1) - 1)) | leastSignificantBit
    }
}

enum S2CellGeometry {
    private static let maxLevel = 30
    private static let maxSize = 1 << maxLevel
    // Inverse Hilbert lookup from Google's s2coords_internal.h.
    private static let ijToPosition = [
        [0, 1, 3, 2],
        [0, 3, 1, 2],
        [2, 3, 1, 0],
        [2, 1, 3, 0]
    ]
    private static let positionOrientation = [1, 0, 0, 3]

    static func cell(latitude: Double, longitude: Double, level: Int) -> S2GridCell? {
        guard (0...30).contains(level), latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        let lat = latitude * .pi / 180
        let lng = longitude * .pi / 180
        let x = cos(lat) * cos(lng)
        let y = cos(lat) * sin(lng)
        let z = sin(lat)
        let ax = abs(x), ay = abs(y), az = abs(z)
        let face: Int
        let u: Double
        let v: Double
        // LargestAbsComponent's stable x, then y, then z tie order matches S2.
        if ax >= ay && ax >= az {
            if x >= 0 { face = 0; u = y / x; v = z / x }
            else { face = 3; u = z / x; v = y / x }
        } else if ay >= az {
            if y >= 0 { face = 1; u = -x / y; v = z / y }
            else { face = 4; u = z / y; v = -x / y }
        } else if z >= 0 {
            face = 2; u = -x / z; v = -y / z
        } else {
            face = 5; u = -y / z; v = -x / z
        }
        let i = stToIJ(uvToST(u))
        let j = stToIJ(uvToST(v))
        let size = 1 << (maxLevel - level)
        let i0 = (i / size) * size
        let j0 = (j / size) * size
        let id = cellID(face: face, i: i, j: j, level: level)
        let vertices = [
            coordinate(face: face, i: i0, j: j0),
            coordinate(face: face, i: i0 + size, j: j0),
            coordinate(face: face, i: i0 + size, j: j0 + size),
            coordinate(face: face, i: i0, j: j0 + size),
            coordinate(face: face, i: i0, j: j0)
        ]
        return S2GridCell(id: id, face: face, level: level, vertices: vertices)
    }

    private static func cellID(face: Int, i: Int, j: Int, level: Int) -> UInt64 {
        var orientation = face & 1
        var id = UInt64(face) << 61
        for bit in stride(from: maxLevel - 1, through: 0, by: -1) {
            let ij = (((i >> bit) & 1) << 1) | ((j >> bit) & 1)
            let position = ijToPosition[orientation][ij]
            id |= UInt64(position) << UInt64(2 * bit + 1)
            orientation ^= positionOrientation[position]
        }
        let leastSignificantBit = UInt64(1) << UInt64(2 * (maxLevel - level))
        return (id & ~((leastSignificantBit << 1) - 1)) | leastSignificantBit
    }

    private static func uvToST(_ value: Double) -> Double {
        value >= 0 ? 0.5 * sqrt(1 + 3 * value) : 1 - 0.5 * sqrt(1 - 3 * value)
    }

    private static func stToUV(_ value: Double) -> Double {
        value >= 0.5 ? (4 * value * value - 1) / 3 : (1 - 4 * (1 - value) * (1 - value)) / 3
    }

    private static func stToIJ(_ value: Double) -> Int {
        guard value > 0 else { return 0 }
        return min(maxSize - 1, Int(Double(maxSize) * value))
    }

    private static func coordinate(face: Int, i: Int, j: Int) -> S2GridCoordinate {
        let s = Double(i) / Double(maxSize)
        let t = Double(j) / Double(maxSize)
        let u = stToUV(s)
        let v = stToUV(t)
        let xyz: (Double, Double, Double)
        switch face {
        case 0: xyz = (1, u, v)
        case 1: xyz = (-u, 1, v)
        case 2: xyz = (-u, -v, 1)
        case 3: xyz = (-1, -v, -u)
        case 4: xyz = (v, -1, -u)
        default: xyz = (v, u, -1)
        }
        let latitude = atan2(xyz.2, hypot(xyz.0, xyz.1)) * 180 / .pi
        let longitude = atan2(xyz.1, xyz.0) * 180 / .pi
        return S2GridCoordinate(latitude: latitude, longitude: longitude)
    }
}

enum S2GridLevelMode: Equatable, Sendable {
    case automatic
    case fixed(Int)

    static let supportedLevels = Array(14...20)

    init(rawValue: String) {
        if rawValue == "auto" { self = .automatic }
        else if let level = Int(rawValue), Self.supportedLevels.contains(level) { self = .fixed(level) }
        else { self = .automatic }
    }

    var rawValue: String {
        switch self {
        case .automatic: return "auto"
        case .fixed(let level): return String(min(20, max(14, level)))
        }
    }
}

enum S2GridLevelPolicy {
    static let minimumLevel = 14
    static let maximumLevel = 20
    /// At 1.18 m/point, the automatic visual density centers on level 17.
    static let level17ReferenceMetersPerPoint = 1.18
    static let hysteresisLevels = 0.65

    static func choose(metersPerPoint: Double, previousLevel: Int?) -> Int {
        guard metersPerPoint.isFinite, metersPerPoint > 0 else {
            return min(maximumLevel, max(minimumLevel, previousLevel ?? 17))
        }
        let raw = 17 + log2(level17ReferenceMetersPerPoint / metersPerPoint)
        let candidate = min(maximumLevel, max(minimumLevel, Int(raw.rounded())))
        guard let previousLevel, (minimumLevel...maximumLevel).contains(previousLevel), candidate != previousLevel else { return candidate }
        guard abs(raw - Double(previousLevel)) >= hysteresisLevels else { return previousLevel }
        return candidate
    }
}

enum S2GridViewportScalePolicy {
    static func metersPerPoint(
        projectedViewportWidth: Double,
        viewportWidthPoints: Double,
        metersPerMapPoint: Double
    ) -> Double? {
        guard projectedViewportWidth.isFinite, projectedViewportWidth > 0,
              viewportWidthPoints.isFinite, viewportWidthPoints > 0,
              metersPerMapPoint.isFinite, metersPerMapPoint > 0 else { return nil }
        // MKMapRect is measured in projected MapKit points, not meters. Convert
        // using the map scale at the viewport center latitude before applying
        // the S2 level policy.
        return projectedViewportWidth / viewportWidthPoints * metersPerMapPoint
    }
}

enum S2GridSamplingPolicy {
    static let maximumViewportSamples = 1_500
    static let maximumStridePoints: Double = 32
    static let viewportBufferPoints: CGFloat = 12

    /// Approximate projected cell width from the L17 reference scale. Sampling
    /// at half a cell prevents sparse viewport probes from skipping narrow
    /// fixed-level cells; very dense views are rejected before allocation.
    static func stridePoints(level: Int, metersPerPoint: Double) -> Double {
        guard metersPerPoint.isFinite, metersPerPoint > 0 else { return maximumStridePoints }
        let clampedLevel = min(20, max(14, level))
        let projectedCellPoints = 75.5 / metersPerPoint / pow(2, Double(clampedLevel - 17))
        return max(1, min(maximumStridePoints, projectedCellPoints / 2))
    }

    static func estimatedSampleCount(size: CGSize, stridePoints: Double) -> Int {
        guard size.width > 0, size.height > 0, stridePoints.isFinite, stridePoints > 0 else { return 0 }
        let bufferedWidth = Double(size.width + viewportBufferPoints * 2)
        let bufferedHeight = Double(size.height + viewportBufferPoints * 2)
        return (Int(ceil(bufferedWidth / stridePoints)) + 1)
            * (Int(ceil(bufferedHeight / stridePoints)) + 1)
    }

    static func samplePoints(size: CGSize, stridePoints: CGFloat, buffer: CGFloat = viewportBufferPoints) -> [CGPoint] {
        guard size.width > 0, size.height > 0, stridePoints.isFinite, stridePoints > 0,
              buffer.isFinite, buffer >= 0 else { return [] }
        let xValues = axisSamples(length: size.width, stridePoints: stridePoints, buffer: buffer)
        let yValues = axisSamples(length: size.height, stridePoints: stridePoints, buffer: buffer)
        var points: [CGPoint] = []
        points.reserveCapacity(xValues.count * yValues.count)
        for y in yValues {
            for x in xValues {
                points.append(CGPoint(x: x, y: y))
            }
        }
        return points
    }

    private static func axisSamples(length: CGFloat, stridePoints: CGFloat, buffer: CGFloat) -> [CGFloat] {
        let upperBound = length + buffer
        var values: [CGFloat] = []
        var value = -buffer
        while value <= upperBound {
            values.append(value)
            value += stridePoints
        }
        if values.last != upperBound { values.append(upperBound) }
        return values
    }
}

struct S2GridRenderResult: Equatable, Sendable {
    var cells: [S2GridCell] = []
    var actualLevel: Int?
    var didExceedCellLimit = false
}

enum S2GridViewportRenderer {
    static let defaultCellLimit = 300

    static func render(
        samples: [S2GridCoordinate],
        enabled: Bool,
        mode: S2GridLevelMode,
        metersPerPoint: Double,
        previousLevel: Int?,
        maximumCellCount: Int = defaultCellLimit,
        cachedCells: [UInt64: S2GridCell] = [:]
    ) -> S2GridRenderResult {
        guard enabled, !samples.isEmpty, maximumCellCount > 0 else { return S2GridRenderResult() }
        let desiredLevel: Int
        switch mode {
        case .automatic:
            desiredLevel = S2GridLevelPolicy.choose(metersPerPoint: metersPerPoint, previousLevel: previousLevel)
        case .fixed(let value):
            desiredLevel = min(20, max(14, value))
        }
        var didExceed = false
        let levels = modeIsAutomatic(mode) ? stride(from: desiredLevel, through: 14, by: -1) : stride(from: desiredLevel, through: desiredLevel, by: -1)
        for level in levels {
            var cellsByID: [UInt64: S2GridCell] = [:]
            for sample in samples {
                if Task<Never, Never>.isCancelled { return S2GridRenderResult() }
                guard let uncached = S2CellGeometry.cell(latitude: sample.latitude, longitude: sample.longitude, level: level) else { continue }
                let cell = cachedCells[uncached.id] ?? uncached
                cellsByID[cell.id] = cell
                if cellsByID.count > maximumCellCount {
                    didExceed = true
                    break
                }
            }
            if cellsByID.count <= maximumCellCount {
                return S2GridRenderResult(cells: cellsByID.values.sorted { $0.id < $1.id }, actualLevel: level, didExceedCellLimit: didExceed)
            }
        }
        return S2GridRenderResult(didExceedCellLimit: didExceed)
    }

    private static func modeIsAutomatic(_ mode: S2GridLevelMode) -> Bool {
        if case .automatic = mode { return true }
        return false
    }
}

struct S2GridGenerationGate: Sendable {
    private(set) var generation = 0
    mutating func begin() -> Int { generation &+= 1; return generation }
    mutating func invalidate() { generation &+= 1 }
    func accepts(_ token: Int) -> Bool { token == generation }
}

@MainActor
final class S2GridController: ObservableObject {
    @Published private(set) var result = S2GridRenderResult()
    private var gate = S2GridGenerationGate()
    private var renderTask: Task<Void, Never>?
    private var renderWorker: Task<S2GridRenderResult, Never>?
    private var cache: [UInt64: S2GridCell] = [:]
    private var lastStableLevel: Int?

    func update(samples: [S2GridCoordinate], metersPerPoint: Double, mode: S2GridLevelMode) {
        let token = gate.begin()
        renderTask?.cancel()
        renderWorker?.cancel()
        let previousLevel = lastStableLevel
        let previousCache = cache
        // Do not leave a previous viewport's polygons visible while the new
        // debounced calculation is in flight.
        result = S2GridRenderResult()
        renderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .utility) {
                S2GridViewportRenderer.render(
                    samples: samples,
                    enabled: true,
                    mode: mode,
                    metersPerPoint: metersPerPoint,
                    previousLevel: previousLevel,
                    cachedCells: previousCache
                )
            }
            self?.renderWorker = worker
            let rendered = await worker.value
            guard let self, !Task.isCancelled, self.gate.accepts(token) else { return }
            self.result = rendered
            self.lastStableLevel = rendered.actualLevel ?? self.lastStableLevel
            self.cache = Dictionary(uniqueKeysWithValues: rendered.cells.map { ($0.id, $0) })
        }
    }

    func clear() {
        gate.invalidate()
        renderTask?.cancel()
        renderTask = nil
        renderWorker?.cancel()
        renderWorker = nil
        cache.removeAll(keepingCapacity: true)
        lastStableLevel = nil
        result = S2GridRenderResult()
    }

    func showCellLimitMessage() {
        gate.invalidate()
        renderTask?.cancel()
        renderTask = nil
        renderWorker?.cancel()
        renderWorker = nil
        result = S2GridRenderResult(didExceedCellLimit: true)
    }
}
