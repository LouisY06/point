import CoreLocation
import Foundation
import Testing
@testable import PointCore

/// Straight-line "Boston": Red runs north→south along one column, Green runs west→east along a row
/// through Park St, bus 1 runs along a parallel column. Grid unit is 1e-3° (~111 m N-S, ~83 m E-W);
/// stations sit 4 units apart so an 800 m search radius holds about one station.
@MainActor final class FakeTransit: TransitDataSource {
    var stationCalls = 0, routeCalls = 0, patternCalls = 0
    var arrivalsQueue: [[TransitArrival]] = []
    var vehicleQueue: [VehicleStatus?] = []
    var alertsResult: [TransitAlert] = []

    static func point(_ row: Double, _ column: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 42 - row * 0.001, longitude: -71 + column * 0.001)
    }
    static func stop(_ id: String, station: String? = nil, _ row: Double, _ column: Double) -> PatternStop {
        let stationID = station ?? id
        return PatternStop(platformID: id, stationID: stationID, name: names[stationID] ?? stationID, coordinate: point(row, column))
    }
    static let names = [
        "place-alfcl": "Alewife", "place-knncl": "Kendall/MIT", "place-chmnl": "Charles/MGH", "place-pktrm": "Park Street",
        "place-dwnxg": "Downtown Crossing", "place-sstat": "South Station", "place-boyls": "Boylston", "place-armnl": "Arlington",
        "place-coecl": "Copley", "b1-a": "Mass Ave @ A", "b1-b": "Mass Ave @ B", "b1-c": "Mass Ave @ C", "b1-d": "Mass Ave @ D"
    ]

    // Red (north→south, column 0): Alewife(0) Kendall(2) Charles(3) ParkSt(4) Downtown(5) ... direction 0.
    static let redSouth = RidePattern(id: "Red-1-0", routeID: "Red", directionID: 0, headsign: "Ashmont", stops: [
        stop("r-alewife-s", station: "place-alfcl", 0, 0), stop("r-kendall-s", station: "place-knncl", 8, 0),
        stop("r-charles-s", station: "place-chmnl", 12, 0), stop("r-park-s", station: "place-pktrm", 16, 0),
        stop("r-downtown-s", station: "place-dwnxg", 20, 0), stop("r-south-s", station: "place-sstat", 24, 0)
    ], shape: stride(from: 0, through: 24, by: 4).map { point(Double($0), 0) })
    static let redSouthBraintree = RidePattern(id: "Red-3-0", routeID: "Red", directionID: 0, headsign: "Braintree", stops: redSouth.stops, shape: redSouth.shape)
    static let redNorth = RidePattern(id: "Red-1-1", routeID: "Red", directionID: 1, headsign: "Alewife", stops: [
        stop("r-south-n", station: "place-sstat", 24, 0), stop("r-downtown-n", station: "place-dwnxg", 20, 0),
        stop("r-park-n", station: "place-pktrm", 16, 0), stop("r-charles-n", station: "place-chmnl", 12, 0),
        stop("r-kendall-n", station: "place-knncl", 8, 0), stop("r-alewife-n", station: "place-alfcl", 0, 0)
    ], shape: stride(from: 24, through: 0, by: -4).map { point(Double($0), 0) })
    // Green B (east→west, row 4): ParkSt(0) Boylston(1) Arlington(2) Copley(3) direction 0.
    static let greenWest = RidePattern(id: "Green-B-0", routeID: "Green-B", directionID: 0, headsign: "Boston College", stops: [
        stop("g-park-w", station: "place-pktrm", 16, 0), stop("g-boylston-w", station: "place-boyls", 16, 4),
        stop("g-arlington-w", station: "place-armnl", 16, 8), stop("g-copley-w", station: "place-coecl", 16, 12)
    ], shape: stride(from: 0, through: 12, by: 4).map { point(16, Double($0)) })
    static let greenCWest = RidePattern(id: "Green-C-0", routeID: "Green-C", directionID: 0, headsign: "Cleveland Circle", stops: greenWest.stops, shape: greenWest.shape)
    // Bus 1 north→south along column 1, curbside stops (no parent).
    static let bus1 = RidePattern(id: "1-_-0", routeID: "1", directionID: 0, headsign: "Nubian", stops: [
        stop("b1-a", 4, 4), stop("b1-b", 8, 4), stop("b1-c", 12, 4), stop("b1-d", 20, 4)
    ], shape: [point(4, 4), point(8, 4), point(12, 4), point(20, 4)])

    static let stations: [TransitStation] = [
        TransitStation(id: "place-alfcl", name: "Alewife", coordinate: point(0, 0), wheelchairAccessible: true),
        TransitStation(id: "place-knncl", name: "Kendall/MIT", coordinate: point(8, 0), wheelchairAccessible: true),
        TransitStation(id: "place-chmnl", name: "Charles/MGH", coordinate: point(12, 0), wheelchairAccessible: true),
        TransitStation(id: "place-pktrm", name: "Park Street", coordinate: point(16, 0), wheelchairAccessible: true),
        TransitStation(id: "place-dwnxg", name: "Downtown Crossing", coordinate: point(20, 0), wheelchairAccessible: true),
        TransitStation(id: "place-sstat", name: "South Station", coordinate: point(24, 0), wheelchairAccessible: true),
        TransitStation(id: "place-boyls", name: "Boylston", coordinate: point(16, 4), wheelchairAccessible: false),
        TransitStation(id: "place-armnl", name: "Arlington", coordinate: point(16, 8), wheelchairAccessible: true),
        TransitStation(id: "place-coecl", name: "Copley", coordinate: point(16, 12), wheelchairAccessible: true),
        TransitStation(id: "b1-a", name: "Mass Ave @ A", coordinate: point(4, 4), wheelchairAccessible: nil),
        TransitStation(id: "b1-b", name: "Mass Ave @ B", coordinate: point(8, 4), wheelchairAccessible: nil),
        TransitStation(id: "b1-c", name: "Mass Ave @ C", coordinate: point(12, 4), wheelchairAccessible: nil),
        TransitStation(id: "b1-d", name: "Mass Ave @ D", coordinate: point(20, 4), wheelchairAccessible: nil)
    ]
    static let routesAtStation: [String: [TransitRoute]] = [
        "place-knncl": [TransitRoute(id: "Red", name: "Red Line", colorHex: "DA291C", type: 1)],
        "place-pktrm": [TransitRoute(id: "Red", name: "Red Line", colorHex: "DA291C", type: 1), TransitRoute(id: "Green-B", name: "Green Line B", colorHex: "00843D", type: 0), TransitRoute(id: "Green-C", name: "Green Line C", colorHex: "00843D", type: 0)],
        "place-coecl": [TransitRoute(id: "Green-B", name: "Green Line B", colorHex: "00843D", type: 0), TransitRoute(id: "Green-C", name: "Green Line C", colorHex: "00843D", type: 0)],
        "place-dwnxg": [TransitRoute(id: "Red", name: "Red Line", colorHex: "DA291C", type: 1)],
        "place-sstat": [TransitRoute(id: "Red", name: "Red Line", colorHex: "DA291C", type: 1)],
        "b1-a": [TransitRoute(id: "1", name: "Route 1", colorHex: "FFC72C", type: 3)],
        "b1-b": [TransitRoute(id: "1", name: "Route 1", colorHex: "FFC72C", type: 3)],
        "b1-d": [TransitRoute(id: "1", name: "Route 1", colorHex: "FFC72C", type: 3)]
    ]

    func stations(near location: CLLocationCoordinate2D, radiusMeters: Double) async throws -> [TransitStation] {
        stationCalls += 1
        return Self.stations.filter { RouteGeometry.distanceMeters($0.coordinate, location) <= radiusMeters }
            .sorted { RouteGeometry.distanceMeters($0.coordinate, location) < RouteGeometry.distanceMeters($1.coordinate, location) }
    }
    func routes(atStops stopIDs: [String]) async throws -> [TransitRoute] {
        routeCalls += 1
        var seen = Set<String>()
        return stopIDs.flatMap { Self.routesAtStation[$0] ?? [] }.filter { seen.insert($0.id).inserted }
    }
    func patterns(forRoutes routeIDs: [String]) async throws -> [RidePattern] {
        patternCalls += 1
        return [Self.redSouth, Self.redSouthBraintree, Self.redNorth, Self.greenWest, Self.greenCWest, Self.bus1].filter { routeIDs.contains($0.routeID) }
    }
    func arrivals(at station: TransitStation, route routeID: String, directionID: Int) async throws -> [TransitArrival] {
        arrivalsQueue.isEmpty ? [] : arrivalsQueue.removeFirst()
    }
    func vehicle(forTrip tripID: String) async throws -> VehicleStatus? {
        vehicleQueue.isEmpty ? nil : vehicleQueue.removeFirst()
    }
    func alerts(routes routeIDs: [String], stations stationIDs: [String]) async throws -> [TransitAlert] { alertsResult }
}

