import SwiftUI

struct PhonePointingStatusView: View {
    @ObservedObject var tester: PhoneBeaconTester
    var beaconIndex: Int?
    var beaconCount: Int
    var arrived: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let beaconIndex, beaconCount > 0 {
                Text(arrived ? "Destination reached" : "Heading to beacon \(beaconIndex + 1) of \(beaconCount)")
                    .font(.subheadline.weight(.semibold))
            }
            Label(tester.status, systemImage: "iphone")
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: tester.intensity / 0.8)
                .tint(PointTheme.action)
                .accessibilityLabel("Vibration signal strength")
                .accessibilityValue("\(Int(tester.intensity / 0.8 * 100)) percent")
            if let distance = tester.distanceMeters {
                HStack {
                    Text("Next beacon · \(Int(distance.rounded())) m")
                    Spacer()
                    if let error = tester.angularErrorDegrees {
                        Text("\(Int(abs(error).rounded()))° off")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenDistance(distance, error: tester.angularErrorDegrees))
            }
            if let accuracy = tester.accuracyNote {
                Text(accuracy).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func spokenDistance(_ distance: Double, error: Double?) -> String {
        let meters = "Next beacon \(Int(distance.rounded())) meters away"
        guard let error else { return meters }
        return "\(meters), pointing \(Int(abs(error).rounded())) degrees off"
    }
}
