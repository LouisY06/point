#if DEBUG
import CoreLocation
import PointCore

/// Deterministic UI review data. Never loaded without the explicit debug launch argument.
enum TransitReviewFixtures {
    static let origin = CLLocationCoordinate2D(latitude: 42.3732, longitude: -71.1189)
    static let board = TransitStation(id: "review-board", name: "Massachusetts Ave @ Holyoke St", coordinate: .init(latitude: 42.3718, longitude: -71.1183), wheelchairAccessible: nil)
    static let alight = TransitStation(id: "review-alight", name: "Nubian Station", coordinate: .init(latitude: 42.3298, longitude: -71.0839), wheelchairAccessible: nil)
    static let destination = CLLocationCoordinate2D(latitude: 42.3292, longitude: -71.0833)

    static func walk(_ from: CLLocationCoordinate2D, _ to: CLLocationCoordinate2D, name: String, board: Bool = false) -> RoutePlan {
        let distance = CLLocation(latitude: from.latitude, longitude: from.longitude).distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
        return RoutePlan(destinationName: name, checkpoints: [
            RouteCheckpoint(coordinate: from, distanceFromStartMeters: 0, stepIndex: 0, stepInstruction: "Continue", bearingToNextDegrees: 160),
            RouteCheckpoint(coordinate: to, distanceFromStartMeters: distance, stepIndex: 0, stepInstruction: "Arrive", bearingToNextDegrees: 0)
        ], beacons: [PingTarget(coordinate: to, instruction: "Arrive at \(name)", isFinalDestination: true, bearingAfterTurnDegrees: 0,
                               kind: board ? .boardStop : .destination)], expectedTravelTime: distance / 1.3)
    }

    static var plan: JourneyPlan {
        let route = TransitRoute(id: "1", name: "Route 1", colorHex: "FFC72C", type: 3)
        let ride = RideLeg(route: route, directionID: 0, headsign: "Nubian", board: board, alight: alight,
                           acceptablePatternIDs: ["review-pattern"], boardPlatformIDs: [board.id], alightPlatformIDs: [alight.id],
                           platformOrder: [board.id, "review-middle", alight.id], stopsRidden: 18,
                           path: [board.coordinate, .init(latitude: 42.365, longitude: -71.105), .init(latitude: 42.353, longitude: -71.092), alight.coordinate])
        return JourneyPlan(destinationName: "Nubian Station", legs: [
            .walk(walk(origin, board.coordinate, name: board.name, board: true)), .ride(ride),
            .walk(walk(alight.coordinate, destination, name: "Nubian Station"))
        ], summary: "Sample journey. Walk to Massachusetts Ave at Holyoke Street, take Route 1 toward Nubian for 18 stops, then walk to Nubian Station.")
    }
}

@MainActor final class TransitReviewDataSource: TransitDataSource {
    func stations(near location: CLLocationCoordinate2D, radiusMeters: Double) async throws -> [TransitStation] { [] }
    func routes(atStops stopIDs: [String]) async throws -> [TransitRoute] { [] }
    func patterns(forRoutes routeIDs: [String]) async throws -> [RidePattern] { [] }
    func arrivals(at station: TransitStation, route routeID: String, directionID: Int) async throws -> [TransitArrival] {
        if ProcessInfo.processInfo.arguments.contains("--transit-no-arrivals") { return [] }
        return [TransitArrival(tripID: "review-trip", patternID: "review-pattern", headsign: "Nubian", time: Date(), status: nil,
                               vehicle: VehicleStatus(vehicleID: "review-bus", status: .stoppedAt, platformStopID: TransitReviewFixtures.board.id,
                                                      coordinate: nil, updatedAt: Date()))]
    }
    func vehicle(forTrip tripID: String) async throws -> VehicleStatus? {
        VehicleStatus(vehicleID: "review-bus", status: .inTransitTo, platformStopID: "review-middle", coordinate: nil, updatedAt: Date())
    }
    func alerts(routes routeIDs: [String], stations stationIDs: [String]) async throws -> [TransitAlert] { [] }
}
#endif
