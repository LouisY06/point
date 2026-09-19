import CoreLocation
import MapKit

/// Native Apple Maps search and walking directions; no provider API key is required.
@MainActor public final class AppleMapsService: PlaceSearching, RouteProviding {
    public init() {}

    public func search(_ query: String, near location: CLLocationCoordinate2D) async throws -> [PlaceCandidate] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CLLocationCoordinate2DIsValid(location), !query.isEmpty else {
            throw ServiceError.invalidResponse
        }
        try Task.checkCancellation()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: location, latitudinalMeters: 10_000, longitudinalMeters: 10_000)
        request.resultTypes = [.address, .pointOfInterest]
        let response = try await MKLocalSearch(request: request).start()
        try Task.checkCancellation()
        return response.mapItems.compactMap { item -> PlaceCandidate? in
            let coordinate = item.placemark.coordinate
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return PlaceCandidate(id: UUID().uuidString, name: item.name ?? query,
                                  address: item.placemark.title ?? "", coordinate: coordinate)
        }.prefix(5).map { $0 }
    }

    public func walkingRoute(from origin: CLLocationCoordinate2D,
                             to destination: CLLocationCoordinate2D, name: String) async throws -> RoutePlan {
        guard CLLocationCoordinate2DIsValid(origin), CLLocationCoordinate2DIsValid(destination) else {
            throw ServiceError.invalidResponse
        }
        try Task.checkCancellation()
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .walking
        request.requestsAlternateRoutes = false
        let response = try await MKDirections(request: request).calculate()
        try Task.checkCancellation()
        guard let route = response.routes.first else { throw ServiceError.noRoute }
        let steps = route.steps.map {
            DirectionsStepRecord(htmlInstructions: $0.instructions,
                                 coordinates: Self.coordinates(in: $0.polyline), distanceMeters: $0.distance)
        }
        return try Self.makeRoute(steps: steps, fallbackCoordinates: Self.coordinates(in: route.polyline), name: name)
    }

    static func coordinates(in polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coordinates = Array(repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
        if !coordinates.isEmpty {
            polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: coordinates.count))
        }
        return coordinates
    }

    /// Zero-length departure/arrival steps are valid in MapKit. Keep their points when
    /// present; if no step has path geometry, use the complete route polyline instead.
    static func makeRoute(steps: [DirectionsStepRecord], fallbackCoordinates: [CLLocationCoordinate2D],
                          name: String) throws -> RoutePlan {
        let pathSteps = steps.contains(where: { $0.coordinates.count >= 2 }) ? steps : [
            DirectionsStepRecord(htmlInstructions: "Continue toward \(name)",
                                 coordinates: fallbackCoordinates, distanceMeters: 0)
        ]
        let segmented = try RouteSegmenter().segment(steps: pathSteps)
        return RoutePlan(destinationName: name, checkpoints: segmented.checkpoints,
                         beacons: TurnPointExtractor().extract(checkpoints: segmented.checkpoints))
    }
}