@MainActor final class StraightWalks: RouteProviding {
    var calls = 0
    func walkingRoute(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D, name: String) async throws -> RoutePlan {
        calls += 1
        return try AppleMapsService.makeRoute(steps: [], fallbackCoordinates: [origin, destination], name: name)
    }
}

@MainActor struct TransitPlannerTests {
    // Origin 60 m west of Kendall; destination 55 m south of Copley.
    let nearKendall = CLLocationCoordinate2D(latitude: 42 - 0.008, longitude: -71 - 0.00075)
    let nearCopley = CLLocationCoordinate2D(latitude: 42 - 0.0165, longitude: -71 + 0.012)

    @Test func oneRideWhenSameLineServesBothEnds() async throws {
        let transit = FakeTransit(), walks = StraightWalks()
        let plans = try await TransitPlanner.plan(from: nearKendall, to: FakeTransit.point(20, 0.3), destinationName: "Downtown shop",
                                                  walking: walks, transit: transit)
        let best = try #require(plans.first)
        #expect(best.rides.count == 1)
        let ride = try #require(best.rides.first)
        #expect(ride.route.id == "Red" && ride.board.id == "place-knncl" && ride.alight.id == "place-dwnxg" && ride.stopsRidden == 3)
        #expect(ride.acceptablePatternIDs == ["Red-1-0", "Red-3-0"]) // Both southbound branches serve Kendall→Downtown.
        #expect(ride.boardPlatformIDs == ["r-kendall-s"] && ride.alightPlatformIDs == ["r-downtown-s"])
        #expect(ride.path.count == 4)
        guard case .walk(let first)? = best.legs.first, case .walk(let last)? = best.legs.last else { Issue.record("walk legs"); return }
        #expect(first.beacons.last?.kind == .boardStop && first.beacons.last?.isFinalDestination == true)
        #expect(first.beacons.last?.instruction == "Board the Red Line toward Ashmont or Braintree here")
        #expect(last.beacons.last?.kind == .destination)
        #expect(best.summary.contains("Red Line toward Ashmont or Braintree 3 stops to Downtown Crossing"))
        #expect(transit.stationCalls == 2 && transit.routeCalls == 2 && transit.patternCalls == 1)
    }

