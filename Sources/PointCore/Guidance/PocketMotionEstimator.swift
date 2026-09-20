import Foundation

/// Experimental pedestrian dead reckoning, not a measured position. Assumes a
/// fixed pocket, forward walking, and a known body heading when started.
public struct PocketMotionEstimator {
    public private(set) var x: Double
    public private(set) var z: Double
    public private(set) var heading: Double
    public private(set) var steps = 0
    public private(set) var travelled = 0.0
    public private(set) var valid = true
    public let stepLength: Double
    private var previousTime: TimeInterval
    private var lastStep = -Double.infinity
    private var peakTime: TimeInterval?
    private var filteredAcceleration = 0.0

    public init?(x: Double, z: Double, heading: Double, stepLength: Double, timestamp: TimeInterval) {
        guard [x, z, heading, stepLength, timestamp].allSatisfy(\.isFinite),
              (0.25...1.2).contains(stepLength) else { return nil }
        self.x = x; self.z = z; self.heading = heading
        self.stepLength = stepLength; previousTime = timestamp
    }

    /// Acceleration is upward, in g, with gravity removed. Rotation is CCW about
    /// world up in radians/second. Room bearings are clockwise from -Z.
    @discardableResult public mutating func update(timestamp: TimeInterval, upwardAcceleration: Double,
                                                   upwardRotation: Double) -> Bool {
        guard valid else { return false }
        guard [timestamp, upwardAcceleration, upwardRotation].allSatisfy(\.isFinite) else {
            valid = false; return false
        }
        let dt = timestamp - previousTime
        guard dt > 0 else { return false } // Duplicate/out-of-order samples cannot count steps.
        guard dt <= 0.3 else { valid = false; return false }
        previousTime = timestamp
        heading = DirectionFeedbackEngine.signedAngle(heading - upwardRotation * dt * 180 / .pi)
        filteredAcceleration += (upwardAcceleration - filteredAcceleration) * (1 - exp(-dt / 0.035))
        if let peakTime, timestamp - peakTime > 0.65 { self.peakTime = nil }
        if peakTime == nil, filteredAcceleration > 0.10, timestamp - lastStep >= 0.32 {
            peakTime = timestamp
        }
        guard let peakTime, filteredAcceleration < -0.06,
              (0.10...0.65).contains(timestamp - peakTime), timestamp - lastStep >= 0.32 else { return false }
        self.peakTime = nil
        lastStep = timestamp
        steps += 1
        travelled += stepLength
        x += sin(heading * .pi / 180) * stepLength
        z -= cos(heading * .pi / 180) * stepLength
        return true
    }
}

/// Arrival is explicitly approximate. Require a new step since the last target
/// and a dwell to avoid consuming adjacent beacons from one position sample.
public struct EstimatedBeaconArrival {
    private var entered: TimeInterval?
    private var stepsAtLastArrival = 0
    public init() {}
    public mutating func update(distance: Double, steps: Int, timestamp: TimeInterval) -> Bool {
        guard distance.isFinite, distance >= 0, timestamp.isFinite, distance <= 0.7,
              steps > stepsAtLastArrival else { entered = nil; return false }
        if entered == nil || timestamp < entered! { entered = timestamp }
        guard timestamp - entered! >= 0.6 else { return false }
        entered = nil; stepsAtLastArrival = steps
        return true
    }
    public mutating func pause() { entered = nil }
    public static func turnCue(targetX: Double, targetZ: Double, bodyHeading: Double) -> String {
        let angle = DirectionFeedbackEngine.signedAngle(atan2(targetX, -targetZ) * 180 / .pi - bodyHeading)
        if abs(angle) < 25 { return "Continue forward" }
        if abs(angle) > 150 { return "Turn around" }
        return angle > 0 ? "Turn right" : "Turn left"
    }
}
