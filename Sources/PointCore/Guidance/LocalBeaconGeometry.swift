import Foundation
import simd

/// Local AR world coordinates use +Y up. Project onto the floor plane for pointing,
/// so a beacon on the floor remains usable while the phone is held at waist height.
public enum LocalBeaconGeometry {
    public struct Direction {
        public let errorDegrees: Double
        public let horizontalDistance: Double
    }

    public static func direction(position: SIMD3<Float>, topEdge: SIMD3<Float>, target: SIMD3<Float>) -> Direction? {
        guard [position, topEdge, target].allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        let offset = target - position
        let toTarget = SIMD2<Float>(offset.x, offset.z)
        let pointing = SIMD2<Float>(topEdge.x, topEdge.z)
        let distance = simd_length(toTarget)
        guard distance >= 0.05, simd_length(pointing) >= 0.5 else { return nil }
        let f = simd_normalize(pointing), d = simd_normalize(toTarget)
        let error = atan2(f.x * d.y - f.y * d.x, simd_dot(f, d))
        return Direction(errorDegrees: Double(error) * 180 / .pi, horizontalDistance: Double(distance))
    }
}
