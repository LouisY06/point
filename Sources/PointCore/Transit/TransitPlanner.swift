import CoreLocation
import Foundation

/// Apple cannot plan transit trips, so rides are found from MBTA route patterns and joined with
/// Apple walking legs. Rides may be any subway line or bus route near either end; a transfer is any
/// stop the two routes share (within 120 m). Budget: about five MBTA calls per plan.
public enum TransitPlanner {
    public struct Options {
        public var walkOnlyBelowMeters: Double = 600
        public var searchRadiusMeters: Double = 800
        /// Two stops this close count as the same transfer point (across the street, bus ↔ station).
        public var transferRadiusMeters: Double = 120
        public var maxOriginStations = 8
        public var maxJourneys = 3
        /// Below this, a leg is a stub rather than an Apple route (you are already at the stop).
        public var stubWalkBelowMeters: Double = 30
        public init() {}
    }

    struct Candidate {
        var rides: [(pattern: RidePattern, board: Int, alight: Int)]
        var score: Double
        /// Same lines to the same stops is one plan; the best-scoring board stop wins (no "walk
        /// six minutes to the next station on the same line" alternatives).
        var key: String { rides.map { "\(TransitPlanner.family($0.pattern.routeID))/\($0.pattern.stops[$0.alight].stationID)" }.joined(separator: "+") }
    }

