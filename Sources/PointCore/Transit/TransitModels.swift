import CoreLocation
import Foundation

public struct TransitRoute: Equatable, Identifiable {
    public let id: String
    /// "Red Line", "Route 1", "Silver Line SL1".
    public let name: String
    public let colorHex: String
    /// GTFS route_type: 0 light rail, 1 heavy rail, 2 commuter rail, 3 bus.
    public let type: Int

    public init(id: String, name: String, colorHex: String, type: Int) {
        self.id = id; self.name = name; self.colorHex = colorHex; self.type = type
    }

    public var isRapidTransit: Bool { type == 0 || type == 1 }
    public var isBus: Bool { type == 3 }

    /// Transfers are found from cached rapid-transit patterns without an extra routes call.
    public static let rapidTransit: [TransitRoute] = [
        TransitRoute(id: "Red", name: "Red Line", colorHex: "DA291C", type: 1),
        TransitRoute(id: "Orange", name: "Orange Line", colorHex: "ED8B00", type: 1),
        TransitRoute(id: "Blue", name: "Blue Line", colorHex: "003DA5", type: 1),
        TransitRoute(id: "Green-B", name: "Green Line B", colorHex: "00843D", type: 0),
        TransitRoute(id: "Green-C", name: "Green Line C", colorHex: "00843D", type: 0),
        TransitRoute(id: "Green-D", name: "Green Line D", colorHex: "00843D", type: 0),
        TransitRoute(id: "Green-E", name: "Green Line E", colorHex: "00843D", type: 0),
        TransitRoute(id: "Mattapan", name: "Mattapan Trolley", colorHex: "DA291C", type: 0)
    ]
}

/// A station (parent of several platforms) or a curbside bus stop.
public struct TransitStation: Equatable, Identifiable {
    public let id: String
    public let name: String
    public let coordinate: CLLocationCoordinate2D
    /// nil when the MBTA has no information.
    public let wheelchairAccessible: Bool?

    public init(id: String, name: String, coordinate: CLLocationCoordinate2D, wheelchairAccessible: Bool?) {
        self.id = id; self.name = name; self.coordinate = coordinate; self.wheelchairAccessible = wheelchairAccessible
    }

    public static func == (a: TransitStation, b: TransitStation) -> Bool { a.id == b.id }
}

public struct PatternStop: Equatable {
    /// The platform (child stop) a vehicle reports being at.
    public let platformID: String
    /// The station the platform belongs to; equals platformID for a plain bus stop.
    public let stationID: String
    public let name: String
    public let coordinate: CLLocationCoordinate2D

    public init(platformID: String, stationID: String, name: String, coordinate: CLLocationCoordinate2D) {
        self.platformID = platformID; self.stationID = stationID; self.name = name; self.coordinate = coordinate
    }

    public static func == (a: PatternStop, b: PatternStop) -> Bool { a.platformID == b.platformID }
}

/// One direction of one route variant: ordered platforms and the drawn shape.
public struct RidePattern: Identifiable, Equatable {
    public let id: String
    public let routeID: String
    public let directionID: Int
    public let headsign: String
    public let stops: [PatternStop]
    public let shape: [CLLocationCoordinate2D]

    public init(id: String, routeID: String, directionID: Int, headsign: String, stops: [PatternStop], shape: [CLLocationCoordinate2D]) {
        self.id = id; self.routeID = routeID; self.directionID = directionID; self.headsign = headsign
        self.stops = stops; self.shape = shape
    }

    public func index(ofStation stationID: String) -> Int? { stops.firstIndex { $0.stationID == stationID } }
    public static func == (a: RidePattern, b: RidePattern) -> Bool { a.id == b.id }
}

public struct RideLeg: Equatable {
    public let route: TransitRoute
    /// The MBTA route ids this ride accepts: one, or every Green Line branch serving both stops.
    public let routeIDs: [String]
    public let directionID: Int
    public let headsign: String
    public let board: TransitStation
    public let alight: TransitStation
    /// Patterns of this route/direction that serve both stops in order (Ashmont vs Braintree).
    public let acceptablePatternIDs: Set<String>
    public let boardPlatformIDs: Set<String>
    public let alightPlatformIDs: Set<String>
    /// Platform order of the primary pattern, used to tell "departed the board stop".
    public let platformOrder: [String]
    public let stopsRidden: Int
    public let path: [CLLocationCoordinate2D]

