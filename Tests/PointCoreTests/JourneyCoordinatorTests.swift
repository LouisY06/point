import CoreLocation
import Foundation
import Testing
@testable import PointCore

@MainActor struct JourneyCoordinatorTests {
    let epoch = Date(timeIntervalSince1970: 50_000)

    /// Walk (stub, 2 checkpoints) → Red Kendall→Park St → transfer → Green Park St→Copley → walk.
    func makePlan() -> JourneyPlan {
        let origin = FakeTransit.point(8, -0.0003)
        let kendall = FakeTransit.stations[1], park = FakeTransit.stations[3], copley = FakeTransit.stations[8]
        let walk1 = TransitPlanner.stubWalk(from: origin, to: kendall.coordinate, name: kendall.name)
            .relabelingFinalBeacon(kind: .boardStop, instruction: "Board the Red Line toward Ashmont here")
        let red = TransitPlanner.rideLeg(FakeTransit.redSouth, board: 1, alight: 3,
                                         routeInfo: ["Red": TransitRoute.rapidTransit[0]], patterns: [FakeTransit.redSouth, FakeTransit.redSouthBraintree])
        let green = TransitPlanner.rideLeg(FakeTransit.greenWest, board: 0, alight: 3,
                                           routeInfo: ["Green-B": TransitRoute.rapidTransit[3]], patterns: [FakeTransit.greenWest])  // single branch: stays Green-B
        let walk2 = TransitPlanner.stubWalk(from: copley.coordinate, to: FakeTransit.point(16.0002, 12), name: "Library")
        return JourneyPlan(destinationName: "Library", legs: [.walk(walk1), .ride(red), .transfer(park), .ride(green), .walk(walk2)], summary: "test")
    }

