import PointCore
import SwiftUI

struct TransitRouteBadge: View {
    let route: TransitRoute

    private var hex: String { route.isBus ? "496FA6" : route.colorHex }
    private var ink: Color {
        let value = UInt32(hex, radix: 16) ?? 0
        func linear(_ channel: UInt32) -> Double {
            let c = Double(channel) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear((value >> 16) & 255) + 0.7152 * linear((value >> 8) & 255) + 0.0722 * linear(value & 255)
        return luminance > 0.179 ? .black : .white
    }

    var body: some View {
        Label(route.name, systemImage: route.isBus ? "bus.fill" : "tram.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(hex: hex), in: RoundedRectangle(cornerRadius: 8))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct JourneyChoiceRow: View {
    let plan: JourneyPlan

    private var walkingDetail: String {
        let walks = plan.legs.compactMap { if case .walk(let walk) = $0 { return walk } else { return nil } }
        let times = walks.compactMap(\.expectedTravelTime)
        let walking = times.count == walks.count ? "\(max(1, Int(ceil(times.reduce(0, +) / 60)))) min walking" : "\(walks.count) walking legs"
        let transfers = max(0, plan.rides.count - 1)
        return walking + " · " + (transfers == 0 ? "No transfers" : "\(transfers) \(transfers == 1 ? "transfer" : "transfers")")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { badges }
                VStack(alignment: .leading, spacing: 8) { badges }
            }
            Text(walkingDetail).font(.subheadline).foregroundStyle(Color.primary)
            if let first = plan.rides.first, let last = plan.rides.last {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Board at \(first.board.name)")
                    Text("Get off at \(last.alight.name)")
                }
                .font(.subheadline).foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(plan.summary)
        .accessibilityHint("Review this route on the map")
    }

    private var badges: some View {
        ForEach(Array(plan.rides.enumerated()), id: \.offset) { _, ride in
            TransitRouteBadge(route: ride.route)
        }
    }
}

struct JourneyLegRow: View {
    let leg: JourneyLeg
    let current: Bool
    let passed: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: glyph)
                .font(.body.weight(.medium))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(width: 24, height: 26)
                .foregroundStyle(current ? PointTheme.action : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                if current, dynamicTypeSize.isAccessibilitySize {
                    Text("Now").font(.caption.weight(.semibold)).foregroundStyle(PointTheme.action)
                }
                switch leg {
                case .walk(let walk):
                    Text("Walk to \(walk.destinationName)")
                        .font(.subheadline.weight(current ? .semibold : .regular))
                case .ride(let ride):
                    TransitRouteBadge(route: ride.route)
                    Text("Toward \(ride.headsign)").font(.subheadline)
                    Text("\(ride.stopsRidden) \(ride.stopsRidden == 1 ? "stop" : "stops") · Get off at \(ride.alight.name)")
                        .font(.subheadline).foregroundStyle(Color.secondary)
                case .transfer(let station):
                    Text("Change at \(station.name)").font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            if current, !dynamicTypeSize.isAccessibilitySize {
                Text("Now").font(.caption.weight(.semibold)).foregroundStyle(PointTheme.action)
            }
        }
        .foregroundStyle(passed ? Color.secondary : Color.primary)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private var glyph: String {
        if passed { return "checkmark" }
        switch leg {
        case .walk: return "figure.walk"
        case .ride(let ride): return ride.route.isBus ? "bus.fill" : "tram.fill"
        case .transfer: return "arrow.triangle.swap"
        }
    }
}
