import CoreLocation
import Foundation
import PointCore

/// Builds a `RoutePlan` from a scenario. Fixtures reuse the production importer so recorded
/// directions payloads go through the same segmentation as the app.
public enum RouteBuilder {
    public static func build(_ spec: RouteSpec, fixturesDirectory: URL?) throws -> RoutePlan {
        switch spec.kind {
        case .inline:
            return plan(for: spec.coordinates!.map(\.coordinate), name: spec.destinationName,
                        spacingMeters: spec.checkpointSpacingMeters)
        case .generated:
            return plan(for: generatedVertices(spec), name: spec.destinationName,
                        spacingMeters: spec.checkpointSpacingMeters)
        case .fixture:
            guard let directory = fixturesDirectory else { throw ScenarioError.missingFixture(spec.fixture!) }
            let url = directory.appendingPathComponent(spec.fixture!)
            guard let data = FileManager.default.contents(atPath: url.path) else {
                throw ScenarioError.missingFixture(url.path)
            }
            return try LegacyDirectionsImporter.route(from: data, destinationName: spec.destinationName)
        }
    }

    /// Corner vertices of a generated route, before checkpoint resampling.
    public static func generatedVertices(_ spec: RouteSpec) -> [CLLocationCoordinate2D] {
        var vertices = [spec.origin!.coordinate]
        for leg in spec.legs! {
            vertices.append(SimGeometry.offset(from: vertices[vertices.count - 1],
                                               bearingDegrees: leg.bearing, distanceMeters: leg.meters))
        }
        return vertices
    }

    /// One beacon per corner, matching how the app treats turns as ping targets, with intermediate
    /// checkpoints so off-route detection has a path to measure against.
    static func plan(for vertices: [CLLocationCoordinate2D], name: String,
                     spacingMeters: Double = 20) -> RoutePlan {
        var checkpoints: [RouteCheckpoint] = []
        var travelled = 0.0
        for (index, start) in vertices.enumerated().dropLast() {
            let end = vertices[index + 1]
            let legLength = SimGeometry.distanceMeters(start, end)
            let bearing = SimGeometry.bearingDegrees(from: start, to: end)
            let steps = max(1, Int((legLength / spacingMeters).rounded(.down)))
            for step in 0..<steps {
                let fraction = Double(step) / Double(steps)
                let point = SimGeometry.offset(from: start, bearingDegrees: bearing,
                                               distanceMeters: legLength * fraction)
                checkpoints.append(RouteCheckpoint(coordinate: point,
                                                   distanceFromStartMeters: travelled + legLength * fraction,
                                                   stepIndex: index, stepInstruction: "Continue",
                                                   bearingToNextDegrees: bearing))
            }
            travelled += legLength
        }
        let last = vertices[vertices.count - 1]
        checkpoints.append(RouteCheckpoint(coordinate: last, distanceFromStartMeters: travelled,
                                           stepIndex: max(0, vertices.count - 2),
                                           stepInstruction: "Arrive", bearingToNextDegrees: 0))
        let beacons = vertices.enumerated().map { index, coordinate in
            PingTarget(coordinate: coordinate,
                       instruction: index == vertices.count - 1 ? "You have arrived" : "Continue",
                       isFinalDestination: index == vertices.count - 1,
                       bearingAfterTurnDegrees: index == vertices.count - 1
                           ? 0 : SimGeometry.bearingDegrees(from: coordinate, to: vertices[index + 1]))
        }
        return RoutePlan(destinationName: name, checkpoints: checkpoints, beacons: beacons)
    }
}
