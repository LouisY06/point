import CoreLocation
import Foundation
import PointCore

/// Builds a `RoutePlan` from a scenario. Every kind goes through the production segmenter and
/// turn-point extractor, so simulated routes carry the same checkpoint spacing and beacon layout
/// the app gets from MapKit.
public enum RouteBuilder {
    public static func build(_ spec: RouteSpec, fixturesDirectory: URL?) throws -> RoutePlan {
        switch spec.kind {
        case .inline:
            return try plan(steps: [SyntheticRouteStep(instruction: "Continue toward \(spec.destinationName)",
                                                       coordinates: spec.coordinates!.map(\.coordinate))],
                            spec: spec)
        case .generated:
            let vertices = generatedVertices(spec)
            let legs = spec.legs!
            let steps = legs.enumerated().map { index, leg in
                SyntheticRouteStep(instruction: leg.instruction ?? defaultInstruction(index: index, count: legs.count,
                                                                                      destination: spec.destinationName),
                                   coordinates: [vertices[index], vertices[index + 1]])
            }
            return try plan(steps: steps, spec: spec)
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

    private static func plan(steps: [SyntheticRouteStep], spec: RouteSpec) throws -> RoutePlan {
        try SyntheticRoute.plan(destinationName: spec.destinationName,
                                steps: steps,
                                checkpointIntervalMeters: spec.checkpointSpacingMeters,
                                turnThresholdDegrees: spec.turnThresholdDegrees)
    }

    private static func defaultInstruction(index: Int, count: Int, destination: String) -> String {
        if index == 0 { return "Begin route" }
        if index == count - 1 { return "Arrive at \(destination)" }
        return "Turn"
    }
}
