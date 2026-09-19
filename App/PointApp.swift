import GoogleMaps
import SwiftUI

@main struct PointApp: App {
    init() {
        if let key = ProcessInfo.processInfo.environment["GOOGLE_MAPS_IOS_KEY"], !key.isEmpty {
            GMSServices.provideAPIKey(key)
        }
    }
    var body: some Scene { WindowGroup { PointHomeView().preferredColorScheme(.dark) } }
}
