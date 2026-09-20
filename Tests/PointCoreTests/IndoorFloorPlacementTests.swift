import Testing
@testable import PointCore

struct IndoorFloorPlacementTests {
    @Test func relaxedFloorDoesNotNeedDetectedPlanes() {
        let hit = IndoorFloorPlacement.approximateHit(origin: [0, 1.2, 0], direction: [0, -0.6, -0.8], floorHeight: 0)
        #expect(hit != nil)
        #expect(abs(hit!.y) < 0.001)
        #expect(abs(hit!.z + 1.6) < 0.001)
        // Raising the camera changes the intersection distance, never the floor height.
        let raised = IndoorFloorPlacement.approximateHit(origin: [0, 1.5, 0], direction: [0, -0.6, -0.8], floorHeight: 0)
        #expect(abs(raised!.y) < 0.001)
        #expect(abs(raised!.z + 2) < 0.001)
    }
    @Test func relaxedFloorRejectsUpwardAndUnusableRays() {
        for direction: SIMD3<Float> in [[0, 0.6, -0.8], [0, 0, -1], [0, -0.01, -1], [0, -1, 0], [0, -.infinity, -1], [.nan, -0.5, -1]] {
            #expect(IndoorFloorPlacement.approximateHit(origin: [0, 1.2, 0], direction: direction, floorHeight: 0) == nil)
        }
        #expect(IndoorFloorPlacement.approximateHit(origin: [0, 1.2, 0], direction: [0, -0.1, -1], floorHeight: 0) == nil)
        #expect(IndoorFloorPlacement.approximateHit(origin: [0, -1, 0], direction: [0, -0.6, -0.8], floorHeight: 0) == nil)
    }
    @Test func prefersClassifiedFloorOverAnUnclassifiedLowerSurface() {
        #expect(IndoorFloorPlacement.floorHeight(classified: [0], unclassified: [-0.2], cameraHeight: 1.4) == 0)
    }
    @Test func fallbackUsesLowestSurfaceAndRejectsHighSurfaces() {
        #expect(IndoorFloorPlacement.floorHeight(classified: [], unclassified: [0.7, 0, 0.2], cameraHeight: 1.4) == 0)
        #expect(IndoorFloorPlacement.floorHeight(classified: [], unclassified: [1.0, 1.5], cameraHeight: 1.4) == nil)
        #expect(IndoorFloorPlacement.floorHeight(classified: [], unclassified: [], cameraHeight: 1.4) == nil)
    }
    @Test func placementMustBeOnFloorAndWithinReachableRange() {
        let camera = SIMD3<Float>(0, 1.4, 0)
        #expect(IndoorFloorPlacement.accepts(hit: [0, 0, -2], camera: camera, floorHeight: 0))
        #expect(!IndoorFloorPlacement.accepts(hit: [0, 0.75, -2], camera: camera, floorHeight: 0))
        #expect(!IndoorFloorPlacement.accepts(hit: [0, 0, -0.2], camera: camera, floorHeight: 0))
        #expect(!IndoorFloorPlacement.accepts(hit: [0, 0, -9], camera: camera, floorHeight: 0))
        #expect(!IndoorFloorPlacement.accepts(hit: [.nan, 0, -2], camera: camera, floorHeight: 0))
    }
}
