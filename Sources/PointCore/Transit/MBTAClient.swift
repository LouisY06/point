import CoreLocation
import Foundation

/// MBTA V3 API (https://api-v3.mbta.com/docs/swagger). Works without a key at 20 requests/min;
/// `MBTA_API_KEY` raises that to 1000. Every request is batched and field-trimmed, and route
/// patterns are cached for the session, so planning a journey costs about four calls.
@MainActor public final class MBTAClient: TransitDataSource {
    private let base: URL
    private let session: URLSession
    private let apiKey: String?
    private var patternCache: [String: [RidePattern]] = [:]
    public private(set) var callCount = 0

    public init(base: URL = URL(string: "https://api-v3.mbta.com")!, session: URLSession = .shared, apiKey: String? = nil) {
        self.base = base; self.session = session; self.apiKey = apiKey
    }

    // MARK: TransitDataSource

    public func stations(near location: CLLocationCoordinate2D, radiusMeters: Double) async throws -> [TransitStation] {
        guard CLLocationCoordinate2DIsValid(location) else { throw ServiceError.invalidResponse }
        let envelope: Envelope<StopAttributes> = try await get("/stops", [
            ("filter[latitude]", String(location.latitude)),
            ("filter[longitude]", String(location.longitude)),
            ("filter[radius]", String(format: "%.5f", radiusMeters / 111_000)),
            ("filter[route_type]", "0,1,3"),
            ("include", "parent_station"),
            ("fields[stop]", "name,latitude,longitude,wheelchair_boarding,location_type"),
            ("sort", "distance"),
            ("page[limit]", "30")
        ])
        return Self.stations(from: envelope)
    }

    public func routes(atStops stopIDs: [String]) async throws -> [TransitRoute] {
        guard !stopIDs.isEmpty else { return [] }
        let envelope: Envelope<RouteAttributes> = try await get("/routes", [
            ("filter[stop]", stopIDs.joined(separator: ",")),
            ("filter[type]", "0,1,3"),
            ("fields[route]", "short_name,long_name,type,color")
        ])
        return envelope.data.map { Self.route(id: $0.id, attributes: $0.attributes) }
    }

    public func patterns(forRoutes routeIDs: [String]) async throws -> [RidePattern] {
        let missing = routeIDs.filter { patternCache[$0] == nil }
        if !missing.isEmpty {
            let envelope: Envelope<PatternAttributes> = try await get("/route_patterns", [
                ("filter[route]", missing.joined(separator: ",")),
                ("include", "representative_trip.stops,representative_trip.shape"),
                ("fields[route_pattern]", "name,direction_id,typicality,canonical"),
                ("fields[trip]", "headsign"),
                ("fields[stop]", "name,latitude,longitude"),
                ("fields[shape]", "polyline"),
                ("page[limit]", "200")
            ])
            let decoded = Self.patterns(from: envelope)
            for id in missing { patternCache[id] = decoded.filter { $0.routeID == id } }
        }
        return routeIDs.flatMap { patternCache[$0] ?? [] }
    }

    public func arrivals(at station: TransitStation, route routeID: String, directionID: Int) async throws -> [TransitArrival] {
        let envelope: Envelope<PredictionAttributes> = try await get("/predictions", [
            ("filter[stop]", station.id),
            ("filter[route]", routeID),
            ("filter[direction_id]", String(directionID)),
            ("include", "trip,vehicle"),
            ("fields[prediction]", "arrival_time,departure_time,status,schedule_relationship"),
            ("fields[trip]", "headsign"),
            ("fields[vehicle]", "current_status,latitude,longitude,updated_at"),
            ("sort", "arrival_time"),
            ("page[limit]", "8")
        ])
        return Self.arrivals(from: envelope)
    }

    public func vehicle(forTrip tripID: String) async throws -> VehicleStatus? {
        let envelope: Envelope<VehicleAttributes> = try await get("/vehicles", [
            ("filter[trip]", tripID),
            ("fields[vehicle]", "current_status,latitude,longitude,updated_at")
        ])
        return envelope.data.first.map { Self.vehicle(id: $0.id, attributes: $0.attributes, relationships: $0.relationships) }
    }

