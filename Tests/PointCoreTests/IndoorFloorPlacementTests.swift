import Testing
@testable import PointCore

struct IndoorFloorPlacementTests {
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