    public static func plan(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D, destinationName: String,
                            walking: any RouteProviding, transit: any TransitDataSource, options: Options = Options()) async throws -> [JourneyPlan] {
        let direct = RouteGeometry.distanceMeters(origin, destination)
        if direct < options.walkOnlyBelowMeters {
            return [try await walkingOnly(from: origin, to: destination, name: destinationName, walking: walking)]
        }
        let originStations = Array(try await transit.stations(near: origin, radiusMeters: options.searchRadiusMeters).prefix(options.maxOriginStations))
        try Task.checkCancellation()
        guard !originStations.isEmpty else {
            return [try await walkingOnly(from: origin, to: destination, name: destinationName, walking: walking)]
        }
        // Routes at both ends: a ride is any origin route reaching the destination, or an origin
        // route meeting a destination route at a shared stop. Patterns are cached per route.
        let destinationStations = Array(try await transit.stations(near: destination, radiusMeters: options.searchRadiusMeters).prefix(options.maxOriginStations))
        let routes = try await transit.routes(atStops: originStations.map(\.id))
        let destinationRoutes = destinationStations.isEmpty ? [] : try await transit.routes(atStops: destinationStations.map(\.id))
        let rapidIDs = TransitRoute.rapidTransit.map(\.id)
        let wanted = Array(Set(routes.map(\.id))).sorted()
        let wantedAtDestination = Array(Set(destinationRoutes.map(\.id) + rapidIDs)).sorted()
        let patterns = try await transit.patterns(forRoutes: Array(Set(wanted + wantedAtDestination)).sorted())
        try Task.checkCancellation()
        let routeInfo = Dictionary((routes + destinationRoutes + TransitRoute.rapidTransit).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let originPatterns = patterns.filter { wanted.contains($0.routeID) }
        let connectingPatterns = patterns.filter { wantedAtDestination.contains($0.routeID) }

        let candidates = findCandidates(originStations: originStations, originPatterns: originPatterns, connectingPatterns: connectingPatterns,
                                        origin: origin, destination: destination, options: options)
        var journeys: [JourneyPlan] = []
        for candidate in candidates.prefix(options.maxJourneys) {
            try Task.checkCancellation()
            if let journey = try? await build(candidate, origin: origin, destination: destination, destinationName: destinationName,
                                              routeInfo: routeInfo, patterns: patterns, walking: walking, options: options) {
                journeys.append(journey)
            }
        }
        if journeys.isEmpty {
            journeys.append(try await walkingOnly(from: origin, to: destination, name: destinationName, walking: walking))
        }
        // Fastest first, now that the walking legs carry Apple's real times.
        return journeys.enumerated().sorted { ($0.element.estimatedSeconds, $0.offset) < ($1.element.estimatedSeconds, $1.offset) }.map(\.element)
    }

    // MARK: Search

    static func findCandidates(originStations: [TransitStation], originPatterns: [RidePattern], connectingPatterns: [RidePattern],
                               origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D, options: Options) -> [Candidate] {
        func near(_ stop: PatternStop) -> Double? {
            let distance = RouteGeometry.distanceMeters(stop.coordinate, destination)
            return distance <= options.searchRadiusMeters ? distance : nil
        }
        // Estimated seconds door to door, so the first candidate is the fastest, not the shortest walk.
        func score(walk1: Double, rides: [(RidePattern, Int, Int)], walk2: Double, transferWalk: Double = 0) -> Double {
            let walking = (walk1 + walk2 + transferWalk) / TravelEstimate.walkingMetersPerSecond
            let riding = rides.reduce(0.0) { $0 + TravelEstimate.rideSeconds(stops: $1.2 - $1.1, isBus: isBus($1.0.routeID)) }
            return walking + riding + Double(rides.count - 1) * TravelEstimate.transferSeconds
        }
        func isBus(_ routeID: String) -> Bool { !TransitRoute.rapidTransit.contains { $0.id == routeID } }
        // Flat-earth metres; exact enough for a 120 m transfer test and far cheaper than CLLocation.
        func flatDistance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
            let dy = (a.latitude - b.latitude) * 111_195
            let dx = (a.longitude - b.longitude) * 111_195 * cos(a.latitude * .pi / 180)
            return (dx * dx + dy * dy).squareRoot()
        }
        // For each connecting pattern, the best (closest to destination) alight index after a given stop.
        func bestAlight(in pattern: RidePattern, after index: Int) -> (index: Int, walk2: Double)? {
            var best: (index: Int, walk2: Double)?
            for candidate in (index + 1)..<pattern.stops.count {
                if let walk2 = near(pattern.stops[candidate]), walk2 < (best?.walk2 ?? .infinity) { best = (candidate, walk2) }
            }
            return best
        }
        var found: [Candidate] = []
        for pattern in originPatterns {
            for station in originStations {
                guard let boardIndex = pattern.index(ofStation: station.id), boardIndex < pattern.stops.count - 1 else { continue }
                let walk1 = RouteGeometry.distanceMeters(origin, station.coordinate)
                if let direct = bestAlight(in: pattern, after: boardIndex) {
                    let rides = [(pattern, boardIndex, direct.index)]
                    found.append(Candidate(rides: rides.map { ($0.0, $0.1, $0.2) }, score: score(walk1: walk1, rides: rides, walk2: direct.walk2)))
                }
                // One transfer: any downstream stop within transferRadius of a stop on a connecting pattern.
                for transferIndex in (boardIndex + 1)..<pattern.stops.count {
                    let transfer = pattern.stops[transferIndex]
                    for second in connectingPatterns where second.routeID != pattern.routeID {
                        var bestSecond: (board: Int, alight: Int, walk2: Double, hop: Double)?
                        for (secondBoard, stop) in second.stops.enumerated() where secondBoard < second.stops.count - 1 {
                            let hop = stop.stationID == transfer.stationID ? 0 : flatDistance(stop.coordinate, transfer.coordinate)
                            guard hop <= options.transferRadiusMeters, let alight = bestAlight(in: second, after: secondBoard) else { continue }
                            let total = alight.walk2 + hop
                            if total < (bestSecond.map { $0.walk2 + $0.hop } ?? .infinity) { bestSecond = (secondBoard, alight.index, alight.walk2, hop) }
                        }
                        guard let bestSecond else { continue }
                        let rides = [(pattern, boardIndex, transferIndex), (second, bestSecond.board, bestSecond.alight)]
                        found.append(Candidate(rides: rides.map { ($0.0, $0.1, $0.2) },
                                               score: score(walk1: walk1, rides: rides, walk2: bestSecond.walk2, transferWalk: bestSecond.hop)))
                    }
                }
            }
        }
        var seen = Set<String>()
        // Deterministic order: `sorted` is not stable, and equal-score branches share a key.
        return found.sorted { ($0.score, $0.rides[0].pattern.id) < ($1.score, $1.rides[0].pattern.id) }.filter { seen.insert($0.key).inserted }
    }

    // MARK: Assembly

