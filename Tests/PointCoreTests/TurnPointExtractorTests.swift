import CoreLocation
import Foundation
import Testing
@testable import PointCore

/// Routes built through the real segmenter (15 m checkpoints), the way Apple routes arrive.
@MainActor struct TurnPointExtractorTests {
    private let start = CLLocationCoordinate2D(latitude: 42.36, longitude: -71.09)

    private func path(_ legs: [(bearing: Double, meters: Double)]) -> [CLLocationCoordinate2D] {
        var points = [start]
        for leg in legs { points.append(RouteGeometry.offsetCoordinate(from: points.last!, bearingDegrees: leg.bearing, distanceMeters: leg.meters)) }
        return points
    }

    private func beacons(_ points: [CLLocationCoordinate2D]) throws -> [PingTarget] {
        try AppleMapsService.makeRoute(steps: [], fallbackCoordinates: points, name: "Test").beacons
    }

    @Test func roundedCornerOfSmallBendsGetsOneBeacon() throws {
        // A 90° corner drawn as four 22.5° bends 8 m apart: no single bend reaches 45°.
        let points = path([(0, 100), (22.5, 8), (45, 8), (67.5, 8), (90, 8), (90, 100)])
        let found = try beacons(points)
        #expect(found.count == 3, "expected start, one corner beacon, end; got \(found.map(\.instruction))")
        let corner = found[1].coordinate
        // The beacon lands inside the bend, not on the straight approach.
        #expect(RouteGeometry.distanceMeters(corner, points[1]) < 30 && RouteGeometry.distanceMeters(corner, points[4]) < 30)
    }

    @Test func gentleCurveOverALongDistanceIsNotACorner() throws {
        // 60° spread over 300 m in 10° steps: a bend in the road, not a turn.
        var legs: [(Double, Double)] = [(0, 100)]
        for step in 1...6 { legs.append((Double(step) * 10, 50)) }
        legs.append((60, 100))
        #expect(try beacons(path(legs)).count == 2)
    }

    @Test func zigzagCornersThirtyMetresApartBothGetBeacons() throws {
        let points = path([(0, 100), (90, 30), (0, 100)])
        let found = try beacons(points)
        #expect(found.count == 4)
        #expect(RouteGeometry.distanceMeters(found[1].coordinate, points[1]) < 0.5)
        #expect(RouteGeometry.distanceMeters(found[2].coordinate, points[2]) < 0.5)
    }

    @Test func sharpCornerBeaconSitsExactlyOnTheVertex() throws {
        let points = path([(0, 100), (90, 100), (180, 100)])
        let found = try beacons(points)
        #expect(found.count == 4)
        #expect(RouteGeometry.distanceMeters(found[1].coordinate, points[1]) < 0.5)
        #expect(abs(found[1].bearingAfterTurnDegrees - 90) < 1)
    }

    @Test func providerManeuverCountsEvenWhenTheGeometryIsGentle() throws {
        // A 30° fork Apple labels "Bear right": below the geometric threshold, above the maneuver one.
        let approach = path([(0, 100)])
        let fork = RouteGeometry.offsetCoordinate(from: approach[1], bearingDegrees: 30, distanceMeters: 100)
        let route = try AppleMapsService.makeRoute(steps: [
            .init(htmlInstructions: "Head north", coordinates: approach, distanceMeters: 100),
            .init(htmlInstructions: "Bear right onto Elm St", coordinates: [approach[1], fork], distanceMeters: 100)
        ], fallbackCoordinates: [], name: "Fork")
        #expect(route.beacons.count == 3)
        #expect(route.beacons[1].instruction == "Bear right onto Elm St")
        // The same fork without a maneuver label stays a plain bend.
        #expect(try beacons(approach + [fork]).count == 2)
    }

    @Test func turnWordsAreRecognised() {
        #expect(TurnPointExtractor.describesTurn("Turn left onto Main St"))
        #expect(TurnPointExtractor.describesTurn("Bear right"))
        #expect(TurnPointExtractor.describesTurn("Keep left at the fork"))
        #expect(!TurnPointExtractor.describesTurn("Continue onto Main St"))
        #expect(!TurnPointExtractor.describesTurn("Walk to the destination"))
    }
}
