import Foundation
import PointCore

/// Phone-side vibration output. The app composes `PhoneHapticEnvelope` + `PhoneHapticPlayback`;
/// the harness drives the same pair so the trace shows what the phone would have felt like.
public final class RecordingHapticOutput: PhoneHapticOutput {
    public struct Call {
        public let second: Double
        public let kind: String
        public let intensity: Double?
    }

    public private(set) var calls: [Call] = []
    public private(set) var isPrepared = false
    public var now: Double = 0
    public var failNextPrepare = false
    public var failNextBurst = false

    public init() {}

    public func prepare(onInterruption: @escaping (PhoneHapticInterruption) -> Void) throws {
        if failNextPrepare {
            failNextPrepare = false
            throw GloveTransportError.unsupported
        }
        isPrepared = true
        calls.append(Call(second: now, kind: "prepare", intensity: nil))
    }

    public func startBurst(intensity: Double, duration: TimeInterval) throws {
        if failNextBurst {
            failNextBurst = false
            throw GloveTransportError.unsupported
        }
        calls.append(Call(second: now, kind: "burst", intensity: intensity))
    }

    public func changeIntensity(_ intensity: Double) throws {
        calls.append(Call(second: now, kind: "intensity", intensity: intensity))
    }

    public func silence() {
        calls.append(Call(second: now, kind: "silence", intensity: nil))
    }

    public func shutdown() {
        isPrepared = false
        calls.append(Call(second: now, kind: "shutdown", intensity: nil))
    }
}
