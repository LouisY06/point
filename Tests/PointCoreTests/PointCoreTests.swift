import CoreLocation
import Foundation
import Testing
@testable import PointCore

private let origin = CLLocationCoordinate2D(latitude: 42, longitude: -71)
private let north = CLLocationCoordinate2D(latitude: 42.001, longitude: -71)
private let epoch = Date(timeIntervalSince1970: 1_000)

private func location(_ coordinate: CLLocationCoordinate2D = origin, seconds: Double = 0, accuracy: Double = 2) -> CLLocation {
    CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: accuracy,
               verticalAccuracy: 2, timestamp: epoch.addingTimeInterval(seconds))
}

private func heading(_ degrees: Double, seconds: Double = 0, reference: HeadingReference = .trueNorth) -> HeadingReading {
    HeadingReading(degrees: degrees, accuracyDegrees: 2, timestamp: epoch.addingTimeInterval(seconds), reference: reference)
}

private func plan() -> RoutePlan {
    RoutePlan(destinationName: "Destination", checkpoints: [
        .init(coordinate: origin, distanceFromStartMeters: 0, stepIndex: 0, stepInstruction: "North", bearingToNextDegrees: 0),
        .init(coordinate: north, distanceFromStartMeters: 111, stepIndex: 0, stepInstruction: "Arrive", bearingToNextDegrees: 0)
    ], beacons: [.init(coordinate: north, instruction: "North", isFinalDestination: true, bearingAfterTurnDegrees: 0)])
}

struct RouteTests {
    @Test func malformedPolylinesCannotHangOrCreatePartialRoutes() {
        for encoded in ["é", "_", "???", "~~~~~~~~~~~~", "\n"] {
            #expect(PolylineDecoder.decode(encoded).isEmpty)
        }
        let points = PolylineDecoder.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        #expect(points.count == 3)
        #expect(abs(points[0].latitude - 38.5) < 0.00001)
    }

    @Test func originalTurnSurvivesCheckpointResampling() throws {
        let data = Data(#"{"routes":[{"legs":[{"steps":[{"polyline":{"points":"???gE"},"html_instructions":"Go east"},{"polyline":{"points":"?gEgE?"},"html_instructions":"Turn left"}]}]}]}"#.utf8)
        let result = try LegacyDirectionsImporter.route(from: data, destinationName: "Corner")
        #expect(result.beacons.count == 3)
        #expect(abs(result.beacons[1].coordinate.longitude - 0.001) < 0.00001)
        #expect(result.beacons[1].instruction == "Turn left")
    }

    @Test @MainActor func duplicateOrInaccurateFixesDoNotCompleteJourney() throws {
        let session = NavigationSession()
        try session.start(plan())
        session.updateLocation(location(north, accuracy: 20), now: epoch)
        session.updateLocation(location(north), now: epoch)
        session.updateLocation(location(north), now: epoch)
        #expect(session.state == .navigating)
        session.updateLocation(location(north, seconds: 1), now: epoch.addingTimeInterval(1))
        #expect(session.state == .navigating)
        session.updateLocation(location(north, seconds: 2), now: epoch.addingTimeInterval(2))
        #expect(session.state == .arrived)
    }

    @Test @MainActor func stopAndRouteReplacementResetProgress() throws {
        let session = NavigationSession()
        try session.start(plan())
        session.updateLocation(location(north), now: epoch)
        try session.replaceRoute(plan())
        session.updateLocation(location(north, seconds: 1), now: epoch.addingTimeInterval(1))
        #expect(session.state == .navigating)
        #expect(session.beaconIndex == 0)
        session.stop()
        session.updateLocation(location(north, seconds: 2), now: epoch.addingTimeInterval(2))
        #expect(session.route == nil)
        #expect(session.state == .idle)
    }


}

struct FeedbackTests {
    private func evaluate(_ engine: inout DirectionFeedbackEngine, degrees: Double, seconds: Double,
                          reference: HeadingReference = .trueNorth) -> DirectionFeedback {
        engine.evaluate(target: plan().beacons[0], location: location(),
                        heading: heading(degrees, seconds: seconds, reference: reference),
                        connected: true, enabled: true, rerouteRequired: false, now: epoch.addingTimeInterval(seconds))
    }

