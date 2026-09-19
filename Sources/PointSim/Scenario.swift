import CoreLocation
import Foundation

/// A scenario is data, so adding an integration case never requires new Swift.
public struct Scenario: Codable {
    public static let currentSchema = 1

    public var schema: Int
    public var id: String
    public var title: String
    public var tags: [String]
    public var seed: UInt64
    public var tickHz: Double
    public var maxSeconds: Double
    public var route: RouteSpec
    public var voice: VoiceSpec?
    public var link: LinkSpec
    public var walker: WalkerSpec
    public var arm: ArmSpec
    public var timeline: [TimelineEvent]
    public var expect: [Expectation]

    enum CodingKeys: String, CodingKey {
        case schema, id, title, tags, seed, tickHz, maxSeconds, route, voice, link, walker, arm, timeline, expect
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? Scenario.currentSchema
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        seed = try container.decodeIfPresent(UInt64.self, forKey: .seed) ?? 1
        tickHz = try container.decodeIfPresent(Double.self, forKey: .tickHz) ?? 20
        maxSeconds = try container.decodeIfPresent(Double.self, forKey: .maxSeconds) ?? 600
        route = try container.decode(RouteSpec.self, forKey: .route)
        voice = try container.decodeIfPresent(VoiceSpec.self, forKey: .voice)
        link = try container.decodeIfPresent(LinkSpec.self, forKey: .link) ?? LinkSpec()
        walker = try container.decodeIfPresent(WalkerSpec.self, forKey: .walker) ?? WalkerSpec()
        arm = try container.decodeIfPresent(ArmSpec.self, forKey: .arm) ?? ArmSpec()
        timeline = try container.decodeIfPresent([TimelineEvent].self, forKey: .timeline) ?? []
        expect = try container.decodeIfPresent([Expectation].self, forKey: .expect) ?? []
    }

    public func validated() throws -> Scenario {
        guard schema == Scenario.currentSchema else { throw ScenarioError.unsupportedSchema(schema) }
        guard !id.isEmpty else { throw ScenarioError.invalid("id must not be empty") }
        guard tickHz >= 1, tickHz <= 200 else { throw ScenarioError.invalid("tickHz must be 1…200") }
        guard maxSeconds > 0 else { throw ScenarioError.invalid("maxSeconds must be positive") }
        try route.validate()
        return self
    }
}

public enum ScenarioError: LocalizedError {
    case unsupportedSchema(Int)
    case invalid(String)
    case missingFixture(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let value): return "Scenario schema \(value) is not supported."
        case .invalid(let reason): return "Invalid scenario: \(reason)"
        case .missingFixture(let name): return "Fixture not found: \(name)"
        }
    }
}

/// `[latitude, longitude]` in scenario files, so hand written coordinates stay readable.
public struct Coord: Codable, Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        latitude = try container.decode(Double.self)
        longitude = try container.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(latitude)
        try container.encode(longitude)
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

public struct RouteSpec: Codable {
    public enum Kind: String, Codable { case inline, generated, fixture }

    public struct Leg: Codable {
        public let bearing: Double
        public let meters: Double
    }

    public var kind: Kind
    public var destinationName: String
    public var coordinates: [Coord]?
    public var origin: Coord?
    public var legs: [Leg]?
    public var fixture: String?
    /// Metres between synthesised checkpoints along a generated leg.
    public var checkpointSpacingMeters: Double

    enum CodingKeys: String, CodingKey {
        case kind, destinationName, coordinates, origin, legs, fixture, checkpointSpacingMeters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        destinationName = try container.decodeIfPresent(String.self, forKey: .destinationName) ?? "Destination"
        coordinates = try container.decodeIfPresent([Coord].self, forKey: .coordinates)
        origin = try container.decodeIfPresent(Coord.self, forKey: .origin)
        legs = try container.decodeIfPresent([Leg].self, forKey: .legs)
        fixture = try container.decodeIfPresent(String.self, forKey: .fixture)
        checkpointSpacingMeters = try container.decodeIfPresent(Double.self, forKey: .checkpointSpacingMeters) ?? 20
    }

