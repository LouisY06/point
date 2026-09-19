import Combine
import CoreLocation
import Foundation

/// Drives a multi-leg journey above the unchanged `PointController`: one walking session per walk
/// leg, and MBTA polling while waiting for or riding a vehicle. There are no beacons and no
/// pointing feedback between boarding and alighting. Every transition bumps a token, and every
/// awaited result checks it, so a late response can never move a journey it no longer belongs to.
@MainActor public final class JourneyCoordinator: ObservableObject {
    public enum Tracking: Equatable { case live, lost }

    public enum Phase: Equatable {
        case idle
        case walking(leg: Int)
        case waitingAtStop(leg: Int)
        case vehicleArriving(leg: Int, tripID: String)
        /// `confirmed` is false after an automatic departure until the user confirms boarding.
        case riding(leg: Int, tripID: String, confirmed: Bool, tracking: Tracking)
        case alighting(leg: Int, tripID: String)
        case needsReplan(reason: String)
        case arrived

        public var legIndex: Int? {
            switch self {
            case .walking(let leg), .waitingAtStop(let leg), .vehicleArriving(let leg, _), .riding(let leg, _, _, _), .alighting(let leg, _): return leg
            case .idle, .needsReplan, .arrived: return nil
            }
        }
        public var isRiding: Bool { if case .riding = self { return true } else { return false } }
    }

    public enum Event: Equatable {
        case walkingLegStarted(leg: Int, toward: String)
        case reachedStop(RideLeg)
        case vehicleArriving(RideLeg)
        case departedTentatively(RideLeg)
        case boarded(RideLeg)
        case notOnBoard(RideLeg)
        case nextStopIsYours(RideLeg)
        case alightHere(RideLeg)
        case alighted(RideLeg)
        case trackingLost(RideLeg)
        /// Off the vehicle but still underground: hold walking instructions until GPS returns.
        case awaitingSignal(leg: Int)
        case signalRestored(leg: Int)
        case liveDataLost
        case liveDataRestored
        case needsReplan(String)
        case arrived
        case notice(String)
    }

    public struct Countdown: Equatable {
        public let headsign: String
        public let secondsAway: Int?
        public let status: String?
        public let routeName: String
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var plan: JourneyPlan?
    @Published public private(set) var countdown: Countdown?
    @Published public private(set) var alerts: [TransitAlert] = []
    @Published public private(set) var liveDataAvailable = true
    /// True from alighting until a fresh, accurate fix proves we are back outside. The walking
    /// session runs (so the map is right) but no instructions or pointing should be given.
    @Published public private(set) var awaitingSignal = false
    /// Test mode: watch the next ride's board stop from the moment a walking leg starts, and cue
    /// `vehicleArrived` whenever a vehicle on that route/direction arrives there, without requiring
    /// the rider to be at the stop. Later this narrows to "at the stop and arriving".
    public var cueArrivalsWhileWalking = true
    public var onEvent: ((Event) -> Void)?

    public let controller: PointController
    private let transit: any TransitDataSource
    private let pollInterval: Duration
    private var phaseToken = UUID()
    private var poll: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var lastFix: CLLocation?
    private var lastNearBoardStopAt: Date?
    private var departedAt: Date?
    private var cued: Set<String> = []
    private var vehicleMisses = 0
    private var farFromVehiclePolls = 0

    public init(controller: PointController, transit: any TransitDataSource, pollInterval: Duration = .seconds(10)) {
        self.controller = controller
        self.transit = transit
        self.pollInterval = pollInterval
        controller.navigation.$state.sink { [weak self] state in
            guard let self, state == .arrived, case .walking(let leg) = phase else { return }
            walkLegCompleted(leg)
        }.store(in: &subscriptions)
    }

    // MARK: Lifecycle

    public func start(_ plan: JourneyPlan, at fix: CLLocation? = nil, now: Date = Date()) throws {
        stop()
        self.plan = plan
        lastFix = fix
        guard case .walk(let walk)? = plan.legs.first else { throw ServiceError.noRoute }
        try beginWalk(leg: 0, walk, at: fix, now: now)
    }