    @Test func transferAtRapidTransitStationReachesCopley() async throws {
        let transit = FakeTransit(), walks = StraightWalks()
        let plans = try await TransitPlanner.plan(from: nearKendall, to: nearCopley, destinationName: "Copley Library",
                                                  walking: walks, transit: transit)
        let best = try #require(plans.first)
        #expect(best.rides.map(\.route.id) == ["Red", "Green"]) // B and C merged into one Green Line ride.
        #expect(best.rides[1].routeIDs == ["Green-B", "Green-C"] && best.rides[1].routeFilter == "Green-B,Green-C")
        #expect(best.rides[1].acceptablePatternIDs == ["Green-B-0", "Green-C-0"])
        #expect(best.rides[0].alight.id == "place-pktrm" && best.rides[1].board.id == "place-pktrm" && best.rides[1].alight.id == "place-coecl")
        #expect(best.legs.count == 5)
        #expect(plans.filter { $0.rides.last?.route.id.hasPrefix("Green") == true }.count == 1) // One plan per line pair, best board stop.
        guard case .transfer(let station) = best.legs[2] else { Issue.record("expected transfer leg"); return }
        #expect(station.id == "place-pktrm")
        #expect(best.summary.contains("then change to the Green Line toward Boston College or Cleveland Circle"))
    }

    @Test func shortTripsAndNoStationsFallBackToWalking() async throws {
        let transit = FakeTransit(), walks = StraightWalks()
        let short = try await TransitPlanner.plan(from: nearKendall, to: FakeTransit.point(8, 0.2), destinationName: "Corner",
                                                  walking: walks, transit: transit)
        #expect(short.count == 1 && short[0].isWalkingOnly && transit.stationCalls == 0)
        let remote = try await TransitPlanner.plan(from: CLLocationCoordinate2D(latitude: 41, longitude: -72),
                                                   to: CLLocationCoordinate2D(latitude: 41.02, longitude: -72), destinationName: "Far",
                                                   walking: walks, transit: transit)
        #expect(remote.count == 1 && remote[0].isWalkingOnly)
    }

