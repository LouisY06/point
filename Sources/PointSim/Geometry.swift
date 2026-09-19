import CoreLocation
import Foundation

/// `PointCore.RouteGeometry` is internal and this target deliberately avoids `@testable`, so the
/// few formulas the world models need are restated here. They must stay equivalent; the scenario
/// suite would surface a divergence as bearing errors that production never reports.
public enum SimGeometry {
    public static func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    public static func bearingDegrees(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let deltaLongitude = (to.longitude - from.longitude) * .pi / 180
        let y = sin(deltaLongitude) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLongitude)
        return normalized(atan2(y, x) * 180 / .pi)
    }

    public static func offset(from origin: CLLocationCoordinate2D, bearingDegrees: Double,
                             distanceMeters: Double) -> CLLocationCoordinate2D {
        let radius = 6_371_000.0
        let lat1 = origin.latitude * .pi / 180
        let lon1 = origin.longitude * .pi / 180
        let bearing = bearingDegrees * .pi / 180
        let angular = distanceMeters / radius
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
        let lon2 = lon1 + atan2(sin(bearing) * sin(angular) * cos(lat1),
                                cos(angular) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }

    public static func normalized(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }
}
