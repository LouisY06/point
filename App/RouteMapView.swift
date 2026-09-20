import MapKit
import PointCore
import SwiftUI

/// High-rate heading samples invalidate only the map, not the complete home/route screen.
@MainActor final class RouteMapTelemetry: ObservableObject {
    @Published private(set) var heading: HeadingReading?
    private var lastPublished = -Double.infinity

    func receive(_ value: HeadingReading) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPublished >= 0.1 else { return } // Display at 10 Hz; haptics receive every sample.
        lastPublished = now
        heading = value
    }

    func clearHeading() { heading = nil; lastPublished = -.infinity }
}

/// Geometry is created once per route identity, never for a compass update. For a transit
/// journey the active walking leg is the route; other legs are drawn once as context.
private final class RouteMapDrawing: ObservableObject {
    struct Ride { let routeID: String; let polyline: MKPolyline; let color: Color; let isBus: Bool; let board: TransitStation; let alight: TransitStation; let isPassed: Bool; let boardedByWalk: Bool }
    /// A walking leg other than the active one: drawn with its beacons, faded once passed.
    struct Walk { let polyline: MKPolyline; let beacons: [PingTarget]; let isPassed: Bool; let boardGlyph: String }
    let polyline: MKPolyline
    let otherWalks: [Walk]
    let rides: [Ride]
    let region: MKCoordinateRegion

    init(route: RoutePlan, journey: JourneyPlan?, legIndex: Int?) {
        let coordinates = route.checkpoints.map(\.coordinate)
        polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        var walks: [Walk] = []
        var rides: [Ride] = []
        var rect = polyline.boundingMapRect
        if let journey {
            for (index, leg) in journey.legs.enumerated() {
                let passed = legIndex.map { index < $0 } ?? false
                let nextRide: RideLeg? = journey.legs.indices.contains(index + 1) ? { if case .ride(let r) = journey.legs[index + 1] { return r } else { return nil } }() : nil
                let previousIsWalk: Bool = index > 0 ? { if case .walk = journey.legs[index - 1] { return true } else { return false } }() : false
                switch leg {
                case .walk(let plan) where plan.id != route.id:
                    let points = plan.checkpoints.map(\.coordinate)
                    let line = MKPolyline(coordinates: points, count: points.count)
                    walks.append(Walk(polyline: line, beacons: plan.beacons, isPassed: passed,
                                      boardGlyph: nextRide?.route.isBus == true ? "bus.fill" : "tram.fill"))
                    rect = rect.union(line.boundingMapRect)
                case .ride(let ride):
                    let line = MKPolyline(coordinates: ride.path, count: ride.path.count)
                    // Subway lines keep their MBTA colours; buses use one calm slate blue instead of MBTA yellow.
                    rides.append(Ride(routeID: ride.route.id, polyline: line, color: ride.route.isBus ? Color(red: 0.29, green: 0.44, blue: 0.65) : Color(hex: ride.route.colorHex), isBus: ride.route.isBus,
                                      board: ride.board, alight: ride.alight, isPassed: passed, boardedByWalk: previousIsWalk))
                    rect = rect.union(line.boundingMapRect)
                default: break
                }
            }
        }
        otherWalks = walks
        self.rides = rides
        let bounds = MKCoordinateRegion(rect)
        // A whole journey is wide already; pad modestly so a transfer trip is not framed at city scale.
        let pad = journey == nil ? (1.8, 2.2) : (1.25, 1.3)
        region = MKCoordinateRegion(center: bounds.center,
                                    span: .init(latitudeDelta: min(170, max(0.003, bounds.span.latitudeDelta * pad.0)),
                                                longitudeDelta: min(360, max(0.004, bounds.span.longitudeDelta * pad.1))))
    }
}

struct RouteMapView: View {
    let route: RoutePlan
    var activeBeaconIndex: Int?
    var phoneLocation: CLLocation?
    var journey: JourneyPlan?
    var journeyLegIndex: Int?
    /// Not observed here: only the direction marker redraws on a compass sample. Re-evaluating the
    /// map content ten times a second re-diffs every polyline, which shows as flashing lines.
    let telemetry: RouteMapTelemetry
    @State private var drawing: RouteMapDrawing
    @State private var position: MapCameraPosition = .automatic
    @State private var mapHeading: Double = 0
    /// The marker's position, updated only when the fix moved or its quality changed, so GPS jitter
    /// at one fix per second does not re-diff the whole map.
    @State private var markerLocation: CLLocation?

