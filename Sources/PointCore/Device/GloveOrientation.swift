import Foundation

/// BNO055 CALIB_STAT uses two bits each: system, gyro, accelerometer, magnetometer.
/// These are calibration levels, not an angular accuracy measurement.
public struct FirmwareSensorHealth: Equatable {
    public enum Source: UInt8 { case bno055 = 1, mpu6050 = 2 }
    public let source: Source
    public let calibration: UInt8
    public let flags: UInt8
    public var system: UInt8 { calibration >> 6 }
    public var gyro: UInt8 { (calibration >> 4) & 3 }
    public var accelerometer: UInt8 { (calibration >> 2) & 3 }
    public var magnetometer: UInt8 { calibration & 3 }

    /// Gravity-based mounting does not need magnetic north.
    public var mountingBlockingReason: String? {
        guard flags & 1 != 0 else { return "Glove sensor unavailable" }
        guard flags & 4 == 0 else { return "Glove sensors disagree · Direction paused" }
        guard source == .bno055, flags & 8 == 0 else {
            return "Backup motion sensor active · Compass guidance paused"
        }
        // NDOF system > 0 means fusion has acquired its absolute reference; the
        // individual gyro offset may still be settling. Use that estimated
        // orientation without requiring full calibration. Stable pose capture,
        // compass readiness and sample freshness remain separate checks.
        // https://learn.adafruit.com/adafruit-bno055-absolute-orientation-sensor/device-calibration
        guard gyro == 3 || system > 0 else {
            return "Hold the glove still for a few seconds to settle its gyro"
        }
        return nil
    }

    /// Magnetic readiness gates navigation separately from the finger-axis setup.
    public var fusionBlockingReason: String? {
        if let reason = mountingBlockingReason { return reason }
        guard magnetometer >= 2 else { return "Move the glove gently away from magnets to settle its compass" }
        guard system > 0 else { return "Glove is finding magnetic north · Move it gently, then hold still" }
        return nil
    }
    public var blockingReason: String? {
        if let reason = fusionBlockingReason { return reason }
        return flags & 2 == 0 ? "Glove pointing orientation needs setup" : nil
    }

}

/// Local magnetic declination inferred from the paired headings in ONE CLLocation
/// sample. The phone may face any direction; its orientation cancels in the difference.
public struct MagneticNorthCorrection {
    /// Local declination changes much more slowly than a live pointing direction.
    /// The cache additionally limits reuse by distance from the capture location.
    public static let maximumAge: TimeInterval = 30 * 60
    public let degrees: Double
    public let uncertainty: Double
    public let timestamp: Date

    /// `accuracy` is the correction's uncertainty, not the phone's headingAccuracy.
    /// Use MagneticNorthCorrectionCache to establish this from phone samples.
    public init?(trueHeading: Double, magneticHeading: Double, accuracy: Double, timestamp: Date) {
        guard trueHeading.isFinite, magneticHeading.isFinite, accuracy.isFinite,
              (0..<360).contains(trueHeading), (0..<360).contains(magneticHeading),
              (0...25).contains(accuracy), timestamp.timeIntervalSince1970.isFinite else { return nil }
        degrees = DirectionFeedbackEngine.signedAngle(trueHeading - magneticHeading)
        uncertainty = accuracy
        self.timestamp = timestamp
    }

    public func apply(to reading: HeadingReading, now: Date) -> HeadingReading? {
        guard reading.reference == .magneticNorth,
              reading.degrees.isFinite, (0..<360).contains(reading.degrees),
              reading.accuracyDegrees.isFinite, (0...25).contains(reading.accuracyDegrees),
              (0...0.5).contains(now.timeIntervalSince(reading.timestamp)),
              (0...Self.maximumAge).contains(now.timeIntervalSince(timestamp)) else { return nil }
        let normalized = (reading.degrees + degrees + 360).truncatingRemainder(dividingBy: 360)
        return HeadingReading(degrees: normalized, accuracyDegrees: min(180, reading.accuracyDegrees + uncertainty),
                              timestamp: reading.timestamp, reference: .trueNorth)
    }
}

/// The relaxed room demo keeps a continuous yaw reference when the fusion
/// sensor gains/loses north readiness. A transition correction treats the short
/// inter-sample yaw change as a reference adjustment, not wearer movement. This
/// is approximate and can discard real rotation during that one sample interval.
public struct RelativeOrientationReference {
    public private(set) var offset = 0.0
    public private(set) var adjustments = 0
    public init() {}

    public mutating func update(previous: GloveOrientationSample?, current: GloveOrientationSample) {
        guard let previous, (0...0.5).contains(current.timestamp.timeIntervalSince(previous.timestamp)),
              previous.health.source == .bno055, current.health.source == .bno055,
              previous.health.flags & 0x0D == 1, current.health.flags & 0x0D == 1 else { return }
        let northChanged = (previous.health.fusionBlockingReason == nil) != (current.health.fusionBlockingReason == nil)
        let gyroChanged = (previous.health.mountingBlockingReason == nil) != (current.health.mountingBlockingReason == nil)
        guard northChanged || gyroChanged else { return }
        let oldNorthInSensor = previous.quaternion.unrotate(GloveQuaternion.horizontal(0))
        guard let shift = GloveQuaternion.heading(current.quaternion.rotate(oldNorthInSensor)) else { return }
        offset = DirectionFeedbackEngine.signedAngle(offset - shift)
        adjustments += 1
    }

    public func apply(to reading: HeadingReading) -> HeadingReading {
        HeadingReading(degrees: (reading.degrees + offset + 360).truncatingRemainder(dividingBy: 360),
                       accuracyDegrees: reading.accuracyDegrees, timestamp: reading.timestamp, reference: .relative)
    }
}
