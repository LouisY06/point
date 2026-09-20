import ActivityKit
import Foundation

struct PocketActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var beacon: Int
        var total: Int
        var steps: Int
        var status: String
        var distance: Double?
        var stationary: Bool? = nil
    }
    var sessionID: UUID
}