    @Test func alignmentCrossesNorthAndRequiresDwell() {
        var engine = DirectionFeedbackEngine()
        #expect(evaluate(&engine, degrees: 359, seconds: 0).status == .checking)
        #expect(evaluate(&engine, degrees: 1, seconds: 0.4).shouldConfirm)
        #expect(!evaluate(&engine, degrees: 50, seconds: 0.5).shouldConfirm)
    }

    @Test func acceptedHeadingUncertaintyDoesNotMakeAlignmentImpossible() {
        for uncertainty in [15.0, 17.432, 24.9, 25] {
            var engine = DirectionFeedbackEngine()
            func check(_ angle: Double, at seconds: Double) -> DirectionFeedback {
                let now = epoch.addingTimeInterval(seconds)
                return engine.evaluate(target: plan().beacons[0], location: location(seconds: seconds, accuracy: 0),
                    heading: .init(degrees: angle, accuracyDegrees: uncertainty, timestamp: now, reference: .trueNorth),
                    connected: true, enabled: true, rerouteRequired: false, now: now)
            }
            #expect(check(0, at: 0).status == .checking)
            #expect(check(25, at: 0.1).status == .checking)
            #expect(check(25, at: 0.21).shouldConfirm)
            #expect(check(35, at: 0.3).shouldConfirm)
            #expect(check(35.1, at: 0.4).status == .offDirection)
            #expect(check(25.1, at: 0.5).status == .offDirection)
            #expect(check(335, at: 0.6).status == .checking)
            #expect(check(335, at: 0.81).shouldConfirm)
            #expect(check(180, at: 0.9).status == .offDirection)
        }
    }

    @Test func nearbyBeaconUsesEstimatedDirectionDespiteGPSUncertainty() {
        var engine = DirectionFeedbackEngine()
        var scheduler = HapticScheduler()
        let target = PingTarget(coordinate: .init(latitude: 42 + 20 / 111_195.0, longitude: -71),
                               instruction: "North", isFinalDestination: true, bearingAfterTurnDegrees: 0)
        func check(gpsAccuracy: Double, angle: Double = 0, at seconds: Double) -> DirectionFeedback {
            let now = epoch.addingTimeInterval(seconds)
            return engine.evaluate(target: target, location: location(seconds: seconds, accuracy: gpsAccuracy),
                heading: .init(degrees: angle, accuracyDegrees: 17.432, timestamp: now, reference: .trueNorth),
                connected: true, enabled: true, rerouteRequired: false, now: now)
        }
        // Reproduces the phone's ~20 m beacon and ±15 m location estimate.
        #expect(check(gpsAccuracy: 15, at: 0).status == .checking)
        let aligned = check(gpsAccuracy: 15, at: 0.21)
        #expect((aligned.uncertaintyDegrees ?? 0) > 60)
        #expect(scheduler.command(for: aligned, now: epoch.addingTimeInterval(0.21)) == .confirm(durationMs: 180, intensity: 160))
        // Crossing inside the GPS uncertainty circle no longer suppresses pointing.
        #expect(check(gpsAccuracy: 25, at: 0.3).shouldConfirm)
        let turnedAway = check(gpsAccuracy: 25, angle: 36, at: 0.4)
        #expect(turnedAway.status == .offDirection)
        #expect(scheduler.command(for: turnedAway, now: epoch.addingTimeInterval(0.4)) == .stop)
        #expect(check(gpsAccuracy: 25, at: 0.5).status == .checking)
        #expect(check(gpsAccuracy: 25, at: 0.71).shouldConfirm)
        #expect(check(gpsAccuracy: 26, at: 0.8).status == .locationUnavailable)
    }

