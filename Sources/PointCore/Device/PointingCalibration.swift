import Foundation
import simd

/// Unit quaternion in the BNO055's WXYZ order. The compass convention is
/// East-North-Up fusion frame: sensor vectors rotate into ENU. Compass heading
/// is atan2(east, north), clockwise from magnetic north.
public struct GloveQuaternion: Equatable {
    private let value: simd_quatd
    public init?(w: Double, x: Double, y: Double, z: Double) {
        let norm = w*w + x*x + y*y + z*z
        guard norm.isFinite, (0.90...1.10).contains(norm) else { return nil }
        value = simd_normalize(simd_quatd(ix: x, iy: y, iz: z, r: w))
    }
    public func rotate(_ vector: SIMD3<Double>) -> SIMD3<Double> { value.act(vector) }
    public func unrotate(_ vector: SIMD3<Double>) -> SIMD3<Double> { value.inverse.act(vector) }
    public static func horizontal(_ degrees: Double) -> SIMD3<Double> {
        let a = degrees * .pi / 180
        return SIMD3(sin(a), cos(a), 0)
    }
    /// A lowered hand or a vertical finger must never request directional pulses.
    /// A symmetric 30° elevation window works with either sign of vertical axis.
    public static func isForward(_ vector: SIMD3<Double>) -> Bool {
        let length = simd_length(vector)
        return length.isFinite && length > 0.9 && abs(vector.z / length) <= sin(.pi / 6)
    }
    public static func heading(_ vector: SIMD3<Double>) -> Double? {
        guard simd_length(vector).isFinite, hypot(vector.x, vector.y) >= 0.35 else { return nil }
        return (atan2(vector.x, vector.y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

public struct GloveOrientationSample {
    public let quaternion: GloveQuaternion
    public let timestamp: Date
    public let health: FirmwareSensorHealth
}

/// Two opposing gravity-referenced glove poses learn the finger vector in sensor
/// space. No phone heading, phone motion, or known compass bearing is needed.
/// This checks mounting repeatability, not absolute magnetic heading accuracy.
public struct PointingCalibration: Codable {
    public enum PoseDirection { case down, up
        fileprivate var vector: SIMD3<Double> { SIMD3(0, 0, self == .down ? -1 : 1) }
    }
    public struct Pose {
        fileprivate let finger: SIMD3<Double>
        fileprivate let direction: PoseDirection
        fileprivate let spread: Double
        let timestamp: Date
    }
    public let finger: SIMD3<Double>
    /// Operational budget: measured mount repeatability plus a provisional 5°
    /// compass allowance. This is not a measured or guaranteed sensor accuracy.
    public let uncertainty: Double
    public let validationError: Double

    private enum CodingKeys: String, CodingKey { case version, finger, uncertainty, validationError }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        let components = try values.decode([Double].self, forKey: .finger)
        let uncertainty = try values.decode(Double.self, forKey: .uncertainty)
        let error = try values.decode(Double.self, forKey: .validationError)
        guard version == 1, components.count == 3, components.allSatisfy(\.isFinite),
              uncertainty.isFinite, error.isFinite, (0...10).contains(error),
              (5...20).contains(uncertainty), uncertainty >= 5 + error else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid mounting calibration"))
        }
        let finger = SIMD3(components[0], components[1], components[2])
        guard abs(simd_length(finger) - 1) < 0.001 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid finger direction"))
        }
        self.finger = simd_normalize(finger)
        self.uncertainty = uncertainty
        validationError = error
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .version)
        try values.encode([finger.x, finger.y, finger.z], forKey: .finger)
        try values.encode(uncertainty, forKey: .uncertainty)
        try values.encode(validationError, forKey: .validationError)
    }

    public static func capture(_ samples: [GloveOrientationSample], direction: PoseDirection, now: Date) -> Pose? {
        guard samples.count >= 12, let first = samples.first, let last = samples.last,
              (1.2...3).contains(last.timestamp.timeIntervalSince(first.timestamp)),
              (0...0.5).contains(now.timeIntervalSince(last.timestamp)) else { return nil }
        var vectors: [SIMD3<Double>] = []
        var previous = Date.distantPast
        for sample in samples {
            guard sample.health.mountingBlockingReason == nil,
                  sample.timestamp > previous,
                  previous == .distantPast || sample.timestamp.timeIntervalSince(previous) <= 0.35 else { return nil }
            previous = sample.timestamp
            vectors.append(sample.quaternion.unrotate(direction.vector))
        }
        let sum = vectors.reduce(SIMD3<Double>.zero, +)
        guard simd_length(sum) > 0.5 else { return nil }
        let mean = simd_normalize(sum)
        let spread = vectors.map { acos(max(-1, min(1, simd_dot(mean, $0)))) * 180 / .pi }.max() ?? 180
        guard spread <= 5 else { return nil }
        return Pose(finger: mean, direction: direction, spread: spread, timestamp: last.timestamp)
    }

