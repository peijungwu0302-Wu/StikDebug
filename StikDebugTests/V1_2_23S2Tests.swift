import Foundation
import MapKit
import Testing
@testable import RouteLocation

struct V1_2_23S2ReferenceTests {
    // Leaf fixture comes from github.com/golang/geo/s2 CellIDFromLatLng for
    // (31.232135, 121.413217); coarser IDs are its canonical S2 parents.
    @Test func shanghaiReferenceCellIDsMatchAtSupportedLevels() throws {
        let expected: [Int: UInt64] = [
            14: 3869277664065880064,
            15: 3869277662992138240,
            16: 3869277663260573696,
            17: 3869277663059247104,
            18: 3869277663042469888,
            19: 3869277663055052800,
            20: 3869277663051907072
        ]
        for level in 14...20 {
            let cell = try #require(S2CellGeometry.cell(latitude: 31.232135, longitude: 121.413217, level: level))
            #expect(cell.id == expected[level])
            #expect(cell.level == level)
        }
        let leaf = try #require(S2CellGeometry.cell(latitude: 31.232135, longitude: 121.413217, level: 30))
        #expect(leaf.id == 3869277663051577529)
    }

    @Test func sameCoordinateParentAndChildIDsFollowS2Hierarchy() throws {
        let level17 = try #require(S2CellGeometry.cell(latitude: 25.033964, longitude: 121.564468, level: 17))
        let level18 = try #require(S2CellGeometry.cell(latitude: 25.033964, longitude: 121.564468, level: 18))
        #expect(level18.parentID(at: 17) == level17.id)
    }

    @Test func datelineAndOfficialCubeFaceBoundaryVectorsAreStable() throws {
        let east = try #require(S2CellGeometry.cell(latitude: 0, longitude: 180, level: 17))
        let west = try #require(S2CellGeometry.cell(latitude: 0, longitude: -180, level: 17))
        #expect(east.id == west.id)
        #expect(east.face == 3 && west.face == 3)
        let faceCenters: [(Double, Double, Int)] = [
            (0, 0, 0), (0, 90, 1), (90, 0, 2), (0, 180, 3), (0, -90, 4), (-90, 0, 5)
        ]
        for (latitude, longitude, face) in faceCenters {
            #expect(S2CellGeometry.cell(latitude: latitude, longitude: longitude, level: 17)?.face == face)
        }
        #expect(S2CellGeometry.cell(latitude: 44.9999, longitude: 0, level: 17)?.face == 0)
        #expect(S2CellGeometry.cell(latitude: 45.0001, longitude: 0, level: 17)?.face == 2)
    }

    @Test func autoLevelClampsAndUsesHysteresis() {
        #expect(S2GridLevelPolicy.choose(metersPerPoint: 1.18, previousLevel: nil) == 17)
        #expect(S2GridLevelPolicy.choose(metersPerPoint: 0.0001, previousLevel: nil) == 20)
        #expect(S2GridLevelPolicy.choose(metersPerPoint: 1_000_000, previousLevel: nil) == 14)
        #expect(S2GridLevelPolicy.choose(metersPerPoint: 1.18, previousLevel: 17) == 17)
        func metersPerPoint(rawLevel: Double) -> Double { 1.18 / pow(2, rawLevel - 17) }
        #expect(S2GridLevelPolicy.choose(metersPerPoint: metersPerPoint(rawLevel: 17.4), previousLevel: 17) == 17)
        #expect(S2GridLevelPolicy.choose(metersPerPoint: metersPerPoint(rawLevel: 17.7), previousLevel: 17) == 18)
        #expect(S2GridLevelPolicy.choose(metersPerPoint: metersPerPoint(rawLevel: 17.4), previousLevel: 18) == 18)
    }

    @Test func autoLevelUsesProjectedMapKitViewportScale() throws {
        #expect(S2GridViewportScalePolicy.metersPerPoint(projectedViewportWidth: 10_000, viewportWidthPoints: 500, metersPerMapPoint: 0.5) == 10)
        #expect(S2GridViewportScalePolicy.metersPerPoint(projectedViewportWidth: 10_000, viewportWidthPoints: 500, metersPerMapPoint: 0) == nil)
        #expect(S2GridViewportScalePolicy.metersPerPoint(projectedViewportWidth: 0, viewportWidthPoints: 500, metersPerMapPoint: 0.5) == nil)
        #expect(S2GridViewportScalePolicy.metersPerPoint(projectedViewportWidth: 10_000, viewportWidthPoints: 0, metersPerMapPoint: 0.5) == nil)
        let equator = S2GridViewportScalePolicy.metersPerPoint(
            projectedViewportWidth: 10_000,
            viewportWidthPoints: 500,
            metersPerMapPoint: MKMetersPerMapPointAtLatitude(0)
        )
        let taipei = S2GridViewportScalePolicy.metersPerPoint(
            projectedViewportWidth: 10_000,
            viewportWidthPoints: 500,
            metersPerMapPoint: MKMetersPerMapPointAtLatitude(25)
        )
        let equatorMetersPerPoint = try #require(equator)
        let taipeiMetersPerPoint = try #require(taipei)
        #expect(taipeiMetersPerPoint < equatorMetersPerPoint)
    }

    @Test func viewportSamplingIncludesSmallBufferAndRespectsWorkCap() {
        let size = CGSize(width: 390, height: 844)
        let points = S2GridSamplingPolicy.samplePoints(size: size, stridePoints: 32)
        #expect(points.contains { $0.x < 0 && $0.y < 0 })
        #expect(points.contains { $0.x > size.width })
        #expect(points.contains { $0.y > size.height })
        #expect(S2GridSamplingPolicy.estimatedSampleCount(size: size, stridePoints: 32) >= points.count)
        #expect(points.count <= S2GridSamplingPolicy.maximumViewportSamples)
    }

    @Test func viewportRendererHonorsOffFixedLevelCapAndStaleGenerationPolicy() {
        let samples = [
            S2GridCoordinate(latitude: 0, longitude: 0),
            S2GridCoordinate(latitude: 0, longitude: 90),
            S2GridCoordinate(latitude: 45, longitude: 45)
        ]
        let off = S2GridViewportRenderer.render(samples: samples, enabled: false, mode: .automatic, metersPerPoint: 5, previousLevel: nil, maximumCellCount: 1)
        #expect(off.cells.isEmpty)
        #expect(off.actualLevel == nil)
        let capped = S2GridViewportRenderer.render(samples: samples, enabled: true, mode: .fixed(14), metersPerPoint: 5, previousLevel: nil, maximumCellCount: 1)
        #expect(capped.cells.isEmpty)
        #expect(capped.didExceedCellLimit)
        var generation = S2GridGenerationGate()
        let old = generation.begin()
        let current = generation.begin()
        #expect(!generation.accepts(old))
        #expect(generation.accepts(current))
    }
}