    public func stop() {
        advance(.idle)
        plan = nil
        countdown = nil
        alerts = []
        lastFix = nil
        lastNearBoardStopAt = nil
        departedAt = nil
        cued = []
        awaitingSignal = false
        liveDataAvailable = true
        controller.stop()
    }

    static func isFresh(_ fix: CLLocation?, now: Date) -> Bool {
        guard let fix else { return false }
        return fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= 25 && (0...5).contains(now.timeIntervalSince(fix.timestamp))
    }

    /// Manual overrides. Each is a no-op outside the phase it belongs to.
    public func confirmAtStop(now: Date = Date()) {
        guard case .walking(let leg) = phase, rideIndex(after: leg) != nil else { return }
        walkLegCompleted(leg, now: now)
    }

    public func confirmBoarded(now: Date = Date()) {
        switch phase {
        case .vehicleArriving(let leg, let trip):
            beginRiding(leg: leg, tripID: trip, confirmed: true, now: now)
        case .riding(let leg, let trip, false, let tracking):
            advance(.riding(leg: leg, tripID: trip, confirmed: true, tracking: tracking), keepPolling: true)
            if let ride = ride(at: leg) { onEvent?(.boarded(ride)) }
        default: break
        }
    }

    public func notOnBoard(now: Date = Date()) {
        guard case .riding(let leg, _, _, _) = phase, let ride = ride(at: leg) else { return }
        onEvent?(.notOnBoard(ride))
        beginWaiting(leg: leg, now: now)
    }

    public func confirmAlighted(now: Date = Date()) {
        switch phase {
        case .alighting(let leg, _), .riding(let leg, _, _, _): alighted(leg: leg, now: now)
        default: break
        }
    }

    // MARK: Inputs

    public func updateLocation(_ fix: CLLocation, now: Date = Date()) {
        lastFix = fix
        if awaitingSignal, case .walking(let leg) = phase, Self.isFresh(fix, now: now) {
            awaitingSignal = false
            onEvent?(.signalRestored(leg: leg))
        }
        guard case .walking(let leg) = phase, let rideLeg = rideIndex(after: leg), let ride = ride(at: rideLeg) else { return }
        let distance = RouteGeometry.distanceMeters(fix.coordinate, ride.board.coordinate)
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 50 else { return }
        if distance <= 150 { lastNearBoardStopAt = now }
        // The session's 8 m / 8 m arrival rule rarely triggers at a station entrance; 40 m is enough.
        if distance <= 40 { walkLegCompleted(leg, now: now) }
    }

    /// Foreground heartbeat, also called on scene activation to reconcile after a suspension.
    public func tick(now: Date = Date()) {
        switch phase {
        case .walking(let leg):
            // Fixes stopped shortly after being near the stop: assume we went underground.
            if let near = lastNearBoardStopAt, now.timeIntervalSince(near) <= 90,
               let fix = lastFix, now.timeIntervalSince(fix.timestamp) > 20 {
                walkLegCompleted(leg, now: now)
            }
        case .riding(let leg, _, false, _):
            // The train left without us: still within 50 m of the board stop well after departure.
            if let departedAt, now.timeIntervalSince(departedAt) >= 90, let fix = lastFix,
               now.timeIntervalSince(fix.timestamp) <= 30, fix.horizontalAccuracy <= 50, let ride = ride(at: leg),
               RouteGeometry.distanceMeters(fix.coordinate, ride.board.coordinate) <= 50 {
                onEvent?(.notice("Looks like you're still at \(ride.board.name). Waiting for the next \(ride.route.name)."))
                beginWaiting(leg: leg, now: now)
            }
        default: break
        }
        if poll == nil { resumePolling() }
    }

    // MARK: Reducers (internal for tests; the poll loops call them)