    static func build(_ candidate: Candidate, origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D, destinationName: String,
                      routeInfo: [String: TransitRoute], patterns: [RidePattern], walking: any RouteProviding, options: Options) async throws -> JourneyPlan {
        var legs: [JourneyLeg] = []
        var rideLegs: [RideLeg] = []
        var previousAlight: TransitStation?
        var walkMinutes: [Int] = []
        for (position, ride) in candidate.rides.enumerated() {
            let board = station(ride.pattern.stops[ride.board])
            let alight = station(ride.pattern.stops[ride.alight])
            let rideLeg = rideLeg(ride.pattern, board: ride.board, alight: ride.alight, routeInfo: routeInfo, patterns: patterns)
            let boardInstruction = "Board the \(rideLeg.route.name) toward \(rideLeg.headsign) here"
            if position == 0 {
                let leg = try await walkLeg(from: origin, to: board, kind: .boardStop, walking: walking, options: options, instruction: boardInstruction)
                walkMinutes.append(minutes(leg))
                legs.append(.walk(leg))
            } else if let previousAlight {
                if previousAlight.id == board.id {
                    legs.append(.transfer(previousAlight))
                } else {
                    // Different stop (across the street, station to bus stop): a short walking leg with its own board beacon.
                    let leg = try await walkLeg(from: previousAlight.coordinate, to: board, kind: .boardStop, walking: walking, options: options, instruction: boardInstruction)
                    walkMinutes.insert(minutes(leg), at: walkMinutes.count)
                    legs.append(.walk(leg))
                }
            }
            rideLegs.append(rideLeg)
            legs.append(.ride(rideLeg))
            previousAlight = alight
        }
        guard let last = previousAlight else { throw ServiceError.noRoute }
        let final = try await walkLeg(from: last.coordinate, to: TransitStation(id: "destination", name: destinationName, coordinate: destination, wheelchairAccessible: nil),
                                      kind: .destination, walking: walking, options: options, instruction: "You have arrived")
        walkMinutes.append(minutes(final))
        legs.append(.walk(final))
        return JourneyPlan(destinationName: destinationName, legs: legs, summary: summary(rides: rideLegs, walkMinutes: walkMinutes, destinationName: destinationName))
    }

    static func walkingOnly(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D, name: String, walking: any RouteProviding) async throws -> JourneyPlan {
        let plan = try await walking.walkingRoute(from: origin, to: destination, name: name)
        return JourneyPlan(destinationName: name, legs: [.walk(plan)], summary: "Walk \(plural(minutes(plan), "minute")) to \(name).")
    }

    static func walkLeg(from origin: CLLocationCoordinate2D, to station: TransitStation, kind: PingTarget.Kind, walking: any RouteProviding,
                        options: Options, instruction: String) async throws -> RoutePlan {
        let plan: RoutePlan
        if RouteGeometry.distanceMeters(origin, station.coordinate) < options.stubWalkBelowMeters {
            plan = stubWalk(from: origin, to: station.coordinate, name: station.name)
        } else {
            plan = try await walking.walkingRoute(from: origin, to: station.coordinate, name: station.name)
        }
        return kind == .destination ? plan : plan.relabelingFinalBeacon(kind: kind, instruction: instruction, coordinate: station.coordinate)
    }

    /// Two checkpoints and one final beacon; satisfies `NavigationSession.start` when the user is already at the stop.
    static func stubWalk(from origin: CLLocationCoordinate2D, to target: CLLocationCoordinate2D, name: String) -> RoutePlan {
        let bearing = RouteGeometry.bearingDegrees(from: origin, to: target)
        let distance = RouteGeometry.distanceMeters(origin, target)
        return RoutePlan(destinationName: name, checkpoints: [
            RouteCheckpoint(coordinate: origin, distanceFromStartMeters: 0, stepIndex: 0, stepInstruction: "Continue to \(name)", bearingToNextDegrees: bearing),
            RouteCheckpoint(coordinate: target, distanceFromStartMeters: distance, stepIndex: 0, stepInstruction: "Arrive at \(name)", bearingToNextDegrees: bearing)
        ], beacons: [PingTarget(coordinate: target, instruction: "You have arrived", isFinalDestination: true, bearingAfterTurnDegrees: bearing, kind: .destination)],
           expectedTravelTime: distance / 1.3)
    }

    /// Green Line branches share track through downtown; for a rider they are one line.
    static func family(_ routeID: String) -> String { routeID.hasPrefix("Green-") ? "Green" : routeID }

