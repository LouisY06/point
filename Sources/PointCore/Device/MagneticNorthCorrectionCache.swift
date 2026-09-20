import CoreLocation
import Foundation

/// A session-local north reference, independent of the glove's live pointing samples.
/// Poor or missing phone updates cannot erase a usable reference or extend its lifetime.
public struct MagneticNorthCorrectionCache {
    public static let maximumDistance: CLLocationDistance = 2_000
    public static let maximumLocationAccuracy: CLLocationAccuracy = 250
    public static let maximumLocationAge: TimeInterval = 60
    /// Engineering allowance for local declination, not a Core Location accuracy measurement.
    /// Phone headingAccuracy describes the phone's magnetic azimuth, whose common
    /// error cancels in the paired true-minus-magnetic difference. It is not the
    /// uncertainty of this offset. Keep a separate allowance plus observed spread.
    public static let declinationAllowance = 5.0

    private var stored: MagneticNorthCorrection?
    private var origin: CLLocation?
    private var samples: [(degrees: Double, timestamp: Date)] = []
    private var sampleOrigin: CLLocation?

    public init() {}

    public mutating func clear() {
        stored = nil
        origin = nil
        samples = []
        sampleOrigin = nil
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
              accuracy.isFinite, (0...180).contains(accuracy),
              let pair = MagneticNorthCorrection(trueHeading: trueHeading, magneticHeading: magneticHeading,
                                                  accuracy: Self.declinationAllowance, timestamp: timestamp) else {
            samples = []; sampleOrigin = nil
            return
        }
        // Keep a time-spanning cluster even when Core Location delivers a fast burst.
        guard samples.last.map({ timestamp.timeIntervalSince($0.timestamp) >= 0.1 }) ?? true else { return }
        if let sampleOrigin, sampleOrigin.distance(from: location) > Self.maximumDistance {
            samples = []
            self.sampleOrigin = nil
        }
        samples.removeAll { timestamp.timeIntervalSince($0.timestamp) > 2 }
        if samples.isEmpty { sampleOrigin = location }
        samples.append((pair.degrees, timestamp))
        if samples.count > 16 { samples.removeFirst(samples.count - 16) }
        let spread = samples.map { abs(DirectionFeedbackEngine.signedAngle($0.degrees - pair.degrees)) }.max() ?? 0
        guard spread <= 1 else {
            // A single jump must not rotate guidance. Establish a new stable cluster.
            samples = [(pair.degrees, timestamp)]; sampleOrigin = location
            return
        }
        guard samples.count >= 3, let first = samples.first,
              timestamp.timeIntervalSince(first.timestamp) >= 0.25,
              let candidate = MagneticNorthCorrection(trueHeading: trueHeading, magneticHeading: magneticHeading,
                  accuracy: Self.declinationAllowance + spread, timestamp: timestamp) else { return }
        if let previous {
            guard candidate.timestamp > previous.timestamp,
                  candidate.uncertainty <= previous.uncertainty + 0.25 else { return }
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
