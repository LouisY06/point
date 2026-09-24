import Foundation

/// The single artifact a run produces. Tests, reports and (from phase 2) the console all read it,
/// so anything a failure needs to be understood must be in here.
public struct Trace: Codable {
    public static let currentSchema = 1

    public struct ScenarioRef: Codable {
        public let id: String
        public let title: String
        public let seed: UInt64
        public let tickHz: Double
        public let hash: String
    }

    public struct RouteRef: Codable {
        public struct Beacon: Codable {
            public let coordinate: [Double]
            public let final: Bool
            public let instruction: String
        }

        public let destinationName: String
        public let checkpoints: [[Double]]
        public let beacons: [Beacon]
    }

    public struct Frame: Codable {
        public let t: Double
        public let lat: Double?
        public let lon: Double?
        public let truthLat: Double?
        public let truthLon: Double?
        public let accuracy: Double?
        public let heading: Double?
        public let headingAccuracy: Double?
        public let state: String
        public let quality: String
        public let connection: String
        public let beaconIndex: Int
        public let status: String
        public let errorDegrees: Double?
        public let conservativeDegrees: Double?
        public let distanceMeters: Double?
        public let phoneIntensity: Double
        public let rerouteRequired: Bool
    }

    public struct Event: Codable {
        public let t: Double
        public let kind: String
        public let detail: [String: String]

        public init(t: Double, kind: String, detail: [String: String] = [:]) {
            self.t = t
            self.kind = kind
            self.detail = detail
        }
    }

    public struct Result: Codable {
        public enum Verdict: String, Codable { case passed, failed, untested }

        public let expectation: String
        public let verdict: Verdict
        public let detail: String
    }

    public struct Metrics: Codable {
        public var timeToFirstConfirmSeconds: Double?
        public var confirmPulses: Int
        public var stopCommands: Int
        public var falseConfirms: Int
        public var meanAbsErrorWhileConfirming: Double?
        public var maxConservativeErrorAtConfirm: Double?
        public var sweepSecondsToFirstConfirm: Double?
        public var arrivalSeconds: Double?
        public var beaconArrivals: Int
        public var rerouteCount: Int
        public var rejectedCommands: Int
        public var frames: Int
    }

    public var schema = Trace.currentSchema
    public var scenario: ScenarioRef
    public var code: [String: String]
    public var route: RouteRef
    public var frames: [Frame]
    public var events: [Event]
    public var results: [Result]
    public var metrics: Metrics

    public var failures: [Result] { results.filter { $0.verdict == .failed } }
    public var untested: [Result] { results.filter { $0.verdict == .untested } }
    public var passed: Bool { failures.isEmpty }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