    public init(route: TransitRoute, routeIDs: [String]? = nil, directionID: Int, headsign: String, board: TransitStation, alight: TransitStation,
                acceptablePatternIDs: Set<String>, boardPlatformIDs: Set<String>, alightPlatformIDs: Set<String>,
                platformOrder: [String], stopsRidden: Int, path: [CLLocationCoordinate2D]) {
        self.route = route; self.routeIDs = routeIDs ?? [route.id]; self.directionID = directionID; self.headsign = headsign
        self.board = board; self.alight = alight
        self.acceptablePatternIDs = acceptablePatternIDs
        self.boardPlatformIDs = boardPlatformIDs; self.alightPlatformIDs = alightPlatformIDs
        self.platformOrder = platformOrder; self.stopsRidden = stopsRidden; self.path = path
    }

    public static func == (a: RideLeg, b: RideLeg) -> Bool {
        a.route.id == b.route.id && a.directionID == b.directionID && a.board == b.board && a.alight == b.alight
    }

    public var title: String { "\(route.name) toward \(headsign)" }
    /// Comma list for MBTA `filter[route]`.
    public var routeFilter: String { routeIDs.joined(separator: ",") }
}

public enum JourneyLeg: Equatable {
    case walk(RoutePlan)
    case ride(RideLeg)
    /// Change lines inside one station: no walking route, no beacons, straight to waiting.
    case transfer(TransitStation)

    public static func == (a: JourneyLeg, b: JourneyLeg) -> Bool {
        switch (a, b) {
        case (.walk(let x), .walk(let y)): return x.id == y.id
        case (.ride(let x), .ride(let y)): return x == y
        case (.transfer(let x), .transfer(let y)): return x == y
        default: return false
        }
    }
}

/// Walk → ride → walk, with any number of rides. First and last legs are always walks.
public struct JourneyPlan: Identifiable {
    public let id: UUID
    public let destinationName: String
    public let legs: [JourneyLeg]
    /// VoiceOver-ready one-sentence description.
    public let summary: String

    public init(destinationName: String, legs: [JourneyLeg], summary: String) {
        id = UUID(); self.destinationName = destinationName; self.legs = legs; self.summary = summary
    }

    public var rides: [RideLeg] { legs.compactMap { if case .ride(let ride) = $0 { return ride } else { return nil } } }
    public var isWalkingOnly: Bool { rides.isEmpty }
    public var firstWalk: RoutePlan? { if case .walk(let plan)? = legs.first { return plan } else { return nil } }
}

public struct VehicleStatus: Equatable {
    public enum Status: String, Equatable { case stoppedAt = "STOPPED_AT", incomingAt = "INCOMING_AT", inTransitTo = "IN_TRANSIT_TO", unknown }
    public let vehicleID: String
    public let status: Status
    /// The platform the status refers to (stopped at / incoming at / in transit to).
    public let platformStopID: String?
    public let coordinate: CLLocationCoordinate2D?
    public let updatedAt: Date?

    public init(vehicleID: String, status: Status, platformStopID: String?, coordinate: CLLocationCoordinate2D?, updatedAt: Date?) {
        self.vehicleID = vehicleID; self.status = status; self.platformStopID = platformStopID
        self.coordinate = coordinate; self.updatedAt = updatedAt
    }

    public static func == (a: VehicleStatus, b: VehicleStatus) -> Bool {
        a.vehicleID == b.vehicleID && a.status == b.status && a.platformStopID == b.platformStopID && a.updatedAt == b.updatedAt
    }
}

public struct TransitArrival: Equatable {
    public let tripID: String
    public let patternID: String?
    public let headsign: String
    public let time: Date?
    public let status: String?
    /// nil until the MBTA assigns a vehicle to the trip.
    public let vehicle: VehicleStatus?

    public init(tripID: String, patternID: String?, headsign: String, time: Date?, status: String?, vehicle: VehicleStatus?) {
        self.tripID = tripID; self.patternID = patternID; self.headsign = headsign
        self.time = time; self.status = status; self.vehicle = vehicle
    }

    public func secondsAway(now: Date) -> Int? { time.map { max(0, Int($0.timeIntervalSince(now).rounded())) } }
}

public struct TransitAlert: Equatable {
    public let header: String
    public let effect: String
    public init(header: String, effect: String) { self.header = header; self.effect = effect }
    public var isElevatorClosure: Bool { effect == "ELEVATOR_CLOSURE" }
}

/// Everything the planner and coordinator need; the MBTA client implements it, tests fake it.
@MainActor public protocol TransitDataSource {
    func stations(near location: CLLocationCoordinate2D, radiusMeters: Double) async throws -> [TransitStation]
    func routes(atStops stopIDs: [String]) async throws -> [TransitRoute]
    func patterns(forRoutes routeIDs: [String]) async throws -> [RidePattern]
    func arrivals(at station: TransitStation, route routeID: String, directionID: Int) async throws -> [TransitArrival]
    func vehicle(forTrip tripID: String) async throws -> VehicleStatus?
    func alerts(routes routeIDs: [String], stations stationIDs: [String]) async throws -> [TransitAlert]
}