    @Test func pointingToleranceDoesNotTightenWithBeaconDistance() {
        for meters in [5.0, 10, 20, 100, 1_000] {
            let target = PingTarget(coordinate: .init(latitude: origin.latitude + meters / 111_195, longitude: origin.longitude),
                                   instruction: "North", isFinalDestination: true, bearingAfterTurnDegrees: 0)
            var engine = DirectionFeedbackEngine()
            func check(_ angle: Double, at seconds: Double) -> DirectionFeedback {
                let now = epoch.addingTimeInterval(seconds)
                return engine.evaluate(target: target, location: location(seconds: seconds, accuracy: 15),
                    heading: .init(degrees: angle, accuracyDegrees: 17.432, timestamp: now, reference: .trueNorth),
                    connected: true, enabled: true, rerouteRequired: false, now: now)
            }
            #expect(check(26, at: 0).status == .offDirection)
            #expect(check(25, at: 0.1).status == .checking)
            #expect(check(25, at: 0.31).shouldConfirm)
            #expect(check(35, at: 0.4).shouldConfirm)
            #expect(check(36, at: 0.5).status == .offDirection)
        }
    }

    @Test @MainActor func recordedGloveEstimateReachesTheMotorQueueWhenPointingAtBeacon() throws {
        let glove = SimulatedGlove()
        let point = PointController(glove: glove)
        glove.connect()
        try point.start(plan())
        let nearBeacon = CLLocationCoordinate2D(latitude: north.latitude - 20 / 111_195.0, longitude: north.longitude)
        point.updateLocation(location(nearBeacon, accuracy: 15), now: epoch)
        for seconds in [0.0, 0.1, 0.21] {
            let now = epoch.addingTimeInterval(seconds)
            point.receive(.heading(.init(degrees: 0, accuracyDegrees: 17.432, timestamp: now, reference: .trueNorth)), now: now)
        }
        #expect(point.feedback.shouldConfirm)
        #expect((point.feedback.uncertaintyDegrees ?? 0) > 60)
        #expect(glove.commands.last == .confirm(durationMs: 180, intensity: 160))
        #expect(point.lastQueuedHapticCommand == glove.commands.last)
        #expect(point.lastTransportError == nil)
        // A real turn away stops output, even though north and sensor accuracy remain valid.
        point.receive(.heading(.init(degrees: 90, accuracyDegrees: 17.432, timestamp: epoch.addingTimeInterval(0.5), reference: .trueNorth)),
                      now: epoch.addingTimeInterval(0.5))
        #expect(point.feedback.status == .offDirection)
        #expect(glove.commands.last == .stop)
        #expect(point.lastQueuedHapticCommand == .stop)
        // Brief GPS gaps or a rejected fix keep the last accepted position usable.
        point.receive(.heading(.init(degrees: 0, accuracyDegrees: 17.432, timestamp: epoch.addingTimeInterval(0.6), reference: .trueNorth)),
                      now: epoch.addingTimeInterval(0.6))
        point.receive(.heading(.init(degrees: 0, accuracyDegrees: 17.432, timestamp: epoch.addingTimeInterval(0.81), reference: .trueNorth)),
                      now: epoch.addingTimeInterval(0.81))
        #expect(point.feedback.shouldConfirm)
        point.updateLocation(location(nearBeacon, seconds: 0.9, accuracy: 40), now: epoch.addingTimeInterval(0.9))
        #expect(point.navigation.locationQuality == .degraded)
        #expect(point.feedback.shouldConfirm)
        for seconds in stride(from: 1.0, through: 15.0, by: 0.5) {
            let now = epoch.addingTimeInterval(seconds)
            point.receive(.heading(.init(degrees: 0, accuracyDegrees: 17.432, timestamp: now, reference: .trueNorth)), now: now)
            #expect(point.feedback.shouldConfirm)
            #expect(point.navigation.beaconIndex == 0)
            #expect(point.navigation.state == .navigating)
        }
        // The retained fix still expires, stopping a previously active motor.
        point.receive(.heading(.init(degrees: 0, accuracyDegrees: 17.432, timestamp: epoch.addingTimeInterval(15.1), reference: .trueNorth)),
                      now: epoch.addingTimeInterval(15.1))
        #expect(point.feedback.status == .locationUnavailable)
        #expect(glove.commands.last == .stop)
    }