    func handleArrivals(_ arrivals: [TransitArrival], now: Date) {
        // While walking, the ride of interest is the one this leg leads to.
        guard let current = phase.legIndex else { return }
        let leg: Int
        if case .walking = phase { guard let next = rideIndex(after: current) else { return }; leg = next } else { leg = current }
        guard let ride = ride(at: leg) else { return }
        let acceptable = arrivals.filter { $0.patternID == nil || ride.acceptablePatternIDs.contains($0.patternID!) }
        switch phase {
        case .walking:
            // Test mode: cue every arrival of our route/direction at the board stop while still walking.
            guard cueArrivalsWhileWalking else { return }
            countdown = acceptable.first.map { Countdown(headsign: $0.headsign.isEmpty ? ride.headsign : $0.headsign, secondsAway: $0.secondsAway(now: now),
                                                          status: $0.status, routeName: ride.route.name) }
            for arrival in acceptable {
                let atPlatform = arrival.vehicle.map { vehicle in
                    vehicle.platformStopID.map { ride.boardPlatformIDs.contains($0) } == true && (vehicle.status == .stoppedAt || vehicle.status == .incomingAt)
                } ?? false
                let imminent = (arrival.secondsAway(now: now) ?? .max) <= 45
                guard atPlatform || imminent else { continue }
                let key = "\(arrival.tripID)/\(atPlatform ? arrival.vehicle!.status.rawValue : "imminent")"
                if cued.insert(key).inserted {
                    controller.emit(.vehicleArrived)
                    onEvent?(.vehicleArriving(ride))
                }
            }
        case .waitingAtStop, .vehicleArriving:
            let next = acceptable.first
            countdown = next.map { Countdown(headsign: $0.headsign.isEmpty ? ride.headsign : $0.headsign, secondsAway: $0.secondsAway(now: now),
                                              status: $0.status, routeName: ride.route.name) }
            if case .vehicleArriving(_, let trip) = phase {
                // Our flagged vehicle moved on to the next platform (or vanished from this stop): it departed.
                let current = acceptable.first { $0.tripID == trip }
                let departed = current?.vehicle.map { vehicle in
                    vehicle.status == .inTransitTo && vehicle.platformStopID.map { !ride.boardPlatformIDs.contains($0) } == true
                } ?? true
                if departed { beginRiding(leg: leg, tripID: trip, confirmed: false, now: now); return }
            }
            for arrival in acceptable {
                guard let vehicle = arrival.vehicle, let platform = vehicle.platformStopID, ride.boardPlatformIDs.contains(platform),
                      vehicle.status == .stoppedAt || vehicle.status == .incomingAt else { continue }
                let key = "\(arrival.tripID)/\(vehicle.status.rawValue)"
                if cued.insert(key).inserted {
                    controller.emit(.vehicleArrived)
                    onEvent?(.vehicleArriving(ride))
                }
                if case .waitingAtStop = phase { advance(.vehicleArriving(leg: leg, tripID: arrival.tripID), keepPolling: true) }
                break
            }
        default: break
        }
    }

    func handleVehicle(_ vehicle: VehicleStatus?, now: Date) {
        guard let leg = phase.legIndex, let ride = ride(at: leg) else { return }
        guard let vehicle else {
            vehicleMisses += 1
            if vehicleMisses >= 3, case .riding(let leg, let trip, let confirmed, .live) = phase {
                advance(.riding(leg: leg, tripID: trip, confirmed: confirmed, tracking: .lost), keepPolling: true)
                onEvent?(.trackingLost(ride))
            }
            return
        }
        vehicleMisses = 0
        switch phase {
        case .riding(let leg, let trip, let confirmed, let tracking):
            if tracking == .lost { advance(.riding(leg: leg, tripID: trip, confirmed: confirmed, tracking: .live), keepPolling: true) }
            if let platform = vehicle.platformStopID, ride.alightPlatformIDs.contains(platform) {
                if vehicle.status == .inTransitTo, cued.insert("\(trip)/next").inserted { onEvent?(.nextStopIsYours(ride)) }
                if vehicle.status == .stoppedAt || vehicle.status == .incomingAt {
                    if cued.insert("\(trip)/alight").inserted {
                        controller.emit(.vehicleArrived)
                        onEvent?(.alightHere(ride))
                    }
                    advance(.alighting(leg: leg, tripID: trip), keepPolling: true)
                }
            }
            // A fresh GPS fix far from the tracked vehicle on consecutive polls: probably the wrong train.
            if let fix = lastFix, now.timeIntervalSince(fix.timestamp) <= 30, fix.horizontalAccuracy <= 50, let position = vehicle.coordinate {
                farFromVehiclePolls = RouteGeometry.distanceMeters(fix.coordinate, position) > 500 ? farFromVehiclePolls + 1 : 0
                if farFromVehiclePolls >= 2 { replan("You may be on the wrong \(ride.route.isBus ? "bus" : "train")."); return }
            }
        case .alighting(let leg, _):
            let departed = vehicle.status == .inTransitTo && vehicle.platformStopID.map { !ride.alightPlatformIDs.contains($0) } == true
            guard departed else { return }
            if let fix = lastFix, now.timeIntervalSince(fix.timestamp) <= 30, fix.horizontalAccuracy <= 50 {
                let distance = RouteGeometry.distanceMeters(fix.coordinate, ride.alight.coordinate)
                if distance <= 100 { alighted(leg: leg, now: now) }
                else if distance > 300 { replan("You may have missed \(ride.alight.name).") }
            } else if cued.insert("\(leg)/tap-off").inserted {
                onEvent?(.notice("If you're off the \(ride.route.isBus ? "bus" : "train") at \(ride.alight.name), tap I'm off."))
            }
        default: break
        }
    }