    init(route: RoutePlan, activeBeaconIndex: Int?, phoneLocation: CLLocation?, telemetry: RouteMapTelemetry,
         journey: JourneyPlan? = nil, journeyLegIndex: Int? = nil) {
        self.route = route
        self.activeBeaconIndex = activeBeaconIndex
        self.phoneLocation = phoneLocation
        self.telemetry = telemetry
        self.journey = journey
        self.journeyLegIndex = journeyLegIndex
        _drawing = State(initialValue: RouteMapDrawing(route: route, journey: journey, legIndex: journeyLegIndex))
    }

    /// The vehicle glyph for the stop this walking leg ends on.
    private var boardGlyph: String {
        guard let journey, let index = journey.legs.firstIndex(where: { if case .walk(let walk) = $0 { return walk.id == route.id }; return false }),
              journey.legs.indices.contains(index + 1),
              case .ride(let ride) = journey.legs[index + 1] else { return "tram.fill" }
        return ride.route.isBus ? "bus.fill" : "tram.fill"
    }

    private var walkPassed: Bool {
        guard let journey, let leg = journeyLegIndex,
              let walk = journey.legs.firstIndex(where: { if case .walk(let plan) = $0 { return plan.id == route.id }; return false }) else { return false }
        return walk < leg
    }

    var body: some View {
        Map(position: $position) {
            if let location = markerLocation, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 25 {
                Annotation("Glove pointing direction", coordinate: location.coordinate, anchor: .center) {
                    GloveDirectionAnnotation(telemetry: telemetry, location: location, mapHeading: mapHeading)
                }
            } else { UserAnnotation() }
            // Every other walking leg, with its beacons in the normal style, faded once passed.
            ForEach(Array(drawing.otherWalks.enumerated()), id: \.offset) { walkIndex, walk in
                MapPolyline(walk.polyline).stroke(.white.opacity(walk.isPassed ? 0.3 : 0.8), lineWidth: 8)
                MapPolyline(walk.polyline).stroke(PointTheme.route.opacity(walk.isPassed ? 0.35 : 0.9), lineWidth: 4)
                ForEach(Array(walk.beacons.enumerated()), id: \.offset) { beaconIndex, beacon in
                    let isBoard = beacon.kind == .boardStop
                    Annotation(beacon.isFinalDestination ? (isBoard ? "" : route.destinationName) : "", coordinate: beacon.coordinate) {
                        Image(systemName: isBoard ? walk.boardGlyph : beacon.isFinalDestination ? "mappin" : "circle.fill")
                            .font(beacon.isFinalDestination ? .title2.bold() : .caption2)
                            .foregroundStyle(.white)
                            .padding(beacon.isFinalDestination ? 12 : 5)
                            .background((isBoard ? Color.green : PointTheme.accent).opacity(walk.isPassed ? 0.45 : 1), in: Circle())
                            .accessibilityLabel(isBoard ? "Stop to get on" : beacon.isFinalDestination ? "Destination" : "Beacon \(beaconIndex + 1) of walking leg \(walkIndex + 1)")
                    }
                }
            }
            // A ride is a solid line in its own colour with no beacons along it: green where you get
            // on, red where you get off. Solid, not dashed: dash patterns redraw visibly on map updates.
            ForEach(Array(drawing.rides.enumerated()), id: \.offset) { _, ride in
                MapPolyline(ride.polyline).stroke(.white.opacity(ride.isPassed ? 0.4 : 0.9), lineWidth: 8)
                MapPolyline(ride.polyline).stroke(ride.color.opacity(ride.isPassed ? 0.45 : 1), lineWidth: 5)
                if !ride.boardedByWalk {
                    Annotation(ride.board.name, coordinate: ride.board.coordinate, anchor: .bottom) {
                        StopBeacon(color: .green, glyph: ride.isBus ? "bus.fill" : "tram.fill", passed: ride.isPassed,
                                   label: "Get on the \(ride.isBus ? "bus" : "train") at \(ride.board.name)")
                    }
                }
                Annotation(ride.alight.name, coordinate: ride.alight.coordinate, anchor: .top) {
                    StopBeacon(color: .red, glyph: "figure.walk", passed: ride.isPassed, label: "Get off at \(ride.alight.name)")
                }
            }
            MapPolyline(drawing.polyline).stroke(.white.opacity(walkPassed ? 0.3 : 1), lineWidth: 9)
            MapPolyline(drawing.polyline).stroke(PointTheme.route.opacity(walkPassed ? 0.35 : 1), lineWidth: 5)
            if let start = route.checkpoints.first {
                Annotation("Start", coordinate: start.coordinate, anchor: .center) {
                    Circle().fill(PointTheme.accent).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.white, lineWidth: 4))
                        .accessibilityLabel("Route starting point")
                }
            }
            ForEach(RouteMapWindow.beaconIndices(count: route.beacons.count, activeIndex: activeBeaconIndex), id: \.self) { index in
                let beacon = route.beacons[index]
                let isBoard = beacon.kind == .boardStop
                Annotation(beacon.isFinalDestination ? route.destinationName : "Next point", coordinate: beacon.coordinate) {
                    Image(systemName: isBoard ? boardGlyph : beacon.isFinalDestination ? "mappin" : "circle.fill")
                        .font(beacon.isFinalDestination ? .title2.bold() : .caption2)
                        .foregroundStyle(.white)
                        .padding(beacon.isFinalDestination ? 12 : 5)
                        .background((isBoard ? Color.green : PointTheme.accent).opacity(walkPassed ? 0.35 : 1), in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: index == activeBeaconIndex ? 3 : 0).padding(-5))
                        .accessibilityLabel(index == activeBeaconIndex ? (isBoard ? "Active beacon: the stop to get on" : "Active beacon")
                                            : beacon.isFinalDestination ? (isBoard ? "Stop to get on" : "Destination") : "Route beacon \(index + 1)")
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls { MapCompass() }
        .onMapCameraChange(frequency: .continuous) {
            if abs(mapHeading - $0.camera.heading) > 0.2 { mapHeading = $0.camera.heading }
        }
        .onAppear { position = .region(drawing.region); markerLocation = phoneLocation }
        .onChange(of: phoneLocation) { _, fix in
            guard let fix else { markerLocation = nil; return }
            guard let shown = markerLocation else { markerLocation = fix; return }
            let moved = fix.distance(from: shown) >= 3
            let usable = { (l: CLLocation) in l.horizontalAccuracy >= 0 && l.horizontalAccuracy <= 25 }
            // A stale timestamp also matters: the marker greys out after five seconds without a fix.
            if moved || usable(fix) != usable(shown) || fix.timestamp.timeIntervalSince(shown.timestamp) >= 4 { markerLocation = fix }
        }
        .onChange(of: journeyLegIndex) { _, index in
            // Update passed-leg styling without rebuilding the map or resetting the user's camera.
            drawing = RouteMapDrawing(route: route, journey: journey, legIndex: index)
        }
    }
}

