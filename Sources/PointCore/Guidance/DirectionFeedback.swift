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

public enum LocationFeedbackIssue: Equatable {
    case missing, invalid
    case inaccurate(meters: Double)
    case stale(seconds: Double)
    case nearby(distance: Double, uncertainty: Double)

    public var message: String {
        switch self {
        case .missing: return "Vibration paused · Waiting for a GPS fix"
        case .invalid: return "Vibration paused · GPS fix unavailable"
        case .inaccurate(let meters): return "Vibration paused · GPS uncertainty ±\(meters.formatted(.number.precision(.fractionLength(0)))) m"
        case .stale(let seconds): return "Vibration paused · GPS last updated \(seconds.formatted(.number.precision(.fractionLength(0)))) s ago"
        case .nearby: return "Near beacon · Waiting for GPS to confirm position"
        }
    }
}

public struct DirectionFeedback {
    public let status: FeedbackStatus
    public let angularErrorDegrees: Double?
    public let distanceToBeaconMeters: Double?
    public var conservativeErrorDegrees: Double? = nil
    public var uncertaintyDegrees: Double? = nil
    public var locationIssue: LocationFeedbackIssue? = nil
    public var shouldConfirm: Bool { status == .aligned }
}

/// Confirms estimated pointing alignment, with accuracy retained for diagnostics.
/// Silence never means that the route is obstacle-free.
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
        func unavailable(_ status: FeedbackStatus, locationIssue: LocationFeedbackIssue? = nil) -> DirectionFeedback {
            DirectionFeedback(status: status, angularErrorDegrees: nil, distanceToBeaconMeters: nil,
                              locationIssue: locationIssue)
        }
        guard enabled, let target else { reset(); return unavailable(.inactive) }
        guard connected else { reset(); return unavailable(.disconnected) }
        guard !rerouteRequired else { reset(); return unavailable(.rerouteRequired) }
        guard let location else {
            reset(); return unavailable(.locationUnavailable, locationIssue: .missing)
        }
        guard CLLocationCoordinate2DIsValid(location.coordinate), location.horizontalAccuracy.isFinite,
              location.horizontalAccuracy >= 0 else {
            reset(); return unavailable(.locationUnavailable, locationIssue: .invalid)
        }
        guard location.horizontalAccuracy <= 25 else {
            reset(); return unavailable(.locationUnavailable, locationIssue: .inaccurate(meters: location.horizontalAccuracy))
        }
        let locationAge = now.timeIntervalSince(location.timestamp)
        guard locationAge.isFinite, locationAge >= 0 else {
            reset(); return unavailable(.locationUnavailable, locationIssue: .invalid)
        }
        guard locationAge <= 5 else {
            reset(); return unavailable(.locationUnavailable, locationIssue: .stale(seconds: locationAge))
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
        // Use the estimated bearing even inside the GPS uncertainty circle. A
        // near-zero target still has no useful pointing direction.
        guard distance > 3 else {
            reset()
            return DirectionFeedback(status: .locationUnavailable, angularErrorDegrees: nil,
                                     distanceToBeaconMeters: distance,
                                     locationIssue: .nearby(distance: distance, uncertainty: location.horizontalAccuracy))
        }
        let bearing = RouteGeometry.bearingDegrees(from: location.coordinate, to: target.coordinate)
        let error = Self.signedAngle(bearing - heading.degrees)
        // Uncertainty and pointing error are different quantities. Use the measured
        // direction for feedback; retain the uncertainty for troubleshooting, without
        // making vibration impossible for nearby beacons under ordinary GPS error.
        let positionError = asin(min(1, location.horizontalAccuracy / distance)) * 180 / .pi
        let uncertainty = heading.accuracyDegrees + positionError
        let conservativeError = abs(error) + uncertainty
        let entryAngle = 25.0
        let exitAngle = 35.0
        let dwell = 0.2
        if aligned {
            if abs(error) > exitAngle { aligned = false; candidateSince = nil }
        } else if abs(error) <= entryAngle {
            if candidateSince == nil { candidateSince = now }
            if now.timeIntervalSince(candidateSince!) >= dwell { aligned = true }
        } else {
            candidateSince = nil
        }
        return DirectionFeedback(status: aligned ? .aligned : candidateSince == nil ? .offDirection : .checking,
                                 angularErrorDegrees: error, distanceToBeaconMeters: distance,
                                 conservativeErrorDegrees: conservativeError, uncertaintyDegrees: uncertainty)
    }

    public static func signedAngle(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return .nan }
        let value = (degrees + 180).truncatingRemainder(dividingBy: 360)
        return (value < 0 ? value + 360 : value) - 180
    }
}