    @Test func standingAtTheStopUsesAStubWalkLeg() async throws {
        let transit = FakeTransit(), walks = StraightWalks()
        let atCharles = FakeTransit.point(12, 0.0001)
        let plans = try await TransitPlanner.plan(from: atCharles, to: FakeTransit.point(24, 1), destinationName: "South Station café",
                                                  walking: walks, transit: transit)
        let best = try #require(plans.first)
        guard case .walk(let first)? = best.legs.first, case .walk(let last)? = best.legs.last else { Issue.record("walk"); return }
        #expect(first.checkpoints.count == 2 && first.beacons.count == 1 && first.beacons[0].kind == .boardStop)
        #expect(last.checkpoints.count > 2) // The final walk came from the route provider.
    }

    @Test func busRideIsPlannedFromCurbsideStops() async throws {
        let transit = FakeTransit(), walks = StraightWalks()
        let plans = try await TransitPlanner.plan(from: FakeTransit.point(4, 4.0003), to: FakeTransit.point(20, 4.3), destinationName: "Nubian shop",
                                                  walking: walks, transit: transit)
        let bus = try #require(plans.first { $0.rides.first?.route.id == "1" })
        #expect(bus.rides[0].board.id == "b1-a" && bus.rides[0].alight.id == "b1-d")
        #expect(bus.rides[0].boardPlatformIDs == ["b1-a"])
    }

    @Test func transitPhrasesPickTheMode() {
        #expect(TransitPhrases.impliesTransit("take the T to Copley"))
        #expect(TransitPhrases.impliesTransit("get me to Harvard by bus"))
        #expect(TransitPhrases.impliesTransit("red line to park street"))
        #expect(TransitPhrases.impliesTransit("take me to Harvard using public transportation"))
        #expect(TransitPhrases.impliesTransit("I want to take the bus to Copley"))
        #expect(TransitPhrases.impliesTransit("get me to the airport by public transport"))
        #expect(TransitPhrases.impliesTransit("navigate to Fenway with transit"))
        #expect(!TransitPhrases.impliesTransit("take me to the bus museum"))
        #expect(!TransitPhrases.impliesTransit("take me to the train station cafe"))
        #expect(TransitPhrases.impliesWalking("walk me to the library"))
    }
}

@MainActor struct MBTADecodingTests {
    @Test func patternsCollapsePlatformsAndPreferCanonical() throws {
        let json = """
        {"data":[
          {"id":"Red-1-0","type":"route_pattern","attributes":{"name":"Alewife - Ashmont","direction_id":0,"typicality":1,"canonical":true},
           "relationships":{"route":{"data":{"id":"Red","type":"route"}},"representative_trip":{"data":{"id":"t1","type":"trip"}}}},
          {"id":"Red-9-0","type":"route_pattern","attributes":{"name":"Shuttle","direction_id":0,"typicality":4,"canonical":false},
           "relationships":{"route":{"data":{"id":"Red","type":"route"}},"representative_trip":{"data":{"id":"t9","type":"trip"}}}},
          {"id":"1-_-0","type":"route_pattern","attributes":{"name":"Harvard - Nubian","direction_id":0,"typicality":1},
           "relationships":{"route":{"data":{"id":"1","type":"route"}},"representative_trip":{"data":{"id":"tb","type":"trip"}}}}
        ],"included":[
          {"id":"t1","type":"trip","attributes":{"headsign":"Ashmont"},"relationships":{"stops":{"data":[{"id":"70061","type":"stop"},{"id":"70071","type":"stop"}]},"shape":{"data":{"id":"s1","type":"shape"}}}},
          {"id":"tb","type":"trip","attributes":{"headsign":"Nubian"},"relationships":{"stops":{"data":[{"id":"97","type":"stop"},{"id":"75","type":"stop"}]},"shape":{"data":null}}},
          {"id":"70061","type":"stop","attributes":{"name":"Alewife","latitude":42.396,"longitude":-71.140},"relationships":{"parent_station":{"data":{"id":"place-alfcl","type":"stop"}}}},
          {"id":"70071","type":"stop","attributes":{"name":"Kendall/MIT","latitude":42.362,"longitude":-71.086},"relationships":{"parent_station":{"data":{"id":"place-knncl","type":"stop"}}}},
          {"id":"97","type":"stop","attributes":{"name":"77 Mass Ave","latitude":42.359,"longitude":-71.093},"relationships":{"parent_station":{"data":null}}},
          {"id":"75","type":"stop","attributes":{"name":"84 Mass Ave","latitude":42.358,"longitude":-71.095},"relationships":{"parent_station":{"data":null}}},
          {"id":"s1","type":"shape","attributes":{"polyline":"_p~iF~ps|U_ulLnnqC_mqNvxq`@"}}
        ]}
        """
        let envelope: MBTAClient.Envelope<MBTAClient.PatternAttributes> = try MBTAClient.decode(Data(json.utf8))
        let patterns = MBTAClient.patterns(from: envelope)
        #expect(patterns.map(\.id) == ["1-_-0", "Red-1-0"])
        let red = patterns[1]
        #expect(red.stops.map(\.stationID) == ["place-alfcl", "place-knncl"] && red.headsign == "Ashmont" && red.shape.count == 3)
        #expect(patterns[0].stops.map(\.stationID) == ["97", "75"])
    }