/// Same silhouette as a destination beacon, so the map reads as one system; only the colour says
/// "get on" (green) or "get off" (red).
private struct StopBeacon: View {
    let color: Color
    let glyph: String
    let passed: Bool
    let label: String
    var body: some View {
        Image(systemName: glyph)
            .font(.title2.bold())
            .foregroundStyle(.white)
            .padding(12)
            .background(color.opacity(passed ? 0.45 : 1), in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 3).padding(-3))
            .accessibilityLabel(label)
    }
}

extension Color {
    /// MBTA route colours arrive as six hex digits without a leading #.
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// Only this small marker has a freshness timer; route lines and all other markers stay unchanged.
private struct GloveDirectionAnnotation: View {
    @ObservedObject var telemetry: RouteMapTelemetry
    let location: CLLocation
    let mapHeading: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { clock in
            let heading = telemetry.heading
            let freshLocation = (0...5).contains(clock.date.timeIntervalSince(location.timestamp))
            if freshLocation, let heading, heading.degrees >= 0, heading.degrees < 360,
               (0...25).contains(heading.accuracyDegrees),
               (0...0.5).contains(clock.date.timeIntervalSince(heading.timestamp)) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 34, weight: .bold)).foregroundStyle(.cyan)
                    .padding(9).background(.black.opacity(0.8), in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .rotationEffect(.degrees(heading.degrees - mapHeading))
                    .accessibilityLabel("Glove points \(Int(heading.degrees)) degrees from north")
            } else {
                Circle().fill(freshLocation ? Color.cyan : Color.gray).frame(width: 18, height: 18)
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .accessibilityLabel(freshLocation ? "Your location. Waiting for calibrated glove direction" : "Last known location. Waiting for GPS")
            }
        }
    }
}