    public func validate() throws {
        switch kind {
        case .inline:
            guard let coordinates, coordinates.count >= 2 else {
                throw ScenarioError.invalid("inline route needs at least two coordinates")
            }
        case .generated:
            guard origin != nil, let legs, !legs.isEmpty, legs.allSatisfy({ $0.meters > 0 }) else {
                throw ScenarioError.invalid("generated route needs an origin and positive legs")
            }
            guard checkpointSpacingMeters > 0 else {
                throw ScenarioError.invalid("checkpointSpacingMeters must be positive")
            }
        case .fixture:
            guard let fixture, !fixture.isEmpty else {
                throw ScenarioError.invalid("fixture route needs a fixture path")
            }
        }
    }
}

public struct VoiceSpec: Codable {
    public struct Candidate: Codable {
        public let name: String
        public let address: String
        public let coordinate: Coord
        public let streetAddress: String?
    }

    public var utterance: String
    public var transcriberLatencyMs: Double
    public var searchLatencyMs: Double
    public var routeLatencyMs: Double
    /// Index of the candidate the user picks. `nil` leaves the chooser open and navigation never starts.
    public var userChoice: Int?
    public var candidates: [Candidate]
    public var transcriberFails: Bool

    enum CodingKeys: String, CodingKey {
        case utterance, transcriberLatencyMs, searchLatencyMs, routeLatencyMs, userChoice, candidates, transcriberFails
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utterance = try container.decode(String.self, forKey: .utterance)
        transcriberLatencyMs = try container.decodeIfPresent(Double.self, forKey: .transcriberLatencyMs) ?? 700
        searchLatencyMs = try container.decodeIfPresent(Double.self, forKey: .searchLatencyMs) ?? 400
        routeLatencyMs = try container.decodeIfPresent(Double.self, forKey: .routeLatencyMs) ?? 600
        userChoice = try container.decodeIfPresent(Int.self, forKey: .userChoice) ?? 0
        candidates = try container.decodeIfPresent([Candidate].self, forKey: .candidates) ?? []
        transcriberFails = try container.decodeIfPresent(Bool.self, forKey: .transcriberFails) ?? false
    }
}

public struct LinkSpec: Codable {
    public var connectAt: Double
    public var heading: Bool
    public var gestures: Bool
    public var vibration: Bool
    public var headingHz: Double
    /// Packet age at delivery. Feedback rejects headings older than 0.5 s, so this is a real failure mode.
    public var latencyMs: Double
    public var dropRate: Double
    public var batteryPercent: Int?

    enum CodingKeys: String, CodingKey {
        case connectAt, heading, gestures, vibration, headingHz, latencyMs, dropRate, batteryPercent
    }

    public init() {
        connectAt = 0
        heading = true
        gestures = true
        vibration = true
        headingHz = 25
        latencyMs = 40
        dropRate = 0
        batteryPercent = nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        connectAt = try container.decodeIfPresent(Double.self, forKey: .connectAt) ?? connectAt
        heading = try container.decodeIfPresent(Bool.self, forKey: .heading) ?? heading
        gestures = try container.decodeIfPresent(Bool.self, forKey: .gestures) ?? gestures
        vibration = try container.decodeIfPresent(Bool.self, forKey: .vibration) ?? vibration
        headingHz = try container.decodeIfPresent(Double.self, forKey: .headingHz) ?? headingHz
        latencyMs = try container.decodeIfPresent(Double.self, forKey: .latencyMs) ?? latencyMs
        dropRate = try container.decodeIfPresent(Double.self, forKey: .dropRate) ?? dropRate
        batteryPercent = try container.decodeIfPresent(Int.self, forKey: .batteryPercent)
    }
}

public struct Window: Codable {
    public let from: Double
    public let to: Double
    public let accuracyMeters: Double?

    public func contains(_ second: Double) -> Bool { second >= from && second < to }
}

