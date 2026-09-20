import CoreLocation
import Foundation
import Testing
@testable import PointCore

struct PhonePointingTests {
    let now = Date(timeIntervalSince1970: 10_000)

    @Test func explainsMissingStaleInaccurateAndNearbyGPSSeparately() {
        let origin = CLLocationCoordinate2D(latitude: 42, longitude: -71)
        let target = PingTarget(coordinate: .init(latitude: 42.001, longitude: -71), instruction: "North",
                                isFinalDestination: true, bearingAfterTurnDegrees: 0)
        let heading = HeadingReading(degrees: 0, accuracyDegrees: 2, timestamp: now, reference: .trueNorth)
        var engine = DirectionFeedbackEngine()
        func feedback(_ coordinate: CLLocationCoordinate2D, accuracy: Double, age: Double) -> DirectionFeedback {
            let location = CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: accuracy,
                                      verticalAccuracy: 2, timestamp: now.addingTimeInterval(-age))
            return engine.evaluate(target: target, location: location, heading: heading, connected: true,
                                   enabled: true, rerouteRequired: false, now: now)
        }
        #expect(feedback(origin, accuracy: 40, age: 0).locationIssue == .inaccurate(meters: 40))
        #expect(feedback(origin, accuracy: 3, age: 6).locationIssue == .stale(seconds: 6))
        let nearby = feedback(target.coordinate, accuracy: 3, age: 0)
        #expect(nearby.locationIssue == .nearby(distance: 0, uncertainty: 3))
        #expect(nearby.distanceToBeaconMeters == 0)
        #expect(nearby.angularErrorDegrees == nil)
        #expect(nearby.locationIssue?.message == "Near beacon · Waiting for GPS to confirm position")
        #expect(engine.evaluate(target: target, location: nil, heading: heading, connected: true,
                                enabled: true, rerouteRequired: false, now: now).locationIssue == .missing)
    }

    @Test @MainActor func onePoorFixDoesNotEraseFreshPhoneDirectionButOldFixStillExpires() throws {
        let origin = CLLocationCoordinate2D(latitude: 42, longitude: -71)
        let target = CLLocationCoordinate2D(latitude: 42.001, longitude: -71)
        let route = try AppleMapsService.makeRoute(steps: [], fallbackCoordinates: [origin, target], name: "GPS regression")
        let session = NavigationSession()
        func fix(accuracy: Double, seconds: Double) -> CLLocation {
            CLLocation(coordinate: origin, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 2,
                       timestamp: now.addingTimeInterval(seconds))
        }
        let good = fix(accuracy: 3, seconds: 0)
        try session.start(route, at: good, now: now)
        session.updateLocation(good, now: now)
        session.updateLocation(fix(accuracy: 50, seconds: 0.2), now: now.addingTimeInterval(0.2))
        #expect(session.locationQuality == .degraded)
        var engine = DirectionFeedbackEngine()
        func feedback(at seconds: Double) -> DirectionFeedback {
            let time = now.addingTimeInterval(seconds)
            return engine.evaluate(target: session.activeBeacon, location: session.location,
                                   heading: HeadingReading(degrees: 0, accuracyDegrees: 2, timestamp: time, reference: .trueNorth),
                                   connected: true, enabled: true, rerouteRequired: false, now: time)
        }
        #expect(feedback(at: 0.3).angularErrorDegrees != nil)
        #expect(feedback(at: 5.1).status == .locationUnavailable)
        session.updateLocation(fix(accuracy: 3, seconds: 6), now: now.addingTimeInterval(6))
        #expect(feedback(at: 6).angularErrorDegrees != nil)
        #expect(session.beaconIndex == 1) // No arrival is invented by retaining a recent fix.
    }

    @Test func walkingRangeHasFocusedCenterAndGentleEdges() {
        func strength(_ angle: Double) -> Double {
            PhoneHapticEnvelope.targetIntensity(errorDegrees: angle, angleRange: .walkingRoute)
        }
        for angle in [-10.0, -5, 0, 5, 10] { #expect(strength(angle) == 0.8) }
        #expect(abs(strength(10.001) - 0.8) < 0.00001)
        #expect(strength(15) > strength(25))
        #expect(strength(25) > strength(30))
        #expect(strength(30) > 0)
        #expect(strength(-30) == strength(30))
        for angle in [-180.0, -90, -35, 35, 90, 180, .nan, .infinity] { #expect(strength(angle) == 0) }
        var envelope = PhoneHapticEnvelope(angleRange: .walkingRoute)
        for tick in 0...20 {
            _ = envelope.update(errorDegrees: tick.isMultiple(of: 2) ? -9 : 9, gripValid: true,
                                now: now.addingTimeInterval(Double(tick) * 0.05))
        }
        #expect(envelope.intensity > 0.79) // Jitter inside the plateau does not weaken output.
        let stopped = envelope.update(errorDegrees: 0, gripValid: false, now: now.addingTimeInterval(1.05))
        #expect(stopped == 0)
    }

    @Test func nearbyEstimatedAlignmentVibratesWithoutClaimingCertainAlignment() throws {
        // Reproduce the reported screen: about 15 m away and 3 degrees off.
        let origin = CLLocationCoordinate2D(latitude: 42, longitude: -71)
        let target = PingTarget(coordinate: .init(latitude: 42 + 15 / 111_195, longitude: -71),
                                instruction: "Continue", isFinalDestination: false, bearingAfterTurnDegrees: 0)
        let location = CLLocation(coordinate: origin, altitude: 0, horizontalAccuracy: 10,
                                  verticalAccuracy: 3, timestamp: now)
        let heading = HeadingReading(degrees: 357, accuracyDegrees: 10, timestamp: now, reference: .trueNorth)
        var engine = DirectionFeedbackEngine()
        let feedback = engine.evaluate(target: target, location: location, heading: heading, connected: true,
                                       enabled: true, rerouteRequired: false, now: now)
        let angle = try #require(feedback.angularErrorDegrees)
        #expect(abs(angle - 3) < 0.01)
        #expect(!feedback.shouldConfirm) // First sample starts the alignment dwell.
        #expect(PhoneHapticEnvelope.targetIntensity(errorDegrees: feedback.conservativeErrorDegrees!) == 0)
        #expect(PhoneHapticEnvelope.targetIntensity(errorDegrees: angle) > 0.78)
        var envelope = PhoneHapticEnvelope()
        for tick in 0...10 {
            _ = envelope.update(errorDegrees: angle, gripValid: true, now: now.addingTimeInterval(Double(tick) * 0.05))
        }
        #expect(envelope.intensity > 0.7)
        let stale = engine.evaluate(target: target, location: location, heading: heading, connected: true,
                                    enabled: true, rerouteRequired: false, now: now.addingTimeInterval(1))
        let stopped = envelope.update(errorDegrees: stale.angularErrorDegrees, gripValid: true, now: now.addingTimeInterval(1))
        #expect(stopped == 0)
    }

    @Test @MainActor func appleRouteAdvancesPointingAndEmitsEachArrivalExactlyOnce() throws {
        let points: [CLLocationCoordinate2D] = [
            .init(latitude: 42, longitude: -71), .init(latitude: 42, longitude: -70.999),
            .init(latitude: 42.001, longitude: -70.999), .init(latitude: 42.001, longitude: -70.998)
        ]
        let route = try AppleMapsService.makeRoute(steps: [], fallbackCoordinates: points, name: "Walk test")
        #expect(route.beacons.count == 4)
        let controller = PointController(glove: SimulatedGlove())
        let session = controller.navigation
        func fix(_ point: Int, _ second: Double, accuracy: Double = 3) -> CLLocation {
            CLLocation(coordinate: points[point], altitude: 0, horizontalAccuracy: accuracy,
                       verticalAccuracy: 3, timestamp: now.addingTimeInterval(second))
        }
        // Same session and Apple Maps adapter used by the real phone route.
        try session.start(route, at: fix(0, 0), now: now)
        #expect(session.beaconIndex == 1)
        #expect(controller.updateLocation(fix(1, 1, accuracy: 20), now: now.addingTimeInterval(1)) == nil)
        #expect(controller.updateLocation(fix(1, 2), now: now.addingTimeInterval(2)) == nil)
        #expect(controller.updateLocation(fix(1, 2), now: now.addingTimeInterval(2)) == nil) // Duplicate isn't a second fix.
        let first = try #require(controller.updateLocation(fix(1, 3), now: now.addingTimeInterval(3)))
        #expect(first.index == 1 && !first.isDestination)
        #expect(session.beaconIndex == 2)
        #expect(controller.updateLocation(fix(1, 3), now: now.addingTimeInterval(3)) == nil)

        var feedback = DirectionFeedbackEngine()
        func strength(_ heading: Double) -> Double {
            let reading = HeadingReading(degrees: heading, accuracyDegrees: 2,
                                         timestamp: now.addingTimeInterval(3), reference: .trueNorth)
            let result = feedback.evaluate(target: session.activeBeacon, location: session.location,
                                           heading: reading, connected: true, enabled: true,
                                           rerouteRequired: false, now: now.addingTimeInterval(3))
            return result.conservativeErrorDegrees.map { PhoneHapticEnvelope.targetIntensity(errorDegrees: $0) } ?? 0
        }
        #expect(strength(90) == 0) // Old eastward direction no longer vibrates.
        #expect(strength(0) > 0.7) // New northward beacon drives strength.

        session.pause()
        #expect(controller.updateLocation(fix(2, 4), now: now.addingTimeInterval(4)) == nil)
        #expect(session.beaconIndex == 2)
        session.resume()
        #expect(controller.updateLocation(fix(2, 5), now: now.addingTimeInterval(5)) == nil)
        let second = try #require(controller.updateLocation(fix(2, 6), now: now.addingTimeInterval(6)))
        #expect(second.index == 2 && !second.isDestination)
        #expect(session.beaconIndex == 3)
        #expect(controller.updateLocation(fix(3, 7), now: now.addingTimeInterval(7)) == nil)
        let destination = try #require(controller.updateLocation(fix(3, 8), now: now.addingTimeInterval(8)))
        #expect(destination.index == 3 && destination.isDestination)
        #expect(session.state == .arrived)
        #expect(session.activeBeacon == nil)
        #expect(controller.updateLocation(fix(3, 9), now: now.addingTimeInterval(9)) == nil)
    }

    @Test func localBeaconsUseTopEdgeAndIgnoreFloorHeight() throws {
        let position = SIMD3<Float>(0, 1.2, 0)
        let top = SIMD3<Float>(0, 0, -1)
        let forward = try #require(LocalBeaconGeometry.direction(position: position, topEdge: top, target: [0, 0, -2]))
        #expect(abs(forward.errorDegrees) < 0.001)
        #expect(abs(forward.horizontalDistance - 2) < 0.001)
        let reverse = try #require(LocalBeaconGeometry.direction(position: position, topEdge: top, target: [0, 0, 2]))
        #expect(abs(abs(reverse.errorDegrees) - 180) < 0.001)
        let right = try #require(LocalBeaconGeometry.direction(position: position, topEdge: top, target: [2, 0, 0]))
        let left = try #require(LocalBeaconGeometry.direction(position: position, topEdge: top, target: [-2, 0, 0]))
        #expect(abs(right.errorDegrees - 90) < 0.001)
        #expect(abs(left.errorDegrees + 90) < 0.001)
        #expect(LocalBeaconGeometry.direction(position: position, topEdge: [0, 1, 0], target: [0, 0, -2]) == nil)
        #expect(LocalBeaconGeometry.direction(position: position, topEdge: top, target: [0, 0, 0]) == nil)
        #expect(LocalBeaconGeometry.direction(position: position, topEdge: top, target: [.nan, 0, -2]) == nil)
    }

    @Test func onlyScreenDownGripIsAcceptedWithTiltHysteresis() {
        var envelope = PhoneHapticEnvelope()
        func check(_ z: Double, age: Double = 0, expected: Bool) {
            let accepted = envelope.acceptsGrip(gravityZ: z, motionAge: age)
            #expect(accepted == expected)
        }
        check(-1, expected: false) // Screen up.
        check(0, expected: false) // Upright or edge-on.
        check(cos(32 * .pi / 180), expected: false)
        check(1, expected: true)
        check(cos(32 * .pi / 180), expected: true)
        check(cos(40 * .pi / 180), expected: false)
        check(1, age: 0.31, expected: false)
        check(.nan, expected: false)
    }

    @Test func strengthPeaksForwardAndNeverTreatsReverseAsForward() {
        #expect(PhoneHapticEnvelope.targetIntensity(errorDegrees: 0) == 0.8)
        #expect(PhoneHapticEnvelope.targetIntensity(errorDegrees: 10) > PhoneHapticEnvelope.targetIntensity(errorDegrees: 30))
        #expect(PhoneHapticEnvelope.targetIntensity(errorDegrees: 20) == PhoneHapticEnvelope.targetIntensity(errorDegrees: -20))
        for error in [45.0, 90, 180, -180, .infinity, .nan] {
            #expect(PhoneHapticEnvelope.targetIntensity(errorDegrees: error) == 0)
        }
    }

    @Test func intensityLerpsRatherThanJumpingAndThenFades() {
        var envelope = PhoneHapticEnvelope()
        let first = envelope.update(errorDegrees: 0, gripValid: true, now: now)
        let second = envelope.update(errorDegrees: 0, gripValid: true, now: now.addingTimeInterval(0.05))
        #expect(first > 0 && first < second && second < 0.8)
        let fading = envelope.update(errorDegrees: 90, gripValid: true, now: now.addingTimeInterval(0.10))
        #expect(fading > 0 && fading < second)
        #expect(envelope.update(errorDegrees: 0, gripValid: false, now: now.addingTimeInterval(0.15)) == 0)
        _ = envelope.update(errorDegrees: 0, gripValid: true, now: now.addingTimeInterval(0.20))
        #expect(envelope.update(errorDegrees: nil, gripValid: true, now: now.addingTimeInterval(0.25)) == 0)
    }

    @Test func lerpIsIndependentOfTickFrequencyAndResetsAfterStall() {
        var slow = PhoneHapticEnvelope(), fast = PhoneHapticEnvelope()
        _ = slow.update(errorDegrees: 0, gripValid: true, now: now)
        _ = fast.update(errorDegrees: 0, gripValid: true, now: now)
        for tick in 1...10 { _ = slow.update(errorDegrees: 0, gripValid: true, now: now.addingTimeInterval(Double(tick) * 0.1)) }
        for tick in 1...20 { _ = fast.update(errorDegrees: 0, gripValid: true, now: now.addingTimeInterval(Double(tick) * 0.05)) }
        #expect(abs(slow.intensity - fast.intensity) < 0.00001)
        #expect(fast.update(errorDegrees: 0, gripValid: true, now: now.addingTimeInterval(2)) == 0)
        fast.reset()
        #expect(fast.intensity == 0)
    }

    @Test func staleHeadingOrGPSCannotProduceGradedFeedback() {
        let origin = CLLocationCoordinate2D(latitude: 42, longitude: -71)
        let destination = CLLocationCoordinate2D(latitude: 42.001, longitude: -71)
        let target = PingTarget(coordinate: destination, instruction: "North", isFinalDestination: true, bearingAfterTurnDegrees: 0)
        let location = CLLocation(coordinate: origin, altitude: 0, horizontalAccuracy: 2, verticalAccuracy: 2, timestamp: now)
        let heading = HeadingReading(degrees: 359, accuracyDegrees: 2, timestamp: now, reference: .trueNorth)
        var engine = DirectionFeedbackEngine()
        let valid = engine.evaluate(target: target, location: location, heading: heading, connected: true,
                                    enabled: true, rerouteRequired: false, now: now)
        #expect(abs(valid.angularErrorDegrees! - 1) < 0.01)
        #expect(valid.conservativeErrorDegrees != nil)
        for seconds in [0.6, 6] {
            let stale = engine.evaluate(target: target, location: location, heading: heading, connected: true,
                                        enabled: true, rerouteRequired: false, now: now.addingTimeInterval(seconds))
            #expect(stale.conservativeErrorDegrees == nil)
        }
        let offRoute = engine.evaluate(target: target, location: location, heading: heading, connected: true,
                                       enabled: true, rerouteRequired: true, now: now)
        #expect(offRoute.conservativeErrorDegrees == nil)
    }

    @Test @MainActor func startMarkerIsSkippedOnlyWhenAlreadyAtRouteOrigin() throws {
        let origin = CLLocationCoordinate2D(latitude: 42, longitude: -71)
        let corner = CLLocationCoordinate2D(latitude: 42.001, longitude: -71)
        let end = CLLocationCoordinate2D(latitude: 42.001, longitude: -70.999)
        let coordinates = [origin, corner, end]
        let route = RoutePlan(destinationName: "Shop", checkpoints: coordinates.enumerated().map {
            RouteCheckpoint(coordinate: $0.element, distanceFromStartMeters: Double($0.offset) * 100,
                            stepIndex: $0.offset, stepInstruction: "Continue", bearingToNextDegrees: 0)
        }, beacons: coordinates.enumerated().map {
            PingTarget(coordinate: $0.element, instruction: "Continue", isFinalDestination: $0.offset == 2, bearingAfterTurnDegrees: 0)
        })
        let session = NavigationSession()
        let fix = CLLocation(coordinate: origin, altitude: 0, horizontalAccuracy: 3, verticalAccuracy: 3, timestamp: now)
        try session.start(route, at: fix, now: now)
        #expect(session.beaconIndex == 1)
        #expect(session.activeBeacon?.coordinate.latitude == corner.latitude)
        try session.start(route, at: fix, now: now.addingTimeInterval(10))
        #expect(session.beaconIndex == 0)
        let distantFix = CLLocation(coordinate: end, altitude: 0, horizontalAccuracy: 3, verticalAccuracy: 3, timestamp: now)
        try session.start(route, at: distantFix, now: now)
        #expect(session.beaconIndex == 0)
    }
}