    static func rideLeg(_ pattern: RidePattern, board: Int, alight: Int, routeInfo: [String: TransitRoute], patterns: [RidePattern]) -> RideLeg {
        let boardStop = pattern.stops[board], alightStop = pattern.stops[alight]
        // Every variant of this route family/direction that serves both stops in order is acceptable.
        let siblings = patterns.filter { family($0.routeID) == family(pattern.routeID) && $0.directionID == pattern.directionID }
            .filter { sibling in
                guard let b = sibling.index(ofStation: boardStop.stationID), let a = sibling.index(ofStation: alightStop.stationID) else { return false }
                return b < a
            }
        let boardPlatforms = Set(siblings.flatMap { $0.stops.filter { $0.stationID == boardStop.stationID }.map(\.platformID) })
        let alightPlatforms = Set(siblings.flatMap { $0.stops.filter { $0.stationID == alightStop.stationID }.map(\.platformID) })
        var routeIDs = Array(Set(siblings.map(\.routeID) + [pattern.routeID])).sorted()
        var route = routeInfo[pattern.routeID] ?? TransitRoute(id: pattern.routeID, name: pattern.routeID, colorHex: "888888", type: 3)
        if routeIDs.count > 1, family(pattern.routeID) == "Green" {
            route = TransitRoute(id: "Green", name: "Green Line", colorHex: "00843D", type: 0)
        } else { routeIDs = [pattern.routeID] }
        // Any branch that serves both stops will do, so name them all: "toward Ashmont or Braintree".
        var headsigns: [String] = []
        for sign in ([pattern.headsign] + siblings.map(\.headsign)) where !sign.isEmpty && !headsigns.contains(sign) { headsigns.append(sign) }
        return RideLeg(route: route, routeIDs: routeIDs, directionID: pattern.directionID, headsign: headsigns.sorted().joined(separator: " or "),
                       board: station(boardStop), alight: station(alightStop),
                       acceptablePatternIDs: Set(siblings.map(\.id)).union([pattern.id]),
                       boardPlatformIDs: boardPlatforms.union([boardStop.platformID]),
                       alightPlatformIDs: alightPlatforms.union([alightStop.platformID]),
                       platformOrder: pattern.stops.map(\.platformID), stopsRidden: alight - board,
                       path: slice(pattern.shape, from: boardStop.coordinate, to: alightStop.coordinate, fallback: pattern.stops[board...alight].map(\.coordinate)))
    }

    static func station(_ stop: PatternStop) -> TransitStation {
        TransitStation(id: stop.stationID, name: stop.name, coordinate: stop.coordinate, wheelchairAccessible: nil)
    }

    /// The drawn ride path: the shape between the vertices nearest each stop, else the stop chain.
    static func slice(_ shape: [CLLocationCoordinate2D], from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D,
                      fallback: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard shape.count >= 2 else { return fallback }
        func nearest(_ point: CLLocationCoordinate2D) -> Int {
            shape.indices.min { RouteGeometry.distanceMeters(shape[$0], point) < RouteGeometry.distanceMeters(shape[$1], point) }!
        }
        let a = nearest(start), b = nearest(end)
        guard a < b else { return fallback }
        return Array(shape[a...b])
    }

    static func minutes(_ plan: RoutePlan) -> Int {
        let seconds = plan.expectedTravelTime ?? (plan.checkpoints.last?.distanceFromStartMeters ?? 0) / 1.3
        return max(1, Int((seconds / 60).rounded()))
    }

    static func summary(rides: [RideLeg], walkMinutes: [Int], destinationName: String) -> String {
        var parts: [String] = []
        for (index, ride) in rides.enumerated() {
            let lead = index == 0 ? "Walk \(plural(walkMinutes.first ?? 1, "minute")) to \(ride.board.name), then take" : "then change to"
            let stops = ride.stopsRidden == 1 ? "1 stop" : "\(ride.stopsRidden) stops"
            parts.append("\(lead) the \(ride.route.name) toward \(ride.headsign) \(stops) to \(ride.alight.name)")
        }
        parts.append("then walk \(plural(walkMinutes.last ?? 1, "minute")) to \(destinationName).")
        return parts.joined(separator: ", ")
    }

    static func plural(_ count: Int, _ unit: String) -> String { "\(count) \(unit)\(count == 1 ? "" : "s")" }
}
