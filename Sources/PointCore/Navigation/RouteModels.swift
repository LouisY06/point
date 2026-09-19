import CoreLocation
import Foundation

// Checkpoint / ping-target structure retained from the existing map algorithm.
struct DirectionsStepRecord {
    let htmlInstructions: String
    let coordinates: [CLLocationCoordinate2D]
    let distanceMeters: Double
}

public struct RouteCheckpoint {
    public let coordinate: CLLocationCoordinate2D
    public let distanceFromStartMeters: Double
    public let stepIndex: Int
    public let stepInstruction: String
    public let bearingToNextDegrees: Double

    public init(coordinate: CLLocationCoordinate2D, distanceFromStartMeters: Double,
                stepIndex: Int, stepInstruction: String, bearingToNextDegrees: Double) {
        self.coordinate = coordinate
        self.distanceFromStartMeters = distanceFromStartMeters
        self.stepIndex = stepIndex
        self.stepInstruction = stepInstruction
        self.bearingToNextDegrees = bearingToNextDegrees
    }
}

/// A geographic route beacon, not a Bluetooth/iBeacon transmitter.
public struct PingTarget {
    /// What the beacon marks. Walking legs use turn/destination; transit journeys end a walking
    /// leg on the stop to board and mark where to get off. There are no beacons while riding.
    public enum Kind: Equatable { case turn, destination, boardStop, alightStop }

    public let coordinate: CLLocationCoordinate2D
    public let instruction: String
    public let isFinalDestination: Bool
    public let bearingAfterTurnDegrees: Double
    public let kind: Kind

    public init(coordinate: CLLocationCoordinate2D, instruction: String,
                isFinalDestination: Bool, bearingAfterTurnDegrees: Double, kind: Kind = .turn) {
        self.coordinate = coordinate
        self.instruction = instruction
        self.isFinalDestination = isFinalDestination
        self.bearingAfterTurnDegrees = bearingAfterTurnDegrees
        self.kind = kind
    }
}

public struct RoutePlan {
    public let id: UUID
    public let destinationName: String
    public let checkpoints: [RouteCheckpoint]
    public let beacons: [PingTarget]
    public let expectedTravelTime: TimeInterval?

    public init(destinationName: String, checkpoints: [RouteCheckpoint], beacons: [PingTarget], expectedTravelTime: TimeInterval? = nil) {
        id = UUID()
        self.destinationName = destinationName
        self.checkpoints = checkpoints
        self.beacons = beacons
        self.expectedTravelTime = expectedTravelTime
    }

    /// A walking leg of a transit journey ends on a stop, not the destination. The final beacon
    /// keeps its position and remains the leg's terminal target; only its meaning changes.
    public func relabelingFinalBeacon(kind: PingTarget.Kind, instruction: String, coordinate: CLLocationCoordinate2D? = nil) -> RoutePlan {
        guard let last = beacons.last else { return self }
        var updated = beacons
        // A stop's real coordinate beats the sidewalk point Apple's route ends on.
        updated[updated.count - 1] = PingTarget(coordinate: coordinate ?? last.coordinate, instruction: instruction,
                                                isFinalDestination: true, bearingAfterTurnDegrees: last.bearingAfterTurnDegrees,
                                                kind: kind)
        return RoutePlan(destinationName: destinationName, checkpoints: checkpoints, beacons: updated,
                         expectedTravelTime: expectedTravelTime)
    }
}

/// Keeps the map presentation independent of device transport and navigation timers.
public struct MapSnapshot {
    public let route: RoutePlan?
    public let location: CLLocation?
    public let activeBeaconIndex: Int?
}

/// Map provider integration belongs behind this boundary. No API key is embedded in PointCore.
@MainActor public protocol RouteProviding {
    func walkingRoute(from origin: CLLocationCoordinate2D,
                      to destination: CLLocationCoordinate2D, name: String) async throws -> RoutePlan
}

public enum LegacyDirectionsImporter {
    public static func route(from data: Data, destinationName: String) throws -> RoutePlan {
        let segmented = try RouteSegmenter().segment(directionsResponseData: data)
        return RoutePlan(destinationName: destinationName, checkpoints: segmented.checkpoints,
                         beacons: TurnPointExtractor().extract(checkpoints: segmented.checkpoints))
    }
}
