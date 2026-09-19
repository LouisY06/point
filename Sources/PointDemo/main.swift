import CoreLocation
import Foundation
import PointCore

@main struct PointDemo {
    @MainActor static func main() async throws {
        let origin = CLLocationCoordinate2D(latitude: 42.3601, longitude: -71.0942)
        let target = CLLocationCoordinate2D(latitude: 42.3611, longitude: -71.0942)
        let route = RoutePlan(destinationName: "Demo destination", checkpoints: [
            .init(coordinate: origin, distanceFromStartMeters: 0, stepIndex: 0, stepInstruction: "Head north", bearingToNextDegrees: 0),
            .init(coordinate: target, distanceFromStartMeters: 111, stepIndex: 0, stepInstruction: "Arrive", bearingToNextDegrees: 0)
        ], beacons: [.init(coordinate: target, instruction: "Head north", isFinalDestination: true, bearingAfterTurnDegrees: 0)])
        let glove = SimulatedGlove()
        let point = PointController(glove: glove)
        glove.connect()
        try point.start(route)
        let start = Date()
        for (offset, heading) in [(0.0, 75.0), (0.1, 2.0), (0.5, 2.0), (0.8, 60.0)] {
            let now = start.addingTimeInterval(offset)
            point.updateLocation(CLLocation(coordinate: origin, altitude: 0, horizontalAccuracy: 2,
                                            verticalAccuracy: 2, timestamp: now), now: now)
            point.receive(.heading(HeadingReading(degrees: heading, accuracyDegrees: 2,
                                                   timestamp: now, reference: .trueNorth)), now: now)
            print("Pointing \(Int(heading))°: \(point.feedback.status.rawValue)")
        }
        print("Motor commands: \(glove.commands)")
    }
}