    // MARK: Transitions

    private func beginWalk(leg: Int, _ walk: RoutePlan, at fix: CLLocation?, now: Date) throws {
        advance(.walking(leg: leg))
        lastNearBoardStopAt = nil
        awaitingSignal = false
        try controller.start(walk, at: fix)
        onEvent?(.walkingLegStarted(leg: leg, toward: walk.destinationName))
        if cueArrivalsWhileWalking, let rideLeg = rideIndex(after: leg), let ride = ride(at: rideLeg) {
            countdown = nil
            startPolling(every: pollInterval) { [weak self] in
                guard let self else { return { _ in } }
                let result = try? await transit.arrivals(at: ride.board, route: ride.routeFilter, directionID: ride.directionID)
                return { now in self.applyArrivalsPoll(result, now: now) }
            }
        }
    }

    private func walkLegCompleted(_ leg: Int, now: Date = Date()) {
        guard case .walking(leg) = phase else { return }
        guard let rideLeg = rideIndex(after: leg) else { advance(.arrived); controller.stop(); onEvent?(.arrived); return }
        beginWaiting(leg: rideLeg, now: now)
    }

    private func beginWaiting(leg: Int, now: Date) {
        guard let ride = ride(at: leg) else { return }
        advance(.waitingAtStop(leg: leg))
        controller.stop() // No beacons or pointing feedback until we are off the vehicle.
        departedAt = nil
        countdown = nil
        onEvent?(.reachedStop(ride))
        startPolling(every: pollInterval) { [weak self] in
            guard let self else { return { _ in } }
            let result = try? await transit.arrivals(at: ride.board, route: ride.routeFilter, directionID: ride.directionID)
            return { now in self.applyArrivalsPoll(result, now: now) }
        }
        let token = phaseToken
        Task { [weak self] in
            guard let self else { return }
            let found = (try? await transit.alerts(routes: ride.routeIDs, stations: [ride.board.id, ride.alight.id])) ?? []
            guard phaseToken == token else { return }
            alerts = found
        }
    }

    /// Underground the MBTA request itself fails. Say so once, stay quiet, and say once when it returns.
    private func applyArrivalsPoll(_ result: [TransitArrival]?, now: Date) {
        if let result {
            if !liveDataAvailable { liveDataAvailable = true; onEvent?(.liveDataRestored) }
            handleArrivals(result, now: now)
        } else if liveDataAvailable {
            liveDataAvailable = false
            countdown = nil
            onEvent?(.liveDataLost)
        }
    }

    private func applyVehiclePoll(_ result: VehicleStatus??, now: Date) {
        // `nil` outer = request failed (no signal); `nil` inner = MBTA has no vehicle for the trip.
        guard let result else {
            if liveDataAvailable { liveDataAvailable = false; onEvent?(.liveDataLost) }
            return
        }
        if !liveDataAvailable { liveDataAvailable = true; onEvent?(.liveDataRestored) }
        handleVehicle(result, now: now)
    }

