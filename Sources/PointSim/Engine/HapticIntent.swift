import Foundation
import PointCore

/// Semantic haptic vocabulary. Production emits only `confirm`/`stop` today; the reserved intents
/// exist so scenarios can describe the intended hardware contract before firmware implements it.
/// A scenario asserting a reserved intent is reported as untested rather than failed.
public enum HapticIntent: String, Codable, CaseIterable {
    case confirmAlignment
    case stop
    case sweepHint
    case turnLeft
    case turnRight
    case beaconReached
    case arrived
    case offRoute
    case lowBattery

    public var isImplemented: Bool {
        switch self {
        case .confirmAlignment, .stop: return true
        default: return false
        }
    }

    public static func intent(for command: HapticCommand) -> HapticIntent {
        switch command {
        case .stop: return .stop
        case .confirm: return .confirmAlignment
        }
    }
}
