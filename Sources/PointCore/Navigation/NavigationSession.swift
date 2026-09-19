import Combine
import CoreLocation
import Foundation

public enum JourneyState: String { case idle, navigating, paused, arrived }
public enum LocationQuality: String { case unavailable, usable, degraded }
public enum SessionError: Error { case invalidRoute }

/// Emitted once, only after distinct accurate GPS fixes confirm this beacon was reached.
public struct BeaconArrival: Equatable {
    public let index: Int
    public let isDestination: Bool
}

/// New route lifecycle. Advancement never waits for speech or a motor acknowledgement.
@MainActor public final class NavigationSession: ObservableObject {
    @Published public private(set) var state: JourneyState = .idle
    @Published public private(set) var route: RoutePlan?
    @Published public private(set) var location: CLLocation?
    @Published public private(set) var locationQuality: LocationQuality = .unavailable
    @Published public private(set) var beaconIndex = 0
    @Published public private(set) var rerouteRequired = false

    private var lastProcessedFix: Date?
    private var arrivalHits = 0
    private var offRouteHits = 0
    public let arrivalRadiusMeters: Double = 8

    public init() {}

    public var activeBeacon: PingTarget? {
        guard state == .navigating, let route, route.beacons.indices.contains(beaconIndex) else { return nil }
        return route.beacons[beaconIndex]
    }

    public var mapSnapshot: MapSnapshot {
        MapSnapshot(route: route, location: location,
                    activeBeaconIndex: route == nil ? nil : beaconIndex)
    }

    public func start(_ route: RoutePlan, at initialLocation: CLLocation? = nil, now: Date = Date()) throws {
        guard route.checkpoints.count >= 2, !route.beacons.isEmpty,
              route.beacons.last?.isFinalDestination == true,
              route.checkpoints.allSatisfy({ CLLocationCoordinate2DIsValid($0.coordinate) }),
              route.beacons.allSatisfy({ CLLocationCoordinate2DIsValid($0.coordinate) }) else {
            throw SessionError.invalidRoute
        }
        self.route = route
        beaconIndex = 0
        // Skip the origin marker only when a fresh fix confirms we're already there.
        if let fix = initialLocation, route.beacons.count > 1,
           CLLocationCoordinate2DIsValid(fix.coordinate),
           (0...25).contains(fix.horizontalAccuracy), (0...5).contains(now.timeIntervalSince(fix.timestamp)),
           !route.beacons[0].isFinalDestination,
           RouteGeometry.distanceMeters(route.beacons[0].coordinate, route.checkpoints[0].coordinate) < 1.5,
           RouteGeometry.distanceMeters(fix.coordinate, route.beacons[0].coordinate) <= max(8, fix.horizontalAccuracy) {
            beaconIndex = 1
        }
        location = nil
        locationQuality = .unavailable
        lastProcessedFix = nil
        arrivalHits = 0
        offRouteHits = 0
        rerouteRequired = false
        state = .navigating
    }

    public func pause() {
        guard state == .navigating else { return }
        state = .paused
        arrivalHits = 0
    }

    public func resume() {
        guard state == .paused else { return }
        state = .navigating
        locationQuality = .unavailable
    }

    public func stop() {
        state = .idle
        route = nil
        location = nil
        beaconIndex = 0
        locationQuality = .unavailable
        rerouteRequired = false
        arrivalHits = 0
        offRouteHits = 0
        lastProcessedFix = nil
    }

    @discardableResult public func updateLocation(_ fix: CLLocation, now: Date = Date()) -> BeaconArrival? {
        guard state == .navigating else { return nil }
        let age = now.timeIntervalSince(fix.timestamp)
        guard CLLocationCoordinate2DIsValid(fix.coordinate), fix.horizontalAccuracy.isFinite,
              fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 25,
              age >= 0, age <= 5 else {
            locationQuality = .degraded
            arrivalHits = 0
            offRouteHits = 0
            return nil
        }
        guard lastProcessedFix.map({ fix.timestamp > $0 }) ?? true else { return nil }
        location = fix
        locationQuality = .usable
        lastProcessedFix = fix.timestamp
        guard let route, let target = activeBeacon else { return nil }

        let offRoute = isFarFromPath(fix.coordinate, checkpoints: route.checkpoints, beyond: max(25, 2 * fix.horizontalAccuracy))
        offRouteHits = offRoute ? offRouteHits + 1 : 0
        rerouteRequired = offRouteHits >= 3
        guard !rerouteRequired else { arrivalHits = 0; return nil }

        let distance = RouteGeometry.distanceMeters(fix.coordinate, target.coordinate)
        // Tight accuracy is needed before advancing, even when GPS is adequate for map display.
        arrivalHits = distance <= arrivalRadiusMeters && fix.horizontalAccuracy <= arrivalRadiusMeters
            ? arrivalHits + 1 : 0
        guard arrivalHits >= 2 else { return nil }
        arrivalHits = 0
        let arrival = BeaconArrival(index: beaconIndex, isDestination: target.isFinalDestination)
        if target.isFinalDestination {
            state = .arrived
        } else {
            beaconIndex += 1
        }
        return arrival
    }

    /// Use only while a journey is active. The caller must discard stale asynchronous responses.
    public func replaceRoute(_ replacement: RoutePlan) throws {
        guard state == .navigating else { return }
        try start(replacement) // New route numbering starts at zero, never at the old route's index.
    }

    private func isFarFromPath(_ point: CLLocationCoordinate2D, checkpoints: [RouteCheckpoint], beyond threshold: Double) -> Bool {
        let metersPerDegree = 111_195.0
        let longitudeScale = cos(point.latitude * .pi / 180) * metersPerDegree
        let thresholdSquared = threshold * threshold
        // We only need inside/outside, not a distance array for every checkpoint.
        for (first, second) in zip(checkpoints, checkpoints.dropFirst()) {
            let ax = (first.coordinate.longitude - point.longitude) * longitudeScale
            let ay = (first.coordinate.latitude - point.latitude) * metersPerDegree
            let bx = (second.coordinate.longitude - point.longitude) * longitudeScale
            let by = (second.coordinate.latitude - point.latitude) * metersPerDegree
            let dx = bx - ax, dy = by - ay
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? min(1, max(0, -(ax * dx + ay * dy) / lengthSquared)) : 0
            let x = ax + t * dx, y = ay + t * dy
            if x * x + y * y <= thresholdSquared { return false }
        }
        return true
    }
}