    @Test func rejectsUncalibratedAndStaleOrientation() {
        var engine = DirectionFeedbackEngine()
        #expect(evaluate(&engine, degrees: 0, seconds: 0, reference: .relative).status == .calibrationRequired)
        let stale = engine.evaluate(target: plan().beacons[0], location: location(), heading: heading(0),
                                    connected: true, enabled: true, rerouteRequired: false, now: epoch.addingTimeInterval(1))
        #expect(stale.status == .headingUnavailable)
    }

    @Test func schedulerOnlyConfirmsAlignmentAndStopsWhenLost() {
        var engine = DirectionFeedbackEngine()
        var scheduler = HapticScheduler()
        #expect(scheduler.command(for: evaluate(&engine, degrees: 90, seconds: 0), now: epoch) == nil)
        _ = evaluate(&engine, degrees: 0, seconds: 0.1)
        let aligned = evaluate(&engine, degrees: 0, seconds: 0.5)
        #expect(scheduler.command(for: aligned, now: epoch.addingTimeInterval(0.5)) == .confirm(durationMs: 180, intensity: 160))
        #expect(scheduler.command(for: aligned, now: epoch.addingTimeInterval(0.6)) == nil)
        #expect(scheduler.command(for: evaluate(&engine, degrees: 90, seconds: 0.7), now: epoch.addingTimeInterval(0.7)) == .stop)
    }

    @Test @MainActor func disconnectStopsConfirmationAndClearsHeading() throws {
        let glove = SimulatedGlove()
        let point = PointController(glove: glove)
        glove.connect()
        try point.start(plan())
        point.updateLocation(location(), now: epoch)
        point.receive(.heading(heading(0)), now: epoch)
        point.receive(.heading(heading(0, seconds: 0.4)), now: epoch.addingTimeInterval(0.4))
        #expect(point.feedback.shouldConfirm)
        glove.disconnect()
        #expect(point.feedback.status == .disconnected)
        glove.connect()
        point.tick(now: epoch.addingTimeInterval(0.5))
        #expect(point.feedback.status == .headingUnavailable)
    }
}

@MainActor private final class StubTranscriber: SpeechTranscribing {
    func transcribe(audio: Data) async throws -> String { "Take me to Shake Shack" }
}
@MainActor private final class StubPlaces: PlaceSearching {
    var query = ""
    func search(_ query: String, near location: CLLocationCoordinate2D) async throws -> [PlaceCandidate] {
        self.query = query
        return [.init(id: "one", name: "Shake Shack", address: "Cambridge", coordinate: north)]
    }
}

struct VoiceTests {
    @Test @MainActor func spokenDestinationRequiresChoosingAPlace() async {
        let places = StubPlaces()
        let flow = VoiceDestination(transcriber: StubTranscriber(), places: places)
        await flow.submit(audio: Data([1]), near: origin)
        #expect(places.query == "Shake Shack")
        #expect(flow.transcript == "Take me to Shake Shack")
        #expect(flow.state == .chooseDestination)
        #expect(flow.candidates.count == 1)
        flow.cancel()
        #expect(flow.candidates.isEmpty)
    }

    @Test @MainActor func emptyTypedDestinationDoesNotCallMaps() async {
        let places = StubPlaces()
        let flow = VoiceDestination(transcriber: StubTranscriber(), places: places)
        await flow.submit(text: "  ", near: origin)
        #expect(flow.state == .failed)
        #expect(places.query.isEmpty)
    }
}

struct DestinationResolverTests {
    private let here = CLLocationCoordinate2D(latitude: 42.36, longitude: -71.10)
    private func place(_ name: String, _ id: String, north meters: Double) -> PlaceCandidate {
        .init(id: id, name: name, address: "", coordinate: .init(latitude: 42.36 + meters / 111_000, longitude: -71.10))
    }

