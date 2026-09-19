import CoreLocation
import Foundation
import PointCore

/// Walks the route polyline in virtual time and produces GPS fixes with noise, accuracy windows
/// and dropouts. True position stays available to the trace so a fix can be judged against truth.
public struct Walker {
    public struct Fix {
        public let location: CLLocation
        public let truth: CLLocationCoordinate2D
    }

    private let spec: WalkerSpec
    private let path: [CLLocationCoordinate2D]
    private let legLengths: [Double]
    private var travelled = 0.0
    private var lastFixSecond: Double?

    public private(set) var truth: CLLocationCoordinate2D
    public private(set) var finished = false

    public init(spec: WalkerSpec, path: [CLLocationCoordinate2D]) {
        self.spec = spec
        self.path = path
        legLengths = zip(path, path.dropFirst()).map(SimGeometry.distanceMeters)
        truth = path.first ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
    }

    public var totalMeters: Double { legLengths.reduce(0, +) }

    public mutating func advance(to second: Double, tickInterval: Double) {
        guard second >= spec.startAt else { return }
        guard !spec.pauses.contains(where: { $0.contains(second) }) else { return }
        travelled = min(totalMeters, travelled + spec.speedMps * tickInterval)
        finished = travelled >= totalMeters
        truth = coordinate(atDistance: travelled)
    }

    /// Returns a fix when one is due at this second, applying dropouts, degraded accuracy and noise.
    public mutating func fix(at second: Double, clock: VirtualClock, random: inout SeededRandom) -> Fix? {
        let interval = 1 / max(0.05, spec.gps.updateHz)
        guard lastFixSecond.map({ second - $0 >= interval - 1e-9 }) ?? true else { return nil }
        lastFixSecond = second
        guard !spec.gps.dropouts.contains(where: { $0.contains(second) }) else { return nil }
        let accuracy = spec.gps.degraded.first(where: { $0.contains(second) })?.accuracyMeters
            ?? spec.gps.accuracyMeters
        let offset = spec.gps.noiseMeters * abs(random.normal())
        let bearing = random.uniform() * 360
        let noisy = spec.gps.noiseMeters > 0
            ? SimGeometry.offset(from: truth, bearingDegrees: bearing, distanceMeters: offset)
            : truth
        let location = CLLocation(coordinate: noisy, altitude: 0, horizontalAccuracy: accuracy,
                                  verticalAccuracy: 3, timestamp: clock.date(atSecond: second))
        return Fix(location: location, truth: truth)
    }

    func coordinate(atDistance distance: Double) -> CLLocationCoordinate2D {
        guard !legLengths.isEmpty else { return truth }
        var remaining = distance
        for (index, length) in legLengths.enumerated() {
            if remaining <= length || index == legLengths.count - 1 {
                let bearing = SimGeometry.bearingDegrees(from: path[index], to: path[index + 1])
                return SimGeometry.offset(from: path[index], bearingDegrees: bearing,
                                          distanceMeters: min(remaining, length))
            }
            remaining -= length
        }
        return path.last ?? truth
    }
}
