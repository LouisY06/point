import CoreLocation
import Foundation

public enum HeadingReference: String { case trueNorth, magneticNorth, relative }

public struct HeadingReading {
    public let degrees: Double
    public let accuracyDegrees: Double
    public let timestamp: Date
    public let reference: HeadingReference

    public init(degrees: Double, accuracyDegrees: Double, timestamp: Date,
                reference: HeadingReference) {
        self.degrees = degrees
        self.accuracyDegrees = accuracyDegrees
        self.timestamp = timestamp
        self.reference = reference
    }


}

public enum FeedbackStatus: String {
    case inactive, disconnected, locationUnavailable, headingUnavailable, calibrationRequired
    case rerouteRequired, checking, offDirection, aligned
}

public struct DirectionFeedback {
    public let status: FeedbackStatus
    public let angularErrorDegrees: Double?
    public let distanceToBeaconMeters: Double?
    public var shouldConfirm: Bool { status == .aligned }
}

/// Positive confirmation only. Silence never means that the route is obstacle-free.
/// All bearings are clockwise from true north. Hardware adapters must correct mount/IMU frames.
public struct DirectionFeedbackEngine {
    private var aligned = false
    private var candidateSince: Date?
    private var previousEvaluation: Date?

    public init() {}

    public mutating func reset() {
        aligned = false
        candidateSince = nil
        previousEvaluation = nil
    }

    public mutating func evaluate(target: PingTarget?, location: CLLocation?, heading: HeadingReading?,
                                  connected: Bool, enabled: Bool, rerouteRequired: Bool,
                                  now: Date = Date()) -> DirectionFeedback {
        func unavailable(_ status: FeedbackStatus) -> DirectionFeedback {
            DirectionFeedback(status: status, angularErrorDegrees: nil, distanceToBeaconMeters: nil)
        }
        guard enabled, let target else { reset(); return unavailable(.inactive) }
        guard connected else { reset(); return unavailable(.disconnected) }
        guard !rerouteRequired else { reset(); return unavailable(.rerouteRequired) }
        guard let location,
              CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy.isFinite,
              (0...25).contains(location.horizontalAccuracy),
              (0...5).contains(now.timeIntervalSince(location.timestamp)) else {
            reset(); return unavailable(.locationUnavailable)
        }
        guard let heading, heading.degrees.isFinite, (0..<360).contains(heading.degrees),
              heading.accuracyDegrees.isFinite, (0...25).contains(heading.accuracyDegrees),
              (0...0.5).contains(now.timeIntervalSince(heading.timestamp)) else {
            reset(); return unavailable(.headingUnavailable)
        }
        guard heading.reference == .trueNorth else { reset(); return unavailable(.calibrationRequired) }
        if previousEvaluation.map({ now.timeIntervalSince($0) > 1 || now < $0 }) == true {
            reset()
        }
        previousEvaluation = now

        let distance = RouteGeometry.distanceMeters(location.coordinate, target.coordinate)
        // Inside the uncertainty circle, the bearing to the beacon is not dependable.
        guard distance > max(3, location.horizontalAccuracy) else {
            reset(); return unavailable(.locationUnavailable)
        }
        let bearing = RouteGeometry.bearingDegrees(from: location.coordinate, to: target.coordinate)
        let error = Self.signedAngle(bearing - heading.degrees)
        // Leave a margin for both heading and position uncertainty before confirming.
        let positionError = asin(min(1, location.horizontalAccuracy / distance)) * 180 / .pi
        let conservativeError = abs(error) + heading.accuracyDegrees + positionError
        if aligned {
            if conservativeError > 25 { aligned = false; candidateSince = nil }
        } else if conservativeError <= 15 {
            if candidateSince == nil { candidateSince = now }
            if now.timeIntervalSince(candidateSince!) >= 0.35 { aligned = true }
        } else {
            candidateSince = nil
        }
        return DirectionFeedback(status: aligned ? .aligned : candidateSince == nil ? .offDirection : .checking,
                                 angularErrorDegrees: error, distanceToBeaconMeters: distance)
    }

    public static func signedAngle(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return .nan }
        let value = (degrees + 180).truncatingRemainder(dividingBy: 360)
        return (value < 0 ? value + 360 : value) - 180
    }
}
