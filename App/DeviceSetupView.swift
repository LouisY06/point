import SwiftUI

struct DeviceSetupView: View {
    @ObservedObject var connection: DeviceConnection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: connection.isConnected ? "checkmark.circle" : "antenna.radiowaves.left.and.right")
                            .font(.largeTitle)
                            .foregroundStyle(.primary)
                            .accessibilityHidden(true)
                        Text(connection.title).font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(connection.isConnected
                             ? "Your iPhone and \(connection.deviceName ?? "device") can send and receive messages."
                             : "Power on BT Test C6 and keep it near your iPhone. Then scan and select your device.")
                            .font(.body).foregroundStyle(.secondary)
                        if connection.isWorking {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text(progressLabel).font(.subheadline)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.vertical, 12)
                }

                if let message = connection.message {
                    Section {
                        Text(message)
                        if connection.permissionDenied {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }

                if !connection.devices.isEmpty && !connection.hasLink {
                    Section("Nearby devices") {
                        ForEach(connection.devices) { device in
                            Button { connection.connect(to: device) } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: "cpu").accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(device.name).font(.body.weight(.medium))
                                        Text("\(signalLabel(device.signal)) · \(device.id.uuidString.suffix(4))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true)
                                }
                                .foregroundStyle(.primary)
                                .frame(minHeight: 48)
                            }
                            .accessibilityLabel("Connect to \(device.name), device \(device.id.uuidString.suffix(4))")
                        }
                    }
                }

                if connection.isConnected {
                    Section("Connection test") {
                        LabeledContent("Device", value: connection.deviceName ?? "BT Test C6")
                        if let verifiedAt = connection.verifiedAt {
                            LabeledContent("Last verified") { Text(verifiedAt, style: .time) }
                        }
                        if let reply = connection.lastReply {
                            LabeledContent("Device reply", value: reply)
                                .font(.subheadline).textSelection(.enabled)
                        }
                        Button("Test connection again") { connection.testConnection() }
                            .frame(minHeight: 44)
                    }
                }

                Section {
                    if connection.canScan {
                        Button(connection.phase == .idle && connection.message == nil && connection.devices.isEmpty
                               ? "Scan for device" : "Scan again") { connection.scan() }
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .buttonStyle(PointFilledButtonStyle())
                    }
                    if connection.isWorking || connection.hasLink {
                        Button(connection.isConnected ? "Disconnect" : "Cancel", role: .cancel) { connection.disconnect() }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                } footer: {
                    Text("This firmware tests the Bluetooth connection. Glove direction and vibration support are still being added.")
                }
            }
            .navigationTitle("Device setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: connection.phase) { _, _ in
                UIAccessibility.post(notification: .announcement,
                                     argument: connection.message ?? connection.title)
            }
            .onDisappear { connection.setupDismissed() }
        }
        .tint(PointTheme.action)
    }

    private var progressLabel: String {
        switch connection.phase {
        case .scanning: return "Scanning nearby…"
        case .connecting: return connection.deviceName ?? "Connecting…"
        case .discovering: return "Enabling device replies…"
        case .verifying: return "Waiting for a matching reply…"
        default: return "Waiting for Bluetooth…"
        }
    }

    private func signalLabel(_ signal: Int?) -> String {
        guard let signal else { return "Signal unavailable" }
        return signal >= -65 ? "Strong signal" : signal >= -85 ? "Good signal" : "Weak signal"
    }
}
