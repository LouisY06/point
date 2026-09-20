import ActivityKit
import SwiftUI
import WidgetKit

@main struct PointPocketWidgets: WidgetBundle {
    var body: some Widget { PocketActivityWidget() }
}

struct PocketActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PocketActivityAttributes.self) { context in
            HStack(spacing: 16) {
                Image(systemName: "hand.point.up.fill").font(.title).foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Point · Beacon \(context.state.beacon) of \(context.state.total)").font(.headline)
                    Text(context.isStale ? "Tracking update delayed · Open Point" : context.state.status)
                        .font(.subheadline)
                    Text(context.state.stationary == true ? "Pointing test · Stay in the same spot" : "\(context.state.steps) steps · Estimated position").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(18)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.yellow)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "hand.point.up.fill").foregroundStyle(.yellow) }
                DynamicIslandExpandedRegion(.trailing) { Text("\(context.state.beacon)/\(context.state.total)") }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.isStale ? "Tracking delayed · Open Point" : context.state.status).font(.caption)
                }
            } compactLeading: {
                Image(systemName: "hand.point.up.fill").foregroundStyle(.yellow)
            } compactTrailing: {
                Text("\(context.state.beacon)").foregroundStyle(.yellow)
            } minimal: {
                Image(systemName: "hand.point.up.fill").foregroundStyle(.yellow)
            }.keylineTint(.yellow)
        }
    }
}