    private func beginRiding(leg: Int, tripID: String, confirmed: Bool, now: Date) {
        guard let ride = ride(at: leg) else { return }
        advance(.riding(leg: leg, tripID: tripID, confirmed: confirmed, tracking: .live))
        departedAt = now
        vehicleMisses = 0
        farFromVehiclePolls = 0
        countdown = nil
        onEvent?(confirmed ? .boarded(ride) : .departedTentatively(ride))
        startPolling(every: pollInterval) { [weak self] in
            guard let self else { return { _ in } }
            let result: VehicleStatus?? = try? await transit.vehicle(forTrip: tripID)
            return { now in self.applyVehiclePoll(result, now: now) }
        }
    }

    private func alighted(leg: Int, now: Date) {
        guard let plan, let ride = ride(at: leg) else { return }
        onEvent?(.alighted(ride))
        let next = leg + 1
        guard plan.legs.indices.contains(next) else { advance(.arrived); onEvent?(.arrived); return }
        switch plan.legs[next] {
        case .walk(let walk):
            do {
                try beginWalk(leg: next, walk, at: nil, now: now)
                // Stepping off inside a station: no fresh GPS yet, so hold instructions until it returns.
                if !Self.isFresh(lastFix, now: now) {
                    awaitingSignal = true
                    onEvent?(.awaitingSignal(leg: next))
                }
            } catch { replan("Couldn't start the next walking leg.") }
        case .transfer:
            beginWaiting(leg: next + 1, now: now)
        case .ride:
            beginWaiting(leg: next, now: now)
        }
    }

    private func replan(_ reason: String) {
        advance(.needsReplan(reason: reason))
        controller.stop()
        onEvent?(.needsReplan(reason))
    }

    private func advance(_ next: Phase, keepPolling: Bool = false) {
        phaseToken = UUID()
        if !keepPolling { poll?.cancel(); poll = nil }
        phase = next
    }

    /// Each loop fetches, then applies its result only if the phase has not moved on.
    private func startPolling(every interval: Duration, _ work: @escaping () async -> (Date) -> Void) {
        poll?.cancel()
        let token = phaseToken
        poll = Task { [weak self] in
            while !Task.isCancelled {
                let apply = await work()
                guard let self, self.phaseToken == token, !Task.isCancelled else { return }
                apply(Date())
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func resumePolling() {
        switch phase {
        case .walking(let leg):
            guard cueArrivalsWhileWalking, let rideLeg = rideIndex(after: leg), let ride = ride(at: rideLeg) else { return }
            startPolling(every: pollInterval) { [weak self] in
                guard let self else { return { _ in } }
                let result = try? await transit.arrivals(at: ride.board, route: ride.routeFilter, directionID: ride.directionID)
                return { now in self.applyArrivalsPoll(result, now: now) }
            }
        case .waitingAtStop(let leg), .vehicleArriving(let leg, _):
            guard let ride = ride(at: leg) else { return }
            startPolling(every: pollInterval) { [weak self] in
                guard let self else { return { _ in } }
                let result = try? await transit.arrivals(at: ride.board, route: ride.routeFilter, directionID: ride.directionID)
                return { now in self.applyArrivalsPoll(result, now: now) }
            }
        case .riding(_, let trip, _, _), .alighting(_, let trip):
            startPolling(every: pollInterval) { [weak self] in
                guard let self else { return { _ in } }
                let result: VehicleStatus?? = try? await transit.vehicle(forTrip: trip)
                return { now in self.applyVehiclePoll(result, now: now) }
            }
        default: break
        }
    }

    // MARK: Plan helpers

    private func ride(at leg: Int) -> RideLeg? {
        guard let plan, plan.legs.indices.contains(leg), case .ride(let ride) = plan.legs[leg] else { return nil }
        return ride
    }

    private func rideIndex(after walkLeg: Int) -> Int? {
        guard let plan, plan.legs.indices.contains(walkLeg + 1), case .ride = plan.legs[walkLeg + 1] else { return nil }
        return walkLeg + 1
    }
}
