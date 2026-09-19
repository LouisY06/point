import CoreLocation
import Foundation
import Testing
@testable import PointCore

@MainActor struct RouteScaleTests {
    @Test func mapWindowStaysBoundedAndNeverDropsTheActiveTarget() {
        for count in [1, 10, 301, 1_000, 10_000] {
            let overview = RouteMapWindow.beaconIndices(count: count, activeIndex: nil)
            #expect(overview.count <= 64)
            #expect(overview.first == 0 && overview.last == count - 1)
            for active in [0, count / 2, count - 1] {
                let visible = RouteMapWindow.beaconIndices(count: count, activeIndex: active)
                #expect(visible.count <= 13)
                #expect(visible.contains(active))
                #expect(visible.contains(count - 1))
                #expect(visible == visible.sorted())
                #expect(Set(visible).count == visible.count)
            }
        }
        #expect(RouteMapWindow.beaconIndices(count: 0, activeIndex: nil).isEmpty)
    }

    @Test func hundredsOfBeaconsAdvanceInOrderWithConstantTargetFeedback() throws {
        var points = [CLLocationCoordinate2D(latitude: 42, longitude: -71)]
        for index in 1...360 {
            points.append(RouteGeometry.offsetCoordinate(from: points.last!, bearingDegrees: index.isMultiple(of: 2) ? 0 : 90, distanceMeters: 100))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let route = try AppleMapsService.makeRoute(steps: [], fallbackCoordinates: points, name: "360 turn scale check")
        let construction = start.duration(to: clock.now)
        #expect(route.beacons.count > 300)
        let session = NavigationSession()
        let date = Date(timeIntervalSince1970: 10000)
        func location(_ coordinate: CLLocationCoordinate2D, _ second: Double) -> CLLocation {
            CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: 3, verticalAccuracy: 3,
                       timestamp: date.addingTimeInterval(second))
        }
        try session.start(route, at: location(points[0], 0), now: date)
        var second = 1.0
        let walkingStart = clock.now
        var reached = 0
        for index in 1..<route.beacons.count {
            #expect(session.beaconIndex == index)
            let target = try #require(session.activeBeacon)
            let approach = RouteGeometry.offsetCoordinate(from: target.coordinate, bearingDegrees: 180, distanceMeters: 30)
            let fix = location(approach, second)
            var engine = DirectionFeedbackEngine()
            let reading = HeadingReading(degrees: 0, accuracyDegrees: 2, timestamp: fix.timestamp, reference: .trueNorth)
            let feedback = engine.evaluate(target: target, location: fix, heading: reading, connected: true,
                                           enabled: true, rerouteRequired: false, now: fix.timestamp)
            #expect(PhoneHapticEnvelope.targetIntensity(errorDegrees: try #require(feedback.angularErrorDegrees)) > 0.79)
            let first = location(target.coordinate, second)
            #expect(session.updateLocation(first, now: first.timestamp) == nil)
            second += 1
            let next = location(target.coordinate, second)
            let arrival = try #require(session.updateLocation(next, now: next.timestamp))
            #expect(arrival.index == index)
            reached += 1
            second += 1
        }
        #expect(reached == route.beacons.count - 1)
        #expect(session.state == .arrived)
        print("Route scale: \(route.beacons.count) beacons, \(route.checkpoints.count) checkpoints; construction \(construction), all GPS updates \(walkingStart.duration(to: clock.now))")
    }
}
