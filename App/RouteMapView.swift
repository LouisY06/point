import MapKit
import PointCore
import SwiftUI

/// High-rate heading samples invalidate only the map, not the complete home/route screen.
@MainActor final class RouteMapTelemetry: ObservableObject {
    @Published private(set) var heading: HeadingReading?
    private var lastPublished = -Double.infinity

    func receive(_ value: CLHeading) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPublished >= 0.1 else { return } // Display at 10 Hz; haptics receive every sample.
        lastPublished = now
        heading = HeadingReading(degrees: value.trueHeading, accuracyDegrees: value.headingAccuracy,
                                 timestamp: value.timestamp, reference: .trueNorth)
    }

    func clearHeading() { heading = nil; lastPublished = -.infinity }
}

/// Geometry is created once per route identity, never for a compass update.
private final class RouteMapDrawing: ObservableObject {
    let polyline: MKPolyline
    let region: MKCoordinateRegion

    init(route: RoutePlan) {
        let coordinates = route.checkpoints.map(\.coordinate)
        polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        let rect = polyline.boundingMapRect
        let bounds = MKCoordinateRegion(rect)
        region = MKCoordinateRegion(center: bounds.center,
                                    span: .init(latitudeDelta: min(170, max(0.003, bounds.span.latitudeDelta * 1.8)),
                                                longitudeDelta: min(360, max(0.004, bounds.span.longitudeDelta * 2.2))))
    }
}

struct RouteMapView: View {
    let route: RoutePlan
    var activeBeaconIndex: Int?
    var phoneLocation: CLLocation?
    @ObservedObject var telemetry: RouteMapTelemetry
    @StateObject private var drawing: RouteMapDrawing
    @State private var position: MapCameraPosition = .automatic
    @State private var mapHeading: Double = 0

    init(route: RoutePlan, activeBeaconIndex: Int?, phoneLocation: CLLocation?, telemetry: RouteMapTelemetry) {
        self.route = route
        self.activeBeaconIndex = activeBeaconIndex
        self.phoneLocation = phoneLocation
        self.telemetry = telemetry
        _drawing = StateObject(wrappedValue: RouteMapDrawing(route: route))
    }

    var body: some View {
        Map(position: $position) {
            if let location = phoneLocation, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 25 {
                Annotation("Your pointing direction", coordinate: location.coordinate, anchor: .center) {
                    PhoneDirectionAnnotation(heading: telemetry.heading, location: location, mapHeading: mapHeading)
                }
            } else { UserAnnotation() }
            MapPolyline(drawing.polyline).stroke(.white, lineWidth: 9)
            MapPolyline(drawing.polyline).stroke(PointTheme.route, lineWidth: 5)
            if let start = route.checkpoints.first {
                Annotation("Start", coordinate: start.coordinate, anchor: .center) {
                    Circle().fill(PointTheme.accent).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.white, lineWidth: 4))
                        .accessibilityLabel("Route starting point")
                }
            }
            ForEach(RouteMapWindow.beaconIndices(count: route.beacons.count, activeIndex: activeBeaconIndex), id: \.self) { index in
                let beacon = route.beacons[index]
                Annotation(beacon.isFinalDestination ? route.destinationName : "Next point", coordinate: beacon.coordinate) {
                    Image(systemName: beacon.isFinalDestination ? "mappin" : "circle.fill")
                        .font(beacon.isFinalDestination ? .title2.bold() : .caption2)
                        .foregroundStyle(.white)
                        .padding(beacon.isFinalDestination ? 12 : 5)
                        .background(PointTheme.accent, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: index == activeBeaconIndex ? 3 : 0).padding(-5))
                        .accessibilityLabel(index == activeBeaconIndex ? "Active beacon" : beacon.isFinalDestination ? "Destination" : "Route beacon \(index + 1)")
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls { MapCompass() }
        .onMapCameraChange(frequency: .continuous) {
            if abs(mapHeading - $0.camera.heading) > 0.2 { mapHeading = $0.camera.heading }
        }
        .onAppear { position = .region(drawing.region) }
    }
}

/// Only this small marker has a freshness timer; route lines and all other markers stay unchanged.
private struct PhoneDirectionAnnotation: View {
    let heading: HeadingReading?
    let location: CLLocation
    let mapHeading: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { clock in
            let freshLocation = (0...5).contains(clock.date.timeIntervalSince(location.timestamp))
            if freshLocation, let heading, heading.degrees >= 0, heading.degrees < 360,
               (0...25).contains(heading.accuracyDegrees),
               (0...0.5).contains(clock.date.timeIntervalSince(heading.timestamp)) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 34, weight: .bold)).foregroundStyle(.cyan)
                    .padding(9).background(.black.opacity(0.8), in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .rotationEffect(.degrees(heading.degrees - mapHeading))
                    .accessibilityLabel("Phone points \(Int(heading.degrees)) degrees from north")
            } else {
                Circle().fill(freshLocation ? Color.cyan : Color.gray).frame(width: 18, height: 18)
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .accessibilityLabel(freshLocation ? "Your location. Waiting for compass" : "Last known location. Waiting for GPS")
            }
        }
    }
}
