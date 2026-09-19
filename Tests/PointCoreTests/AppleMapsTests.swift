import CoreLocation
import Foundation
import MapKit
import Testing
@testable import PointCore

@MainActor struct AppleMapsTests {
    private let start = CLLocationCoordinate2D(latitude: 42, longitude: -71)
    private let corner = CLLocationCoordinate2D(latitude: 42, longitude: -70.999)
    private let end = CLLocationCoordinate2D(latitude: 42.001, longitude: -70.999)

    @Test func nativePolylineStepsPreserveTurnAndInstruction() throws {
        let first = MKPolyline(coordinates: [start, corner], count: 2)
        let second = MKPolyline(coordinates: [corner, end], count: 2)
        let route = try AppleMapsService.makeRoute(steps: [
            .init(htmlInstructions: "Depart", coordinates: [start], distanceMeters: 0),
            .init(htmlInstructions: "Go east", coordinates: AppleMapsService.coordinates(in: first), distanceMeters: 83),
            .init(htmlInstructions: "Turn left", coordinates: AppleMapsService.coordinates(in: second), distanceMeters: 111),
            .init(htmlInstructions: "Arrive", coordinates: [], distanceMeters: 0)
        ], fallbackCoordinates: [], name: "Shop")
        #expect(route.destinationName == "Shop")
        #expect(route.beacons.count == 3)
        #expect(RouteGeometry.distanceMeters(route.beacons[1].coordinate, corner) < 0.1)
        #expect(route.beacons[1].instruction == "Turn left")
        #expect(route.beacons.last?.isFinalDestination == true)
        #expect(abs((route.checkpoints.last?.distanceFromStartMeters ?? 0) - 194) < 3)
    }

    @Test func routePolylineFallbackDoesNotMakeDistanceBasedBeacons() throws {
        let route = try AppleMapsService.makeRoute(steps: [], fallbackCoordinates: [start, corner], name: "Shop")
        #expect(route.checkpoints.count > 2)
        #expect(route.beacons.count == 2)
        #expect(RouteGeometry.distanceMeters(route.beacons.last!.coordinate, corner) < 0.1)
    }

    @Test func invalidAndEmptyPathsAreRejected() {
        #expect(throws: (any Error).self) {
            try AppleMapsService.makeRoute(steps: [], fallbackCoordinates: [], name: "Shop")
        }
        #expect(throws: (any Error).self) {
            try AppleMapsService.makeRoute(steps: [], fallbackCoordinates: [start, start], name: "Shop")
        }
        #expect(throws: (any Error).self) {
            try AppleMapsService.makeRoute(steps: [], fallbackCoordinates: [start, .init(latitude: 100, longitude: 0)], name: "Shop")
        }
    }

    @Test func invalidRequestsFailBeforeCallingApple() async {
        let service = AppleMapsService()
        await #expect(throws: (any Error).self) { try await service.search("  ", near: start) }
        await #expect(throws: (any Error).self) {
            try await service.walkingRoute(from: start, to: .init(latitude: 100, longitude: 0), name: "Shop")
        }
    }

    // Explicit opt-in integration check using public landmark coordinates, never device GPS.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["POINT_TEST_LIVE_MAPS"] == "1"))
    func liveAppleSearchAndWalkingRoute() async throws {
        let service = AppleMapsService()
        let origin = CLLocationCoordinate2D(latitude: 42.3601, longitude: -71.0942)
        let candidates = try await service.search("MIT Museum Cambridge", near: origin)
        let destination = try #require(candidates.first)
        let route = try await service.walkingRoute(from: origin, to: destination.coordinate, name: destination.name)
        #expect(route.checkpoints.count >= 2)
        #expect(route.beacons.last?.isFinalDestination == true)
        print("Apple Maps live check: \(destination.name), \(route.checkpoints.count) checkpoints, \(route.beacons.count) beacons")
    }
}
