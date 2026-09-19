import Foundation

/// Temporary phone-as-glove tuning. Device +Y (the camera/top edge) is forward.
/// Core Motion's +Z points out of the screen, so gravity.z is +1 when screen-down.
public struct PhoneHapticEnvelope {
    public enum AngleRange {
        case nearbyTest, walkingRoute

        var fullStrength: Double { self == .walkingRoute ? 15 : 0 }
        var silent: Double { self == .walkingRoute ? 60 : 45 }
    }

    public private(set) var intensity: Double = 0
    private let angleRange: AngleRange
    private var previousTime: Date?
    private var gripAccepted = false

    public init(angleRange: AngleRange = .nearbyTest) { self.angleRange = angleRange }

    public mutating func reset() {
        intensity = 0
        previousTime = nil
        gripAccepted = false
    }

    public mutating func acceptsGrip(gravityZ: Double?, motionAge: TimeInterval) -> Bool {
        guard let gravityZ, gravityZ.isFinite, (-1.05...1.05).contains(gravityZ),
              motionAge.isFinite, (0...0.3).contains(motionAge) else {
            gripAccepted = false
            return false
        }
        // Enter within 30° of screen-down; allow 35° once accepted to prevent chatter.
        let limit = cos((gripAccepted ? 35.0 : 30.0) * .pi / 180)
        gripAccepted = gravityZ >= limit
        return gripAccepted
    }

    public static func targetIntensity(errorDegrees: Double, angleRange: AngleRange = .nearbyTest) -> Double {
        guard errorDegrees.isFinite else { return 0 }
        // Walking guidance has a broad center plateau so normal hand/compass jitter
        // doesn't ask the user to hunt for a single exact direction.
        let proximity = max(0, min(1, 1 - (abs(errorDegrees) - angleRange.fullStrength) / (angleRange.silent - angleRange.fullStrength)))
        // Smoothstep softens both ends; cap output at 80% for initial phone testing.
        return 0.8 * proximity * proximity * (3 - 2 * proximity)
    }

    public mutating func update(errorDegrees: Double?, gripValid: Bool, now: Date) -> Double {
        guard gripValid, let errorDegrees, errorDegrees.isFinite else {
            intensity = 0
            previousTime = nil
            return 0
        }
        let elapsed = previousTime.map { now.timeIntervalSince($0) } ?? 0.05
        previousTime = now
        guard (0...0.3).contains(elapsed) else { intensity = 0; return 0 }
        let target = Self.targetIntensity(errorDegrees: errorDegrees, angleRange: angleRange)
        let t = 1 - exp(-elapsed / 0.18)
        intensity = intensity + (target - intensity) * t // Time-based lerp; frame-rate independent.
        if intensity < 0.005, target == 0 { intensity = 0 }
        return intensity
    }
}
