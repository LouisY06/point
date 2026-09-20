import CoreLocation
import Foundation

/// A provider-neutral step: the instruction text and the path geometry it covers.
public struct SyntheticRouteStep {
    public let instruction: String
    public let coordinates: [CLLocationCoordinate2D]

    public init(instruction: String, coordinates: [CLLocationCoordinate2D]) {
        self.instruction = instruction
        self.coordinates = coordinates
    }
}

/// Builds a `RoutePlan` from synthetic geometry through the same segmentation and beacon
/// extraction MapKit routes use, so callers cannot invent a different beacon layout.
public enum SyntheticRoute {
    public static func plan(destinationName: String,
                            steps: [SyntheticRouteStep],
                            checkpointIntervalMeters: Double = 15,
                            turnThresholdDegrees: Double? = nil) throws -> RoutePlan {
        let records = steps.map { step in
            DirectionsStepRecord(htmlInstructions: step.instruction,
                                 coordinates: step.coordinates,
                                 distanceMeters: pathLengthMeters(step.coordinates))
        }
        let segmented = try RouteSegmenter(checkpointIntervalMeters: checkpointIntervalMeters).segment(steps: records)
        let extractor = turnThresholdDegrees.map { TurnPointExtractor(turnThresholdDegrees: $0) } ?? TurnPointExtractor()
        let beacons = extractor.extract(checkpoints: segmented.checkpoints)
        return RoutePlan(destinationName: destinationName, checkpoints: segmented.checkpoints, beacons: beacons)
    }

    private static func pathLengthMeters(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 2 else { return 0 }
        return zip(coordinates, coordinates.dropFirst())
            .reduce(0) { $0 + RouteGeometry.distanceMeters($1.0, $1.1) }
    }
}
