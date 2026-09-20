import Foundation

/// How the wearer is moving. It changes which deliberate hand motion arms pointing,
/// because a cyclist's resting hand on the handlebar is already level and forward.
public enum TravelMode: String, Codable, CaseIterable, Sendable {
    case walking, cycling
}

/// Arms the alignment buzz only after a deliberate motion of the hand's pointing axis.
/// The single back-of-hand IMU cannot tell an extended finger from a handlebar grip,
/// so a level hand on its own is never treated as intent. Elevation is the calibrated
/// pointing axis in degrees above horizontal; the caller feeds one value per fresh,
/// mounting-healthy orientation sample at about 10 Hz. Thresholds are prototype tuning
/// values awaiting a worn-glove walk and ride.
public struct PointingIntentGate: Equatable {
    /// Matches `GloveQuaternion.isForward`: pointing output needs the axis within this band.
    public static let levelBandDegrees = 30.0
    /// Walking: the hand must have hung this low before rising into the band.
    public static let walkingHangingBelowDegrees = -45.0
    public static let walkingRiseWithin: TimeInterval = 1.0
    /// Cycling: lift the hand off the bar and tilt it up this far, then bring it level.
    public static let cyclingLiftAboveDegrees = 40.0
    public static let cyclingLiftHold: TimeInterval = 0.25
    public static let cyclingLiftToLevelWithin: TimeInterval = 1.5
    /// Cycling: the hand returns to the bar level, so the window must close by itself.
    public static let cyclingWindow: TimeInterval = 4.0
    /// A short dip out of the band keeps the window; longer needs a new gesture.
    public static let outOfBandGrace: TimeInterval = 0.5
    /// Longer gaps between samples discard any half-finished gesture.
    public static let sampleGap: TimeInterval = 0.5

    public private(set) var mode: TravelMode
    public private(set) var armedSince: Date?
    private var lastSample: Date?
    private var lastLevel: Date?
    private var hangingSeen: Date?
    private var liftStarted: Date?
    private var liftConfirmed: Date?

    public init(mode: TravelMode = .walking) { self.mode = mode }

    /// Changing mode discards the current window: the two gestures mean different things.
    public mutating func setMode(_ mode: TravelMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        reset()
    }

    public mutating func reset() {
        armedSince = nil
        lastSample = nil
        lastLevel = nil
        hangingSeen = nil
        liftStarted = nil
        liftConfirmed = nil
    }

    /// Feed only samples whose mounting health passes. Skipping unhealthy or stale samples
    /// lets a brief dip expire the window through `sampleGap` instead of erasing a gesture.
    public mutating func update(elevationDegrees: Double, now: Date) {
        guard elevationDegrees.isFinite else { return }
        if let lastSample, now < lastSample || now.timeIntervalSince(lastSample) > Self.sampleGap { reset() }
        lastSample = now
        let level = abs(elevationDegrees) <= Self.levelBandDegrees
        switch mode {
        case .walking:
            if elevationDegrees <= Self.walkingHangingBelowDegrees {
                hangingSeen = now
                armedSince = nil
                lastLevel = nil
            }
            if level {
                if armedSince == nil, let hangingSeen,
                   now.timeIntervalSince(hangingSeen) <= Self.walkingRiseWithin {
                    armedSince = now
                    self.hangingSeen = nil
                }
                lastLevel = now
            }
        case .cycling:
            if elevationDegrees >= Self.cyclingLiftAboveDegrees {
                if liftStarted == nil { liftStarted = now }
                if now.timeIntervalSince(liftStarted!) >= Self.cyclingLiftHold { liftConfirmed = now }
            } else {
                liftStarted = nil
            }
            if level {
                if armedSince == nil, let liftConfirmed,
                   now.timeIntervalSince(liftConfirmed) <= Self.cyclingLiftToLevelWithin {
                    armedSince = now
                    self.liftConfirmed = nil
                }
                lastLevel = now
            }
        }
        if armedSince != nil, !isArmed(now: now) { armedSince = nil }
    }

    public func isArmed(now: Date) -> Bool {
        guard let armedSince, let lastSample, let lastLevel,
              (0...Self.sampleGap).contains(now.timeIntervalSince(lastSample)),
              now.timeIntervalSince(lastLevel) <= Self.outOfBandGrace else { return false }
        return mode == .walking || now.timeIntervalSince(armedSince) <= Self.cyclingWindow
    }

    /// Shown while the hand is level but no gesture has opened a window.
    public var blockingReason: String {
        switch mode {
        case .walking: return "Lower your hand, then raise it and point forward"
        case .cycling: return "Lift your hand up off the bar, then point forward"
        }
    }
}
