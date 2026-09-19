import CoreLocation
import Foundation

/// REST clients for a trusted host/development runner. A distributed iOS app must use an
/// authenticated backend, not store provider API keys. Endpoints and headers are injectable.
@MainActor public final class OpenAITranscriber: SpeechTranscribing {
    private let endpoint: URL
    private let authorization: () async throws -> String
    private let session: URLSession
    private let model: String

    public init(endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
                model: String = "gpt-transcribe", session: URLSession = .shared,
                authorization: @escaping () async throws -> String) {
        self.endpoint = endpoint; self.model = model; self.session = session
        self.authorization = authorization
    }

    public func transcribe(audio: Data) async throws -> String {
        guard !audio.isEmpty, audio.count <= 24_000_000 else { throw ServiceError.invalidAudio }
        let boundary = "Point-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"destination.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(try await authorization(), forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, from: body)
        try requireSuccess(response)
        struct Transcript: Decodable { let text: String }
        let text = try JSONDecoder().decode(Transcript.self, from: data).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ServiceError.emptyTranscript }
        return text
    }
}

@MainActor public final class GoogleMapsService: PlaceSearching, RouteProviding {
    private let apiKey: () async throws -> String
    private let session: URLSession
    private let placesEndpoint: URL
    private let routesEndpoint: URL

    public init(session: URLSession = .shared,
                placesEndpoint: URL = URL(string: "https://places.googleapis.com/v1/places:searchText")!,
                routesEndpoint: URL = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!,
                apiKey: @escaping () async throws -> String) {
        self.session = session; self.apiKey = apiKey
        self.placesEndpoint = placesEndpoint; self.routesEndpoint = routesEndpoint
    }

    public func search(_ query: String, near location: CLLocationCoordinate2D) async throws -> [PlaceCandidate] {
        guard CLLocationCoordinate2DIsValid(location), !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceError.invalidResponse
        }
        let data = try await post(to: placesEndpoint,
            fields: "places.id,places.displayName,places.formattedAddress,places.location",
            body: ["textQuery": query, "pageSize": 5,
                   "locationBias": ["circle": ["center": coordinates(location), "radius": 5000]]])
        struct Response: Decodable {
            struct Place: Decodable {
                struct Name: Decodable { let text: String }
                struct Location: Decodable { let latitude: Double; let longitude: Double }
                let id: String; let displayName: Name; let formattedAddress: String?; let location: Location?
            }
            let places: [Place]?
        }
        return try JSONDecoder().decode(Response.self, from: data).places?.compactMap { place in
            guard let location = place.location else { return nil }
            let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return PlaceCandidate(id: place.id, name: place.displayName.text,
                                  address: place.formattedAddress ?? "", coordinate: coordinate)
        } ?? []
    }

    public func walkingRoute(from origin: CLLocationCoordinate2D,
                             to destination: CLLocationCoordinate2D, name: String) async throws -> RoutePlan {
        guard CLLocationCoordinate2DIsValid(origin), CLLocationCoordinate2DIsValid(destination) else {
            throw ServiceError.invalidResponse
        }
        let data = try await post(to: routesEndpoint,
            fields: "routes.legs.steps.polyline.encodedPolyline,routes.legs.steps.navigationInstruction.instructions,routes.legs.steps.distanceMeters",
            body: ["origin": ["location": ["latLng": coordinates(origin)]],
                   "destination": ["location": ["latLng": coordinates(destination)]],
                   "travelMode": "WALK", "polylineQuality": "HIGH_QUALITY"])
        return try Self.route(fromRoutesResponse: data, name: name)
    }

    /// Normalize the current Routes API into the existing route-segmentation input.
    /// The same checkpoint and beacon algorithms then work without the legacy API dependency.
    public static func route(fromRoutesResponse data: Data, name: String) throws -> RoutePlan {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = root["routes"] as? [[String: Any]], let route = routes.first,
              let legs = route["legs"] as? [[String: Any]], let leg = legs.first,
              let steps = leg["steps"] as? [[String: Any]], !steps.isEmpty else { throw ServiceError.noRoute }
        let normalized: [[String: Any]] = try steps.map { step in
            guard let polyline = step["polyline"] as? [String: Any],
                  let encoded = polyline["encodedPolyline"] as? String else { throw ServiceError.invalidResponse }
            return ["polyline": ["points": encoded],
                    "html_instructions": (step["navigationInstruction"] as? [String: Any])?["instructions"] as? String ?? "",
                    "distance": ["value": step["distanceMeters"] as? Double ?? 0]]
        }
        let legacy = try JSONSerialization.data(withJSONObject: ["routes": [["legs": [["steps": normalized]]]]])
        return try LegacyDirectionsImporter.route(from: legacy, destinationName: name)
    }

    private func coordinates(_ coordinate: CLLocationCoordinate2D) -> [String: Double] {
        ["latitude": coordinate.latitude, "longitude": coordinate.longitude]
    }

    private func post(to url: URL, fields: String, body: [String: Any]) async throws -> Data {
        let key = try await apiKey()
        guard !key.isEmpty else { throw ServiceError.missingCredential }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(fields, forHTTPHeaderField: "X-Goog-FieldMask")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try requireSuccess(response)
        return data
    }
}

private func requireSuccess(_ response: URLResponse) throws {
    guard let response = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
    guard (200..<300).contains(response.statusCode) else { throw ServiceError.http(response.statusCode) }
}
