import CoreLocation
import Foundation
import PointCore

/// Where the hand is pointing. Profile segments describe intent (hold a bearing, sweep, track the
/// beacon); mount offset, gyro bias drift and jitter describe everything between intent and the
/// heading the phone actually receives.
public struct ArmModel {
    private let spec: ArmSpec
    private var lastPacketSecond: Double?

    public init(spec: ArmSpec) { self.spec = spec }

    public var reference: HeadingReference {
        HeadingReference(rawValue: spec.reference) ?? .trueNorth
    }

    /// Intended bearing before any sensor error, in degrees clockwise from true north.
    public func intendedDegrees(at second: Double, bearingToTarget: Double?) -> Double {
        guard let segment = spec.profile.last(where: { $0.at <= second }) else {
            return bearingToTarget ?? 0
        }
        if let hold = segment.hold { return SimGeometry.normalized(hold.degrees) }
        if let sweep = segment.sweep {
            let delta = DirectionFeedbackEngine.signedAngle(sweep.toDegrees - sweep.fromDegrees)
            let travelled = sweep.degPerSec * (second - segment.at)
            let progress = delta < 0 ? -min(travelled, abs(delta)) : min(travelled, abs(delta))
            return SimGeometry.normalized(sweep.fromDegrees + progress)
        }
        if let track = segment.track, let bearing = bearingToTarget {
            return SimGeometry.normalized(bearing + track.errorDegrees)
        }
        return bearingToTarget ?? 0
    }

    /// Returns a heading packet when one is due, or nil for tick rates faster than the link rate,
    /// dropped packets and a disconnected link.
    public mutating func packet(at second: Double, bearingToTarget: Double?, link: LinkSpec,
                                connected: Bool, clock: VirtualClock,
                                random: inout SeededRandom) -> HeadingReading? {
        guard connected, link.heading else { return nil }
        let interval = 1 / max(0.1, link.headingHz)
        guard lastPacketSecond.map({ second - $0 >= interval - 1e-9 }) ?? true else { return nil }
        lastPacketSecond = second
        guard link.dropRate <= 0 || random.uniform() >= link.dropRate else { return nil }
        let drift = spec.biasDriftDegPerMin * second / 60
        let jitter = spec.jitterDegrees == 0 ? 0 : spec.jitterDegrees * random.normal()
        let degrees = SimGeometry.normalized(
            intendedDegrees(at: second, bearingToTarget: bearingToTarget)
                + spec.mountOffsetDegrees + drift + jitter)
        // The packet carries the sample time, not the receipt time: latency ages it, and feedback
        // rejects headings older than 0.5 s.
        let sampled = clock.date(atSecond: second - link.latencyMs / 1000)
        return HeadingReading(degrees: degrees, accuracyDegrees: spec.accuracyDegrees,
                              timestamp: sampled, reference: reference)
    }
}
