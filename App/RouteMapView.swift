import MapKit
import PointCore
import SwiftUI

struct RouteMapView: View {
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
