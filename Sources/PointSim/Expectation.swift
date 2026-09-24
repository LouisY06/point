import Foundation

/// Declarative predicates over a recorded trace. One enum case per predicate keeps scenario files
/// free of Swift while making an unknown predicate a decode error rather than a silent pass.
public enum Expectation: Codable {
    case endState(String)
    case arrival(beacon: String, beforeSeconds: Double)
    case confirmPulses(min: Int?, max: Int?)
    case noConfirmBefore(alignedWithinDegrees: Double)
    case eventOrder([String])
    case silentAfter(String)
    case neverIntent(HapticIntent)
    case requiresIntent(HapticIntent)

    public var name: String {
        switch self {
        case .endState: return "endState"
        case .arrival: return "arrival"
        case .confirmPulses: return "confirmPulses"
        case .noConfirmBefore: return "noConfirmBefore"
        case .eventOrder: return "eventOrder"
        case .silentAfter: return "silentAfter"
        case .neverIntent: return "neverIntent"
        case .requiresIntent: return "requiresIntent"
        }
    }

    /// Human readable form used as the row label in reports and test failures.
    public var summary: String {
        switch self {
        case .endState(let value): return "endState == \(value)"
        case .arrival(let beacon, let seconds):
            return "arrival at \(beacon) before \(seconds)s"
        case .confirmPulses(let minimum, let maximum):
            return "confirmPulses in [\(minimum.map(String.init) ?? "-"), \(maximum.map(String.init) ?? "-")]"
        case .noConfirmBefore(let degrees):
            return "no confirm pulse outside \(Int(degrees))°"
        case .eventOrder(let kinds): return "event order \(kinds.joined(separator: " → "))"
        case .silentAfter(let kind): return "silent after \(kind)"
        case .neverIntent(let intent): return "never \(intent.rawValue)"
        case .requiresIntent(let intent): return "requires \(intent.rawValue)"
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
        init(_ value: String) { stringValue = value }
    }

    private struct Arrival: Codable {
        let beacon: String
        let beforeSeconds: Double
    }

    private struct PulseBounds: Codable {
        let min: Int?
        let max: Int?
    }

    private struct AlignedWithin: Codable {
        let alignedWithinDegrees: Double
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard let key = container.allKeys.first, container.allKeys.count == 1 else {
            throw ScenarioError.invalid("each expectation needs exactly one key")
        }
        switch key.stringValue {
        case "endState":
            self = .endState(try container.decode(String.self, forKey: key))
        case "arrival":
            let value = try container.decode(Arrival.self, forKey: key)
            self = .arrival(beacon: value.beacon, beforeSeconds: value.beforeSeconds)
        case "confirmPulses":
            let value = try container.decode(PulseBounds.self, forKey: key)
            self = .confirmPulses(min: value.min, max: value.max)
        case "noConfirmBefore":
            let value = try container.decode(AlignedWithin.self, forKey: key)
            self = .noConfirmBefore(alignedWithinDegrees: value.alignedWithinDegrees)
        case "eventOrder":
            self = .eventOrder(try container.decode([String].self, forKey: key))
        case "silentAfter":
            self = .silentAfter(try container.decode(String.self, forKey: key))
        case "neverIntent":
            self = .neverIntent(try container.decode(HapticIntent.self, forKey: key))
        case "requiresIntent":
            self = .requiresIntent(try container.decode(HapticIntent.self, forKey: key))
        default:
            throw ScenarioError.invalid("unknown expectation '\(key.stringValue)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .endState(let value):
            try container.encode(value, forKey: Key("endState"))
        case .arrival(let beacon, let seconds):
            try container.encode(Arrival(beacon: beacon, beforeSeconds: seconds), forKey: Key("arrival"))
        case .confirmPulses(let minimum, let maximum):
            try container.encode(PulseBounds(min: minimum, max: maximum), forKey: Key("confirmPulses"))
        case .noConfirmBefore(let degrees):
            try container.encode(AlignedWithin(alignedWithinDegrees: degrees), forKey: Key("noConfirmBefore"))
        case .eventOrder(let kinds):
            try container.encode(kinds, forKey: Key("eventOrder"))
        case .silentAfter(let kind):
            try container.encode(kind, forKey: Key("silentAfter"))
        case .neverIntent(let intent):
            try container.encode(intent, forKey: Key("neverIntent"))
        case .requiresIntent(let intent):
            try container.encode(intent, forKey: Key("requiresIntent"))
        }
    }
}
