import Foundation

/// A two-pose attempt belongs to one glove. Live sensor interruptions cancel only
/// the current measurement, never a completed downward pose or an unsaved result.
public struct PointingSetupSession {
    public enum Outcome: Equatable {
        case downwardCaptured
        case readyToSave
        case unsteadyPose
        case inconsistentPoses
    }

    private struct Capture {
        let id: UUID
        let direction: PointingCalibration.PoseDirection
        var samples: [GloveOrientationSample] = []
    }
    public private(set) var deviceID: UUID?
    public private(set) var pendingCalibration: PointingCalibration?
    private var downwardPose: PointingCalibration.Pose?
    private var capture: Capture?
    public var hasDownwardPose: Bool { downwardPose != nil }
    public var isCapturing: Bool { capture != nil }

    public init() {}

    public mutating func prepare(for device: UUID, now: Date = Date()) {
        if deviceID != device { self = Self(); deviceID = device }
        if let downwardPose, pendingCalibration == nil,
           !(0...120).contains(now.timeIntervalSince(downwardPose.timestamp)) {
            self.downwardPose = nil
            capture = nil
        }
    }

    public mutating func begin(for device: UUID, now: Date = Date()) -> UUID? {
        prepare(for: device, now: now)
        guard capture == nil, pendingCalibration == nil else { return nil }
        let id = UUID()
        capture = Capture(id: id, direction: downwardPose == nil ? .down : .up)
        return id
    }

    public mutating func append(_ sample: GloveOrientationSample) {
        guard capture != nil, capture?.samples.last?.timestamp != sample.timestamp else { return }
        capture?.samples.append(sample)
        if (capture?.samples.count ?? 0) > 30 { capture?.samples.removeFirst() }
    }

    public mutating func finish(_ id: UUID, now: Date = Date()) -> Outcome? {
        guard let capture, capture.id == id else { return nil }
        self.capture = nil
        guard let pose = PointingCalibration.capture(capture.samples, direction: capture.direction, now: now) else {
            return .unsteadyPose
        }
        switch capture.direction {
        case .down:
            downwardPose = pose
            return .downwardCaptured
        case .up:
            guard let downwardPose, let result = PointingCalibration(first: downwardPose, second: pose) else {
                return .inconsistentPoses
            }
            pendingCalibration = result
            return .readyToSave
        }
    }

    /// A failed write retains both captures so saving can be retried without measuring again.
    public mutating func save(to store: PointingCalibrationStore, for device: UUID) -> PointingCalibration? {
        guard deviceID == device, let result = pendingCalibration,
              store.save(result, for: device), let saved = store.load(for: device) else { return nil }
        pendingCalibration = nil
        downwardPose = nil
        return saved
    }

    public mutating func interrupt() { capture = nil }
    public mutating func reset() { self = Self() }
}
