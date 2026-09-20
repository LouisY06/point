import Foundation

/// Brief motion/feature loss need only mute guidance. Relocalization or a longer
/// gap may change the room reference and must require explicit alignment again.
public struct RoomTrackingContinuity {
    private var limitedSince: TimeInterval?
    public init() {}
    public mutating func requiresRealignment(normal: Bool, mayKeepReference: Bool, now: TimeInterval) -> Bool {
        guard now.isFinite else { limitedSince = nil; return true }
        if normal {
            defer { limitedSince = nil }
            return limitedSince.map { now - $0 > 1 || now < $0 } ?? false
        }
        if limitedSince == nil { limitedSince = now }
        return !mayKeepReference || now - limitedSince! > 1 || now < limitedSince!
    }
}

/// AR gravity frame: +X right, -Z forward. One explicit known target connects
/// that room frame to the glove's magnetic heading; camera yaw is never pointing.
public struct RoomGloveAlignment {
    public let offset: Double
    public init?(targetX: Double, targetZ: Double, magneticHeading: Double, minimumDistance: Double = 1) {
        guard targetX.isFinite, targetZ.isFinite, magneticHeading.isFinite,
              minimumDistance.isFinite, minimumDistance >= 0.1,
              (0..<360).contains(magneticHeading), hypot(targetX, targetZ) >= minimumDistance else { return nil }
        offset = DirectionFeedbackEngine.signedAngle(magneticHeading - atan2(targetX, -targetZ) * 180 / .pi)
    }
    public func error(targetX: Double, targetZ: Double, magneticHeading: Double) -> Double? {
        guard targetX.isFinite, targetZ.isFinite, magneticHeading.isFinite,
              hypot(targetX, targetZ) > 0.01 else { return nil }
        return DirectionFeedbackEngine.signedAngle(atan2(targetX, -targetZ) * 180 / .pi + offset - magneticHeading)
    }
}

/// Graded, finite glove pulses. Refresh at most 5 Hz; loss of tracking stops
/// immediately and every pulse expires locally even if the app disappears.
public struct GlovePulseFeedback {
    public private(set) var intensity = 0.0
    private var previous: Date?
    private var submitted: Date?
    private var active = false
    public init() {}
    public mutating func stop() -> HapticCommand? {
        let wasActive = active
        intensity = 0; previous = nil; submitted = nil; active = false
        return wasActive ? .stop : nil
    }
    public mutating func update(error: Double, now: Date) -> HapticCommand? {
        guard error.isFinite else { return stop() }
        let dt = previous.map { now.timeIntervalSince($0) } ?? 0.05
        previous = now
        guard (0...0.3).contains(dt) else { return stop() }
        let proximity = max(0, min(1, 1 - (abs(error) - 10) / 25))
        let target = 0.8 * proximity * proximity * (3 - 2 * proximity)
        intensity += (target - intensity) * (1 - exp(-dt / 0.18))
        if target == 0 { return stop() }
        guard submitted.map({ now.timeIntervalSince($0) >= 0.2 }) ?? true else { return nil }
        submitted = now; active = true
        return .confirm(durationMs: 180, intensity: UInt8(min(204, max(0, intensity * 255))))
    }
}
