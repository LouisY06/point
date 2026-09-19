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
    public let coordinate: CLLocationCoordinate2D
    public let instruction: String
    public let isFinalDestination: Bool
    public let bearingAfterTurnDegrees: Double

    public init(coordinate: CLLocationCoordinate2D, instruction: String,
                isFinalDestination: Bool, bearingAfterTurnDegrees: Double) {
        self.coordinate = coordinate
        self.instruction = instruction
        self.isFinalDestination = isFinalDestination
        self.bearingAfterTurnDegrees = bearingAfterTurnDegrees
    }
}

public struct RoutePlan {
    public let id: UUID
    public let destinationName: String
    public let checkpoints: [RouteCheckpoint]
    public let beacons: [PingTarget]

    public init(destinationName: String, checkpoints: [RouteCheckpoint], beacons: [PingTarget]) {
        id = UUID()
        self.destinationName = destinationName
        self.checkpoints = checkpoints
        self.beacons = beacons
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
