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

    @Test func unrelatedResultsStillAskTheUser() {
        let a = place("Harvard Art Museums", "a", north: 500)
        let b = place("MIT List Center", "b", north: 900)
        guard case .choose(let list) = DestinationResolver.resolve(request: "take me to the gallery", candidates: [a, b], from: here)
        else { Issue.record("expected choose"); return }
        #expect(list.count == 2)
        guard case .choose(let empty) = DestinationResolver.resolve(request: "x", candidates: [], from: here) else { Issue.record("expected choose"); return }
        #expect(empty.isEmpty)
    }

    @Test func singleResultGoesDirectly() {
        guard case .go = DestinationResolver.resolve(request: "MIT Museum", candidates: [place("MIT Museum", "one", north: 100)], from: here)
        else { Issue.record("expected go"); return }
    }
}