    @Test func arrivalsCarryPatternAndVehiclePlatform() throws {
        let json = """
        {"data":[
          {"id":"p1","type":"prediction","attributes":{"arrival_time":"2026-09-19T17:03:30-04:00","departure_time":null,"status":null,"schedule_relationship":null},
           "relationships":{"trip":{"data":{"id":"trip-1","type":"trip"}},"vehicle":{"data":{"id":"R-1","type":"vehicle"}}}},
          {"id":"p2","type":"prediction","attributes":{"arrival_time":null,"departure_time":"2026-09-19T17:09:00-04:00","status":null,"schedule_relationship":"CANCELLED"},
           "relationships":{"trip":{"data":{"id":"trip-2","type":"trip"}},"vehicle":{"data":null}}}
        ],"included":[
          {"id":"trip-1","type":"trip","attributes":{"headsign":"Alewife"},"relationships":{"route_pattern":{"data":{"id":"Red-1-1","type":"route_pattern"}}}},
          {"id":"R-1","type":"vehicle","attributes":{"current_status":"STOPPED_AT","latitude":42.362,"longitude":-71.086,"updated_at":"2026-09-19T17:03:00-04:00"},
           "relationships":{"stop":{"data":{"id":"70072","type":"stop"}}}}
        ]}
        """
        let envelope: MBTAClient.Envelope<MBTAClient.PredictionAttributes> = try MBTAClient.decode(Data(json.utf8))
        let arrivals = MBTAClient.arrivals(from: envelope)
        #expect(arrivals.count == 1)
        #expect(arrivals[0].patternID == "Red-1-1" && arrivals[0].headsign == "Alewife")
        #expect(arrivals[0].vehicle?.status == .stoppedAt && arrivals[0].vehicle?.platformStopID == "70072")
        let now = MBTAClient.parseDate("2026-09-19T17:00:00-04:00")!
        #expect(arrivals[0].secondsAway(now: now) == 210)
    }
}


/// Opt in with POINT_TEST_LIVE_MBTA=1: real MBTA + Apple directions from Kendall/MIT.
@MainActor struct TransitLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["POINT_TEST_LIVE_MBTA"] == "1"))
    func liveKendallTrips() async throws {
        let client = MBTAClient(apiKey: ProcessInfo.processInfo.environment["MBTA_API_KEY"])
        let kendall = CLLocationCoordinate2D(latitude: 42.3625, longitude: -71.0862)
        let copley = CLLocationCoordinate2D(latitude: 42.3497, longitude: -71.0776)   // Copley Square
        let mfa = CLLocationCoordinate2D(latitude: 42.3394, longitude: -71.0940)      // Museum of Fine Arts (Green E / bus)
        for (name, target) in [("Copley Square", copley), ("Museum of Fine Arts", mfa)] {
            let before = client.callCount
            let plans = try await TransitPlanner.plan(from: kendall, to: target, destinationName: name, walking: AppleMapsService(), transit: client)
            print("== \(name): \(plans.count) plans, \(client.callCount - before) MBTA calls")
            for plan in plans { print("  -", plan.summary) }
            #expect(!plans.isEmpty)
            #expect(plans.first?.isWalkingOnly == false, "expected a ride to \(name)")
            #expect(client.callCount - before <= 8)
        }
    }
}