    func fix(_ coordinate: CLLocationCoordinate2D, seconds: Double, accuracy: Double = 5) -> CLLocation {
        CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 3, timestamp: epoch.addingTimeInterval(seconds))
    }

    func arrival(_ trip: String, pattern: String = "Red-1-0", status: VehicleStatus.Status, platform: String, seconds: Int = 60) -> TransitArrival {
        TransitArrival(tripID: trip, patternID: pattern, headsign: "Ashmont", time: epoch.addingTimeInterval(Double(seconds)), status: nil,
                       vehicle: VehicleStatus(vehicleID: "V-\(trip)", status: status, platformStopID: platform, coordinate: nil, updatedAt: epoch))
    }

    @Test func fullJourneyWalksWaitsRidesTransfersAndArrives() throws {
        let glove = SimulatedGlove(); glove.connect()
        let controller = PointController(glove: glove)
        let transit = FakeTransit()
        let coordinator = JourneyCoordinator(controller: controller, transit: transit, pollInterval: .seconds(60))
        var events: [JourneyCoordinator.Event] = []
        coordinator.onEvent = { events.append($0) }
        let plan = makePlan()
        let kendall = FakeTransit.stations[1]

        try coordinator.start(plan, at: fix(FakeTransit.point(8, -0.0003), seconds: 0), now: epoch)
        #expect(coordinator.phase == .walking(leg: 0))
        #expect(controller.navigation.state == .navigating)
        #expect(controller.navigation.activeBeacon?.kind == .boardStop)

        // 30 m from the station entrance is "reached": the 8 m/8 m session rule never fires underground.
        coordinator.updateLocation(fix(FakeTransit.point(8, 0.0003), seconds: 5), now: epoch.addingTimeInterval(5))
        #expect(coordinator.phase == .waitingAtStop(leg: 1))
        #expect(controller.navigation.state == .idle && controller.navigation.activeBeacon == nil) // No beacons while waiting.
        #expect(events.contains(.reachedStop(plan.rides[0])))

        // A northbound train (wrong pattern) at the platform must not cue; a Braintree train stopped at our platform must.
        let wrongDirection = TransitArrival(tripID: "north", patternID: "Red-1-1", headsign: "Alewife", time: nil, status: nil,
                                            vehicle: VehicleStatus(vehicleID: "N", status: .stoppedAt, platformStopID: "r-kendall-n", coordinate: nil, updatedAt: epoch))
        coordinator.handleArrivals([wrongDirection, arrival("trip-A", pattern: "Red-3-0", status: .inTransitTo, platform: "r-kendall-s", seconds: 120)], now: epoch.addingTimeInterval(10))
        #expect(coordinator.phase == .waitingAtStop(leg: 1))
        #expect(coordinator.countdown?.secondsAway == 110 && coordinator.countdown?.headsign == "Ashmont")
        #expect(!glove.commands.contains(.vehicleArrived))

        coordinator.handleArrivals([arrival("trip-A", pattern: "Red-3-0", status: .stoppedAt, platform: "r-kendall-s")], now: epoch.addingTimeInterval(20))
        #expect(coordinator.phase == .vehicleArriving(leg: 1, tripID: "trip-A"))
        #expect(glove.commands.filter { $0 == .vehicleArrived }.count == 1)
        coordinator.handleArrivals([arrival("trip-A", pattern: "Red-3-0", status: .stoppedAt, platform: "r-kendall-s")], now: epoch.addingTimeInterval(25))
        #expect(glove.commands.filter { $0 == .vehicleArrived }.count == 1) // Same trip/status cues once.

        // The train leaves toward Charles: tentative boarding until confirmed.
        coordinator.handleArrivals([arrival("trip-A", pattern: "Red-3-0", status: .inTransitTo, platform: "r-charles-s")], now: epoch.addingTimeInterval(40))
        #expect(coordinator.phase == .riding(leg: 1, tripID: "trip-A", confirmed: false, tracking: .live))
        coordinator.confirmBoarded(now: epoch.addingTimeInterval(41))
        #expect(coordinator.phase == .riding(leg: 1, tripID: "trip-A", confirmed: true, tracking: .live))
        #expect(controller.navigation.activeBeacon == nil)

        // Riding: heading to Park St announces "next stop", stopping there cues alighting.
        coordinator.handleVehicle(VehicleStatus(vehicleID: "V", status: .inTransitTo, platformStopID: "r-park-s", coordinate: nil, updatedAt: epoch), now: epoch.addingTimeInterval(200))
        #expect(events.contains(.nextStopIsYours(plan.rides[0])))
        coordinator.handleVehicle(VehicleStatus(vehicleID: "V", status: .stoppedAt, platformStopID: "r-park-s", coordinate: nil, updatedAt: epoch), now: epoch.addingTimeInterval(260))
        #expect(coordinator.phase == .alighting(leg: 1, tripID: "trip-A"))
        #expect(glove.commands.filter { $0 == .vehicleArrived }.count == 2)

        // Off the train at Park St: the transfer leg skips straight to waiting for the Green Line.
        coordinator.confirmAlighted(now: epoch.addingTimeInterval(270))
        #expect(coordinator.phase == .waitingAtStop(leg: 3))
        #expect(events.contains(.alighted(plan.rides[0])) && events.contains(.reachedStop(plan.rides[1])))

        let green = TransitArrival(tripID: "trip-G", patternID: "Green-B-0", headsign: "Boston College", time: nil, status: nil,
                                   vehicle: VehicleStatus(vehicleID: "G", status: .incomingAt, platformStopID: "g-park-w", coordinate: nil, updatedAt: epoch))
        coordinator.handleArrivals([green], now: epoch.addingTimeInterval(400))
        #expect(coordinator.phase == .vehicleArriving(leg: 3, tripID: "trip-G"))
        coordinator.confirmBoarded(now: epoch.addingTimeInterval(410))
        coordinator.handleVehicle(VehicleStatus(vehicleID: "G", status: .incomingAt, platformStopID: "g-copley-w", coordinate: nil, updatedAt: epoch), now: epoch.addingTimeInterval(700))
        #expect(coordinator.phase == .alighting(leg: 3, tripID: "trip-G"))

        // Vehicle departs Copley with a fresh fix near the station: automatic alighting starts the last walk.
        coordinator.updateLocation(fix(FakeTransit.point(16, 12.0002), seconds: 705), now: epoch.addingTimeInterval(705))
        coordinator.handleVehicle(VehicleStatus(vehicleID: "G", status: .inTransitTo, platformStopID: "g-beyond", coordinate: nil, updatedAt: epoch), now: epoch.addingTimeInterval(710))
        #expect(coordinator.phase == .walking(leg: 4))
        #expect(controller.navigation.state == .navigating && controller.navigation.activeBeacon?.kind == .destination)
        #expect(events.contains(.walkingLegStarted(leg: 4, toward: "Library")))
        #expect(kendall.id == "place-knncl")
        coordinator.stop()
        #expect(coordinator.phase == .idle && coordinator.plan == nil && controller.navigation.state == .idle)
    }

    @Test func staleResultsAndUndoDoNotMoveTheJourney() throws {
        let glove = SimulatedGlove(); glove.connect()
        let coordinator = JourneyCoordinator(controller: PointController(glove: glove), transit: FakeTransit(), pollInterval: .seconds(60))
        let plan = makePlan()
        try coordinator.start(plan, at: nil, now: epoch)
        coordinator.confirmAtStop(now: epoch)
        #expect(coordinator.phase == .waitingAtStop(leg: 1))
        coordinator.handleArrivals([arrival("trip-A", status: .stoppedAt, platform: "r-kendall-s")], now: epoch)
        coordinator.handleArrivals([arrival("trip-A", status: .inTransitTo, platform: "r-charles-s")], now: epoch.addingTimeInterval(30))
        #expect(coordinator.phase == .riding(leg: 1, tripID: "trip-A", confirmed: false, tracking: .live))

        // "Not on board" returns to waiting; the same train's later positions are ignored there.
        coordinator.notOnBoard(now: epoch.addingTimeInterval(35))
        #expect(coordinator.phase == .waitingAtStop(leg: 1))
        coordinator.handleVehicle(VehicleStatus(vehicleID: "V", status: .stoppedAt, platformStopID: "r-park-s", coordinate: nil, updatedAt: epoch), now: epoch.addingTimeInterval(200))
        #expect(coordinator.phase == .waitingAtStop(leg: 1))

        // Missed the train: 90 s after an automatic departure, a fresh fix still at the stop reverts to waiting.
        coordinator.handleArrivals([arrival("trip-B", status: .stoppedAt, platform: "r-kendall-s")], now: epoch.addingTimeInterval(300))
        coordinator.handleArrivals([arrival("trip-B", status: .inTransitTo, platform: "r-charles-s")], now: epoch.addingTimeInterval(310))
        #expect(coordinator.phase == .riding(leg: 1, tripID: "trip-B", confirmed: false, tracking: .live))
        coordinator.updateLocation(fix(FakeTransit.stations[1].coordinate, seconds: 395), now: epoch.addingTimeInterval(395))
        coordinator.tick(now: epoch.addingTimeInterval(400))
        #expect(coordinator.phase == .waitingAtStop(leg: 1))

        // Three missing vehicle reads while riding flag lost tracking; a read restores it.
        coordinator.handleArrivals([arrival("trip-C", status: .stoppedAt, platform: "r-kendall-s")], now: epoch.addingTimeInterval(500))
        coordinator.confirmBoarded(now: epoch.addingTimeInterval(501))
        for _ in 0..<3 { coordinator.handleVehicle(nil, now: epoch.addingTimeInterval(520)) }
        #expect(coordinator.phase == .riding(leg: 1, tripID: "trip-C", confirmed: true, tracking: .lost))
        coordinator.handleVehicle(VehicleStatus(vehicleID: "V", status: .inTransitTo, platformStopID: "r-charles-s", coordinate: nil, updatedAt: epoch), now: epoch.addingTimeInterval(530))
        #expect(coordinator.phase == .riding(leg: 1, tripID: "trip-C", confirmed: true, tracking: .live))

        // Stop discards everything; late reducer calls are no-ops.
        coordinator.stop()
        coordinator.handleVehicle(VehicleStatus(vehicleID: "V", status: .stoppedAt, platformStopID: "r-park-s", coordinate: nil, updatedAt: epoch), now: epoch.addingTimeInterval(600))
        #expect(coordinator.phase == .idle)
    }

    @Test func instructionsWaitForGPSAfterAlightingUnderground() throws {
        let glove = SimulatedGlove(); glove.connect()
        let coordinator = JourneyCoordinator(controller: PointController(glove: glove), transit: FakeTransit(), pollInterval: .seconds(60))
        var events: [JourneyCoordinator.Event] = []
        coordinator.onEvent = { events.append($0) }
        // A two-leg plan: walk → Green Park St→Copley → walk, alighting with no GPS for minutes.
        let park = FakeTransit.stations[3], copley = FakeTransit.stations[8]
        let walk1 = TransitPlanner.stubWalk(from: FakeTransit.point(16, -0.0002), to: park.coordinate, name: park.name)
            .relabelingFinalBeacon(kind: .boardStop, instruction: "Board here")
        let green = TransitPlanner.rideLeg(FakeTransit.greenWest, board: 0, alight: 3, routeInfo: [:], patterns: [FakeTransit.greenWest])
        let walk2 = TransitPlanner.stubWalk(from: copley.coordinate, to: FakeTransit.point(16.0003, 12), name: "Café")
        try coordinator.start(JourneyPlan(destinationName: "Café", legs: [.walk(walk1), .ride(green), .walk(walk2)], summary: ""), at: nil, now: epoch)
        coordinator.confirmAtStop(now: epoch)
        coordinator.handleArrivals([TransitArrival(tripID: "g", patternID: "Green-B-0", headsign: "BC", time: nil, status: nil,
                                                   vehicle: VehicleStatus(vehicleID: "G", status: .stoppedAt, platformStopID: "g-park-w", coordinate: nil, updatedAt: epoch))], now: epoch)
        coordinator.confirmBoarded(now: epoch.addingTimeInterval(1))
        coordinator.confirmAlighted(now: epoch.addingTimeInterval(600)) // Last fix is 10 minutes old.
        #expect(coordinator.phase == .walking(leg: 2))
        #expect(coordinator.awaitingSignal)
        #expect(events.contains(.awaitingSignal(leg: 2)))
        #expect(!events.contains(.signalRestored(leg: 2)))
        // A poor fix inside the station does not count; the first accurate fresh one does.
        coordinator.updateLocation(fix(copley.coordinate, seconds: 620, accuracy: 80), now: epoch.addingTimeInterval(621))
        #expect(coordinator.awaitingSignal)
        coordinator.updateLocation(fix(FakeTransit.point(16.0001, 12), seconds: 660, accuracy: 8), now: epoch.addingTimeInterval(661))
        #expect(!coordinator.awaitingSignal)
        #expect(events.contains(.signalRestored(leg: 2)))
    }

    @Test func testModeCuesArrivalsAtTheBoardStopWhileStillWalking() throws {
        let glove = SimulatedGlove(); glove.connect()
        let coordinator = JourneyCoordinator(controller: PointController(glove: glove), transit: FakeTransit(), pollInterval: .seconds(60))
        var events: [JourneyCoordinator.Event] = []
        coordinator.onEvent = { events.append($0) }
        let plan = makePlan()
        try coordinator.start(plan, at: nil, now: epoch)
        #expect(coordinator.phase == .walking(leg: 0))
        // A train stopped at our platform while we are still walking: buzz once, stay walking, show the countdown.
        coordinator.handleArrivals([arrival("trip-A", status: .stoppedAt, platform: "r-kendall-s", seconds: 30)], now: epoch)
        #expect(coordinator.phase == .walking(leg: 0))
        #expect(glove.commands.filter { $0 == .vehicleArrived }.count == 1)
        #expect(events.contains(.vehicleArriving(plan.rides[0])))
        #expect(coordinator.countdown?.secondsAway == 30)
        coordinator.handleArrivals([arrival("trip-A", status: .stoppedAt, platform: "r-kendall-s", seconds: 20)], now: epoch.addingTimeInterval(10))
        #expect(glove.commands.filter { $0 == .vehicleArrived }.count == 1) // Same trip/status: no repeat.
        // Wrong direction never cues; a different trip that is imminent (no vehicle yet) does.
        coordinator.handleArrivals([TransitArrival(tripID: "north", patternID: "Red-1-1", headsign: "Alewife", time: epoch.addingTimeInterval(70), status: nil,
                                                   vehicle: VehicleStatus(vehicleID: "N", status: .stoppedAt, platformStopID: "r-kendall-n", coordinate: nil, updatedAt: epoch)),
                                    TransitArrival(tripID: "trip-B", patternID: "Red-3-0", headsign: "Braintree", time: epoch.addingTimeInterval(100), status: nil, vehicle: nil)],
                                   now: epoch.addingTimeInterval(60))
        #expect(glove.commands.filter { $0 == .vehicleArrived }.count == 2)
        // Off by default when test mode is disabled.
        let quiet = JourneyCoordinator(controller: PointController(glove: glove), transit: FakeTransit(), pollInterval: .seconds(60))
        quiet.cueArrivalsWhileWalking = false
        try quiet.start(makePlan(), at: nil, now: epoch)
        let before = glove.commands.count
        quiet.handleArrivals([arrival("trip-C", status: .stoppedAt, platform: "r-kendall-s")], now: epoch)
        #expect(glove.commands.count == before)
    }

    @Test func wrongTrainAndMissedStopAskForAReplan() throws {
        let glove = SimulatedGlove(); glove.connect()
        let coordinator = JourneyCoordinator(controller: PointController(glove: glove), transit: FakeTransit(), pollInterval: .seconds(60))
        try coordinator.start(makePlan(), at: nil, now: epoch)
        coordinator.confirmAtStop(now: epoch)
        coordinator.handleArrivals([arrival("trip-A", status: .stoppedAt, platform: "r-kendall-s")], now: epoch)
        coordinator.confirmBoarded(now: epoch.addingTimeInterval(1))
        // The vehicle is 700 m from two consecutive fresh fixes.
        let farVehicle = VehicleStatus(vehicleID: "V", status: .inTransitTo, platformStopID: "r-charles-s", coordinate: FakeTransit.point(12, 0), updatedAt: epoch)
        coordinator.updateLocation(fix(FakeTransit.point(8, -8), seconds: 100), now: epoch.addingTimeInterval(100))
        coordinator.handleVehicle(farVehicle, now: epoch.addingTimeInterval(101))
        coordinator.updateLocation(fix(FakeTransit.point(8, -8), seconds: 110), now: epoch.addingTimeInterval(110))
        coordinator.handleVehicle(farVehicle, now: epoch.addingTimeInterval(111))
        #expect(coordinator.phase == .needsReplan(reason: "You may be on the wrong train."))
    }
}
