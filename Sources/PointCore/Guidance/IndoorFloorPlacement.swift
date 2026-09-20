import Foundation

/// Floor selection in an AR world aligned to gravity (+Y up).
public enum IndoorFloorPlacement {
    public static func floorHeight(classified: [Float], unclassified: [Float], cameraHeight: Float) -> Float? {
        guard cameraHeight.isFinite else { return nil }
        // Classification takes precedence over height guesses. Without classification, require
        // a low horizontal surface and choose the lowest one seen, never a known table or seat.
        if let floor = classified.filter({ $0.isFinite && $0 < cameraHeight }).min() { return floor }
        return unclassified.filter { $0.isFinite && cameraHeight - $0 >= 0.7 }.min()
    }

    public static func accepts(hit: SIMD3<Float>, camera: SIMD3<Float>, floorHeight: Float) -> Bool {
        guard [hit.x, hit.y, hit.z, camera.x, camera.y, camera.z, floorHeight].allSatisfy(\.isFinite) else { return false }
        let distance = hypot(hit.x - camera.x, hit.z - camera.z)
        return abs(hit.y - floorHeight) <= 0.12 && (0.5...8).contains(distance)
    }
}