    public func alerts(routes routeIDs: [String], stations stationIDs: [String]) async throws -> [TransitAlert] {
        guard !routeIDs.isEmpty || !stationIDs.isEmpty else { return [] }
        var query: [(String, String)] = [
            ("filter[activity]", "BOARD,RIDE,USING_WHEELCHAIR"),
            ("filter[datetime]", "NOW"),
            ("fields[alert]", "header,effect"),
            ("page[limit]", "6")
        ]
        if !routeIDs.isEmpty { query.append(("filter[route]", routeIDs.joined(separator: ","))) }
        if !stationIDs.isEmpty { query.append(("filter[stop]", stationIDs.joined(separator: ","))) }
        let envelope: Envelope<AlertAttributes> = try await get("/alerts", query)
        return envelope.data.map { TransitAlert(header: $0.attributes.header, effect: $0.attributes.effect ?? "") }
    }

    // MARK: Mapping (pure, tested with fixtures)

    /// Platforms collapse to their parent station so one entry stands for every platform;
    /// bus stops have no parent and stay as the curbside stop. Distance order is preserved.
    static func stations(from envelope: Envelope<StopAttributes>) -> [TransitStation] {
        let parents = Dictionary((envelope.included ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        return envelope.data.compactMap { item in
            let parentID = item.relationships?["parent_station"]?.data?.id
            let id = parentID ?? item.id
            guard !seen.contains(id) else { return nil }
            let parent = parentID.flatMap { parents[$0]?.attributes }
            guard let latitude = parent?.latitude ?? item.attributes.latitude,
                  let longitude = parent?.longitude ?? item.attributes.longitude else { return nil }
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            seen.insert(id)
            let wheelchair = parent?.wheelchair_boarding ?? item.attributes.wheelchair_boarding
            return TransitStation(id: id, name: parent?.name ?? item.attributes.name ?? id, coordinate: coordinate,
                                  wheelchairAccessible: wheelchair.flatMap { $0 == 0 ? nil : $0 == 1 })
        }
    }

    static func route(id: String, attributes: RouteAttributes) -> TransitRoute {
        let name: String
        if attributes.type == 3 {
            let short = attributes.short_name ?? id
            name = short.hasPrefix("SL") ? "Silver Line \(short)" : "Route \(short)"
        } else {
            name = attributes.long_name.flatMap { $0.isEmpty ? nil : $0 } ?? id
        }
        return TransitRoute(id: id, name: name, colorHex: attributes.color ?? "888888", type: attributes.type ?? 3)
    }

    /// Keeps the typical pattern(s) per route/direction. Rapid-transit lines mark them canonical;
    /// buses have no canonical flag, so typicality 1 is the fallback.
    static func patterns(from envelope: Envelope<PatternAttributes>) -> [RidePattern] {
        let included = Dictionary((envelope.included ?? []).map { (IncludedKey(type: $0.type, id: $0.id), $0) },
                                  uniquingKeysWith: { a, _ in a })
        let grouped = Dictionary(grouping: envelope.data) { $0.relationships?["route"]?.data?.id ?? "" }
        return grouped.flatMap { routeID, items -> [RidePattern] in
            let canonical = items.filter { $0.attributes.canonical == true }
            let chosen = canonical.isEmpty ? items.filter { $0.attributes.typicality == 1 } : canonical
            return chosen.compactMap { item in
                guard let tripID = item.relationships?["representative_trip"]?.data?.id,
                      let trip = included[IncludedKey(type: "trip", id: tripID)] else { return nil }
                let stopIDs = trip.relationships?["stops"]?.list ?? []
                let stops = stopIDs.compactMap { platformID -> PatternStop? in
                    guard let stop = included[IncludedKey(type: "stop", id: platformID)],
                          let latitude = stop.attributes.latitude, let longitude = stop.attributes.longitude else { return nil }
                    let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                    guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                    return PatternStop(platformID: platformID, stationID: stop.relationships?["parent_station"]?.data?.id ?? platformID,
                                       name: stop.attributes.name ?? platformID, coordinate: coordinate)
                }
                guard stops.count >= 2 else { return nil }
                let shapeID = trip.relationships?["shape"]?.data?.id
                let polyline = shapeID.flatMap { included[IncludedKey(type: "shape", id: $0)]?.attributes.polyline } ?? ""
                return RidePattern(id: item.id, routeID: routeID, directionID: item.attributes.direction_id ?? 0,
                                   headsign: trip.attributes.headsign ?? item.attributes.name ?? "",
                                   stops: stops, shape: PolylineDecoder.decode(polyline))
            }
        }.sorted { $0.id < $1.id }
    }

    static func arrivals(from envelope: Envelope<PredictionAttributes>) -> [TransitArrival] {
        let included = Dictionary((envelope.included ?? []).map { (IncludedKey(type: $0.type, id: $0.id), $0) },
                                  uniquingKeysWith: { a, _ in a })
        return envelope.data.compactMap { item in
            let attributes = item.attributes
            if let relationship = attributes.schedule_relationship, ["CANCELLED", "SKIPPED", "NO_DATA"].contains(relationship) { return nil }
            guard let tripID = item.relationships?["trip"]?.data?.id else { return nil }
            let trip = included[IncludedKey(type: "trip", id: tripID)]
            let vehicle = item.relationships?["vehicle"]?.data.flatMap { included[IncludedKey(type: "vehicle", id: $0.id)] }
                .map { Self.vehicle(id: $0.id, attributes: VehicleAttributes(current_status: $0.attributes.current_status,
                                                                             latitude: $0.attributes.latitude, longitude: $0.attributes.longitude,
                                                                             updated_at: $0.attributes.updated_at),
                                    relationships: $0.relationships) }
            return TransitArrival(tripID: tripID, patternID: trip?.relationships?["route_pattern"]?.data?.id,
                                  headsign: trip?.attributes.headsign ?? "",
                                  time: (attributes.arrival_time ?? attributes.departure_time).flatMap(Self.parseDate),
                                  status: attributes.status, vehicle: vehicle)
        }
    }

    static func vehicle(id: String, attributes: VehicleAttributes, relationships: [String: Relationship]?) -> VehicleStatus {
        let coordinate = zip(attributes.latitude, attributes.longitude).map { CLLocationCoordinate2D(latitude: $0, longitude: $1) }
        return VehicleStatus(vehicleID: id, status: VehicleStatus.Status(rawValue: attributes.current_status ?? "") ?? .unknown,
                             platformStopID: relationships?["stop"]?.data?.id,
                             coordinate: coordinate.flatMap { CLLocationCoordinate2DIsValid($0) ? $0 : nil },
                             updatedAt: attributes.updated_at.flatMap(Self.parseDate))
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: Transport

    private func get<A: Decodable>(_ path: String, _ query: [(String, String)]) async throws -> Envelope<A> {
        try Task.checkCancellation()
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        callCount += 1
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ServiceError.http(http.statusCode) }
        return try Self.decode(data)
    }

    static func decode<A: Decodable>(_ data: Data) throws -> Envelope<A> {
        try JSONDecoder().decode(Envelope<A>.self, from: data)
    }

    // MARK: JSON:API shapes

    struct Envelope<A: Decodable>: Decodable { let data: [Item<A>]; let included: [IncludedItem]? }
    struct Item<A: Decodable>: Decodable { let id: String; let type: String; let attributes: A; let relationships: [String: Relationship]? }
    /// `data` is an object for to-one and an array for to-many relationships.
    struct Relationship: Decodable {
        let data: RelationshipData?
        let list: [String]?
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let many = try? container.decode([RelationshipData].self, forKey: .data) {
                list = many.map(\.id); data = many.first
            } else {
                data = try? container.decode(RelationshipData.self, forKey: .data); list = nil
            }
        }
        private enum CodingKeys: String, CodingKey { case data }
    }
    struct RelationshipData: Decodable { let id: String; let type: String }
    struct IncludedItem: Decodable { let id: String; let type: String; let attributes: IncludedAttributes; let relationships: [String: Relationship]? }
    /// Loose shape shared by stops, trips, shapes and vehicles in `included`.
    struct IncludedAttributes: Decodable {
        let name: String?; let latitude: Double?; let longitude: Double?; let wheelchair_boarding: Int?
        let headsign: String?; let polyline: String?
        let current_status: String?; let updated_at: String?
    }
    struct IncludedKey: Hashable { let type: String; let id: String }
    struct StopAttributes: Decodable { let name: String?; let latitude: Double?; let longitude: Double?; let wheelchair_boarding: Int?; let location_type: Int? }
    struct RouteAttributes: Decodable { let short_name: String?; let long_name: String?; let type: Int?; let color: String? }
    struct PatternAttributes: Decodable { let name: String?; let direction_id: Int?; let typicality: Int?; let canonical: Bool? }
    struct PredictionAttributes: Decodable { let arrival_time: String?; let departure_time: String?; let status: String?; let schedule_relationship: String? }
    struct VehicleAttributes: Decodable { let current_status: String?; let latitude: Double?; let longitude: Double?; let updated_at: String? }
    struct AlertAttributes: Decodable { let header: String; let effect: String? }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