    @Test func destinationQueryStripsWrapperNearestAndPunctuation() {
        #expect(VoiceDestination.destinationQuery(from: "Take me to Shake Shack.") == "Shake Shack")
        #expect(VoiceDestination.destinationQuery(from: "Hey, can you take me to the nearest McDonald's, please?") == "McDonald's")
        #expect(VoiceDestination.destinationQuery(from: "find a pharmacy near me") == "a pharmacy")
        #expect(VoiceDestination.destinationQuery(from: "Where's the McDonald's on Mass Ave?") == "the McDonald's on Mass Ave")
    }

    @Test func chainNameGoesToNearestMatch() {
        let far = place("McDonald's", "far", north: 2000)
        let near = place("McDonald's", "near", north: 400)
        let other = place("Burger King", "bk", north: 100)
        guard case .go(let chosen) = DestinationResolver.resolve(request: "Take me to McDonalds", candidates: [far, other, near], from: here)
        else { Issue.record("expected go"); return }
        #expect(chosen.id == "near")
    }

    @Test func qualifiedRequestTrustsSearchRanking() {
        let ranked = place("McDonald's", "ranked", north: 3000)
        let near = place("McDonald's", "near", north: 200)
        guard case .go(let chosen) = DestinationResolver.resolve(request: "the McDonald's on Mass Ave", candidates: [ranked, near], from: here)
        else { Issue.record("expected go"); return }
        #expect(chosen.id == "ranked")
    }

    @Test func nearestRequestPicksByDistanceEvenWhenRankedLower() {
        let ranked = place("CVS Pharmacy", "ranked", north: 3000)
        let near = place("CVS Pharmacy", "near", north: 200)
        guard case .go(let chosen) = DestinationResolver.resolve(request: "nearest CVS", candidates: [ranked, near], from: here)
        else { Issue.record("expected go"); return }
        #expect(chosen.id == "near")
    }

    @Test func unrelatedResultsGoToTheClosestOne() {
        let a = place("Harvard Art Museums", "a", north: 900)
        let b = place("MIT List Center", "b", north: 500)
        guard case .go(let chosen) = DestinationResolver.resolve(request: "take me to the gallery", candidates: [a, b], from: here)
        else { Issue.record("expected go"); return }
        #expect(chosen.id == "b")
    }

    @Test func unqualifiedRequestsIgnoreResultsInAnotherState() {
        let farAway = place("Coffee Shop", "far", north: 400_000) // ~400 km north
        let nearby = place("Cicada Coffee Bar", "near", north: 1_400)
        guard case .go(let chosen) = DestinationResolver.resolve(request: "take me to the closest coffee shop", candidates: [farAway, nearby], from: here)
        else { Issue.record("expected go"); return }
        #expect(chosen.id == "near")
        // Only far results: better to ask again than to route across the state.
        guard case .choose(let none) = DestinationResolver.resolve(request: "a coffee shop", candidates: [farAway], from: here)
        else { Issue.record("expected choose"); return }
        #expect(none.isEmpty)
        // A qualified request may legitimately be far away.
        guard case .go(let qualified) = DestinationResolver.resolve(request: "the Coffee Shop in Portland", candidates: [farAway], from: here)
        else { Issue.record("expected go"); return }
        #expect(qualified.id == "far")
    }

    @Test func noResultsStillAskTheUser() {
        guard case .choose(let empty) = DestinationResolver.resolve(request: "x", candidates: [], from: here) else { Issue.record("expected choose"); return }
        #expect(empty.isEmpty)
    }

    @Test func singleResultGoesDirectly() {
        guard case .go = DestinationResolver.resolve(request: "MIT Museum", candidates: [place("MIT Museum", "one", north: 100)], from: here)
        else { Issue.record("expected go"); return }
    }
}
