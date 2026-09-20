import CoreLocation
import Foundation

/// A session-local north reference, independent of the glove's live pointing samples.
/// Poor or missing phone updates cannot erase a usable reference or extend its lifetime.
public struct MagneticNorthCorrectionCache {
    public static let maximumDistance: CLLocationDistance = 2_000
    public static let maximumLocationAccuracy: CLLocationAccuracy = 250
    public static let maximumLocationAge: TimeInterval = 60

    private var stored: MagneticNorthCorrection?
    private var origin: CLLocation?

    public init() {}

    public mutating func clear() {
        stored = nil
        origin = nil
    }

    /// Call for both location and heading updates, and before restoring a BLE connection.
    public mutating func correction(at location: CLLocation?, now: Date) -> MagneticNorthCorrection? {
        guard let stored, let origin else { return nil }
        guard (0...MagneticNorthCorrection.maximumAge).contains(now.timeIntervalSince(stored.timestamp)) else {
            clear()
            return nil
        }
        if let location, Self.usable(location, now: now),
           origin.distance(from: location) + origin.horizontalAccuracy + location.horizontalAccuracy > Self.maximumDistance {
            clear()
            return nil
        }
        return stored
    }

    public mutating func update(trueHeading: Double, magneticHeading: Double, accuracy: Double,
                                timestamp: Date, location: CLLocation?, now: Date) {
        let previous = correction(at: location, now: now)
        // A recent neighbourhood-level fix is sufficient for the local correction;
        // route progress continues to enforce its own, stricter GPS requirements.
        guard let location, Self.usable(location, now: now),
              (0...5).contains(now.timeIntervalSince(timestamp)),
              let candidate = MagneticNorthCorrection(trueHeading: trueHeading, magneticHeading: magneticHeading,
                                                       accuracy: accuracy, timestamp: timestamp) else { return }
        if let previous {
            guard candidate.timestamp > previous.timestamp,
                  candidate.uncertainty <= previous.uncertainty else { return }
        }
        stored = candidate
        origin = location
    }

    private static func usable(_ location: CLLocation, now: Date) -> Bool {
        CLLocationCoordinate2DIsValid(location.coordinate)
            && location.coordinate.latitude.isFinite && location.coordinate.longitude.isFinite
            && (0...maximumLocationAccuracy).contains(location.horizontalAccuracy)
            && (0...maximumLocationAge).contains(now.timeIntervalSince(location.timestamp))
    }
}