public struct GPSSpec: Codable {
    public var accuracyMeters: Double
    public var noiseMeters: Double
    public var updateHz: Double
    public var dropouts: [Window]
    public var degraded: [Window]

    enum CodingKeys: String, CodingKey { case accuracyMeters, noiseMeters, updateHz, dropouts, degraded }

    public init() {
        accuracyMeters = 4
        noiseMeters = 1.5
        updateHz = 1
        dropouts = []
        degraded = []
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        accuracyMeters = try container.decodeIfPresent(Double.self, forKey: .accuracyMeters) ?? accuracyMeters
        noiseMeters = try container.decodeIfPresent(Double.self, forKey: .noiseMeters) ?? noiseMeters
        updateHz = try container.decodeIfPresent(Double.self, forKey: .updateHz) ?? updateHz
        dropouts = try container.decodeIfPresent([Window].self, forKey: .dropouts) ?? dropouts
        degraded = try container.decodeIfPresent([Window].self, forKey: .degraded) ?? degraded
    }
}

public struct WalkerSpec: Codable {
    public var startAt: Double
    public var speedMps: Double
    public var pauses: [Window]
    public var gps: GPSSpec

    enum CodingKeys: String, CodingKey { case startAt, speedMps, pauses, gps }

    public init() {
        startAt = 0
        speedMps = 1.3
        pauses = []
        gps = GPSSpec()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        startAt = try container.decodeIfPresent(Double.self, forKey: .startAt) ?? startAt
        speedMps = try container.decodeIfPresent(Double.self, forKey: .speedMps) ?? speedMps
        pauses = try container.decodeIfPresent([Window].self, forKey: .pauses) ?? pauses
        gps = try container.decodeIfPresent(GPSSpec.self, forKey: .gps) ?? gps
    }
}

public struct ArmSpec: Codable {
    public struct Segment: Codable {
        public struct Sweep: Codable {
            public let fromDegrees: Double
            public let toDegrees: Double
            public let degPerSec: Double
        }

        public struct Hold: Codable {
            public let degrees: Double
        }

        public struct Track: Codable {
            public let errorDegrees: Double
        }

        public let at: Double
        public let hold: Hold?
        public let sweep: Sweep?
        public let track: Track?
    }

    public var mountOffsetDegrees: Double
    public var biasDriftDegPerMin: Double
    public var jitterDegrees: Double
    public var accuracyDegrees: Double
    /// `trueNorth` is the only reference feedback accepts; the others exercise calibration handling.
    public var reference: String
    public var profile: [Segment]

    enum CodingKeys: String, CodingKey {
        case mountOffsetDegrees, biasDriftDegPerMin, jitterDegrees, accuracyDegrees, reference, profile
    }

    public init() {
        mountOffsetDegrees = 0
        biasDriftDegPerMin = 0
        jitterDegrees = 0
        accuracyDegrees = 2
        reference = "trueNorth"
        profile = []
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        mountOffsetDegrees = try container.decodeIfPresent(Double.self, forKey: .mountOffsetDegrees) ?? mountOffsetDegrees
        biasDriftDegPerMin = try container.decodeIfPresent(Double.self, forKey: .biasDriftDegPerMin) ?? biasDriftDegPerMin
        jitterDegrees = try container.decodeIfPresent(Double.self, forKey: .jitterDegrees) ?? jitterDegrees
        accuracyDegrees = try container.decodeIfPresent(Double.self, forKey: .accuracyDegrees) ?? accuracyDegrees
        reference = try container.decodeIfPresent(String.self, forKey: .reference) ?? reference
        profile = try container.decodeIfPresent([Segment].self, forKey: .profile) ?? profile
    }
}

public struct TimelineEvent: Codable {
    public enum Action: String, Codable {
        case gesture, linkDisconnect, linkConnect, pause, resume, battery, stop
    }

    public let at: Double
    public let action: Action
    /// `checkDirection` or `pauseResume` for gestures; the percentage for `battery`.
    public let value: String?
}
