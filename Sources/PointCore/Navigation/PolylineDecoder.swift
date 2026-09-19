import CoreLocation
import Foundation

/// Existing polyline decoding, hardened to reject truncated / invalid input without looping.
enum PolylineDecoder {
    static func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
        let bytes = Array(encoded.utf8)
        var index = 0
        var latitude = 0
        var longitude = 0
        var points: [CLLocationCoordinate2D] = []

        func readDelta() -> Int? {
            var result = 0
            for shift in stride(from: 0, through: 30, by: 5) {
                guard index < bytes.count, (63...126).contains(bytes[index]) else { return nil }
                let byte = Int(bytes[index]) - 63
                index += 1
                result |= (byte & 31) << shift
                if byte < 32 { return (result & 1) == 0 ? result >> 1 : ~(result >> 1) }
            }
            return nil
        }

        while index < bytes.count {
            guard let lat = readDelta(), let lon = readDelta() else { return [] }
            latitude += lat
            longitude += lon
            let point = CLLocationCoordinate2D(latitude: Double(latitude) / 1e5,
                                               longitude: Double(longitude) / 1e5)
            guard CLLocationCoordinate2DIsValid(point) else { return [] }
            points.append(point)
        }
        return points
    }
}
