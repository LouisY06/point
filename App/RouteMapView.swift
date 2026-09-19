import GoogleMaps
import MapKit
import PointCore
import SwiftUI

struct RouteMapView: View {
    let route: RoutePlan
    let useGoogle: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if useGoogle { GoogleRouteMap(route: route, animated: !reduceMotion) }
            else { NativePreviewMap(route: route) }
        }
    }
}

/// Uses the existing map-overlay algorithm: path, geographic beacon markers and bounds.
/// No dependency on its camera controller, singleton location manager, or debug controls.
private struct GoogleRouteMap: UIViewRepresentable {
    let route: RoutePlan
    let animated: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> GMSMapView {
        let origin = route.checkpoints[0].coordinate
        let options = GMSMapViewOptions()
        options.camera = GMSCameraPosition(latitude: origin.latitude, longitude: origin.longitude, zoom: 14)
        let map = GMSMapView(options: options)
        map.isMyLocationEnabled = true
        map.settings.compassButton = false
        map.settings.rotateGestures = false
        map.padding = UIEdgeInsets(top: 140, left: 32, bottom: 24, right: 32)
        return map
    }

    func updateUIView(_ map: GMSMapView, context: Context) {
        guard context.coordinator.routeID != route.id else { return }
        context.coordinator.routeID = route.id
        map.clear()
        let path = GMSMutablePath()
        route.checkpoints.forEach { path.add($0.coordinate) }
        let outline = GMSPolyline(path: path)
        outline.strokeWidth = 9
        outline.strokeColor = .white
        outline.map = map
        let line = GMSPolyline(path: path)
        line.strokeWidth = 5
        line.strokeColor = UIColor(PointTheme.route)
        line.map = map
        for (index, beacon) in route.beacons.enumerated() {
            let marker = GMSMarker(position: beacon.coordinate)
            marker.title = beacon.isFinalDestination ? route.destinationName : "Point \(index + 1)"
            marker.icon = GMSMarker.markerImage(with: UIColor(PointTheme.accent))
            marker.map = map
        }
        let camera = GMSCameraUpdate.fit(GMSCoordinateBounds(path: path), withPadding: 48)
        if animated { map.animate(with: camera) } else { map.moveCamera(camera) }
    }

    final class Coordinator { var routeID: UUID? }
}

/// Apple map preview works before Google SDK credentials are configured. Google supplies live
/// place search and route geometry; the UI labels this preview renderer explicitly.
private struct NativePreviewMap: View {
    let route: RoutePlan
    @State private var position: MapCameraPosition = .automatic

    private var region: MKCoordinateRegion {
        let latitudes = route.checkpoints.map { $0.coordinate.latitude }
        let longitudes = route.checkpoints.map { $0.coordinate.longitude }
        let north = latitudes.max() ?? 0, south = latitudes.min() ?? 0
        let east = longitudes.max() ?? 0, west = longitudes.min() ?? 0
        let latitudeSpan = max(0.003, (north - south) * 1.8)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (north + south) / 2,
                                           longitude: (east + west) / 2),
            span: MKCoordinateSpan(latitudeDelta: latitudeSpan,
                                   longitudeDelta: max(0.004, (east - west) * 2.2)))
    }

    var body: some View {
        Map(position: $position) {
            MapPolyline(coordinates: route.checkpoints.map(\.coordinate)).stroke(.white, lineWidth: 9)
            MapPolyline(coordinates: route.checkpoints.map(\.coordinate)).stroke(PointTheme.route, lineWidth: 5)
            if let start = route.checkpoints.first {
                Annotation("Start", coordinate: start.coordinate, anchor: .center) {
                    Circle().fill(PointTheme.accent).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.white, lineWidth: 4)).shadow(color: .black.opacity(0.12), radius: 3)
                        .accessibilityLabel("Route starting point")
                }
            }
            ForEach(Array(route.beacons.enumerated()), id: \.offset) { index, beacon in
                Annotation(beacon.isFinalDestination ? route.destinationName : "Next point", coordinate: beacon.coordinate) {
                    Image(systemName: beacon.isFinalDestination ? "mappin" : "circle.fill")
                        .font(beacon.isFinalDestination ? .title2.bold() : .caption2)
                        .foregroundStyle(.white)
                        .padding(beacon.isFinalDestination ? 12 : 5)
                        .background(PointTheme.accent, in: Circle())
                        .accessibilityLabel(beacon.isFinalDestination ? "Destination" : "Route beacon \(index + 1)")
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls { MapCompass() }
        .onAppear { position = .region(region) }
        .onChange(of: route.id) { _, _ in position = .region(region) }
    }
}