    public init?(first: Pose, second: Pose) {
        guard first.direction == .down, second.direction == .up,
              (0...120).contains(second.timestamp.timeIntervalSince(first.timestamp)) else { return nil }
        let error = acos(max(-1, min(1, simd_dot(first.finger, second.finger)))) * 180 / .pi
        let estimate = 5 + max(first.spread, second.spread) + error
        guard error <= 10, estimate <= 20 else { return nil }
        finger = simd_normalize(first.finger + second.finger)
        uncertainty = estimate
        validationError = error
    }

    public func magneticHeading(_ sample: GloveOrientationSample, now: Date) -> HeadingReading? {
        guard sample.health.fusionBlockingReason == nil,
              let reading = relativeHeading(sample, now: now) else { return nil }
        return HeadingReading(degrees: reading.degrees, accuracyDegrees: uncertainty,
                              timestamp: sample.timestamp, reference: .magneticNorth)
    }

    /// Unsettled yaw is usable only after explicitly aligning a local demo target.
    /// Never advertise this reading as magnetic or true north.
    public func relativeHeading(_ sample: GloveOrientationSample, now: Date) -> HeadingReading? {
        guard sample.health.mountingBlockingReason == nil,
              (0...0.5).contains(now.timeIntervalSince(sample.timestamp)),
              GloveQuaternion.isForward(sample.quaternion.rotate(finger)),
              let degrees = GloveQuaternion.heading(sample.quaternion.rotate(finger)) else { return nil }
        return HeadingReading(degrees: degrees, accuracyDegrees: uncertainty,
                              timestamp: sample.timestamp, reference: .relative)
    }
}

/// Mounting geometry survives power cycles; live readings and room alignment do not.
/// The Bluetooth identifier prevents applying one glove's mounting to another glove.
public final class PointingCalibrationStore {
    private let defaults: UserDefaults
    private let directory: URL?
    public init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        self.directory = directory
    }
    private func key(_ deviceID: UUID) -> String { "point.glove-mount.v1.\(deviceID.uuidString)" }
    private func file(_ deviceID: UUID) -> URL? { directory?.appendingPathComponent("\(deviceID.uuidString).json") }

    /// Commit and verify before the UI reports success or publishes the live mapping.
    /// The app uses an atomic file as well as the legacy preferences copy so a
    /// completed capture does not depend on a deferred preferences flush.
    @discardableResult public func save(_ calibration: PointingCalibration, for deviceID: UUID) -> Bool {
        guard let data = try? JSONEncoder().encode(calibration),
              (try? JSONDecoder().decode(PointingCalibration.self, from: data)) != nil else { return false }
        if let directory, let file = file(deviceID) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                guard try Data(contentsOf: file) == data else { return false }
            } catch { return false }
        }
        defaults.set(data, forKey: key(deviceID))
        return defaults.data(forKey: key(deviceID)) == data
    }
    public func load(for deviceID: UUID) -> PointingCalibration? {
        if let file = file(deviceID), FileManager.default.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(PointingCalibration.self, from: data)
        }
        guard let data = defaults.data(forKey: key(deviceID)),
              let saved = try? JSONDecoder().decode(PointingCalibration.self, from: data) else { return nil }
        if directory != nil { save(saved, for: deviceID) } // Migrate existing completed setups.
        return saved
    }
    /// Older builds saved the mounting map but not the last connection. Migrate only
    /// when exactly one valid glove is identifiable; never guess among multiple gloves.
    public var onlySavedDeviceID: UUID? {
        let prefix = "point.glove-mount.v1."
        var candidates = Set(defaults.dictionaryRepresentation().keys.compactMap { key -> UUID? in
            guard key.hasPrefix(prefix), let id = UUID(uuidString: String(key.dropFirst(prefix.count))),
                  load(for: id) != nil else { return nil }
            return id
        })
        if let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), load(for: id) != nil { candidates.insert(id) }
            }
        }
        return candidates.count == 1 ? candidates.first : nil
    }
    @discardableResult public func remove(for deviceID: UUID) -> Bool {
        if let file = file(deviceID), FileManager.default.fileExists(atPath: file.path) {
            do { try FileManager.default.removeItem(at: file) }
            catch { return false }
        }
        defaults.removeObject(forKey: key(deviceID))
        return true
    }
}
