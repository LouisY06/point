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
                             : "Power on your Point device with Bluetooth firmware and keep it near your iPhone. Then scan and select your device.")
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
                        LabeledContent("Device", value: connection.deviceName ?? "Point device")
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
                    Section("Hardware sensor calibration") {
                        Text(connection.calibrationLevels).font(.subheadline.monospacedDigit())
                        if connection.hardwareCalibrationSupported {
                            Button(connection.hardwareCalibrationInProgress ? "Calibrating sensors…" : "Restart sensor calibration") {
                                connection.recalibrateHardware()
                            }.frame(minHeight: 44).disabled(connection.hardwareCalibrationInProgress)
                            if let status = connection.hardwareCalibrationStatus { Text(status).foregroundStyle(.secondary) }
                            Text("Keep the glove still for the gyro. Then move it gently through different orientations, away from magnets, to settle the compass. Your saved finger direction stays unchanged.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("Update the glove firmware to restart sensor calibration here. Powering the glove off and on also restarts its sensors.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section(connection.pointingReady ? "Glove pointing · Saved" : "Glove pointing setup") {
                        if !connection.pointingReady {
                            Text("Fasten the sensor firmly to your glove and hold it still for a few seconds.")
                            Text("Point your straight finger down and capture the pose. Then point it straight up and capture again.")
                        }
                        Text(connection.calibrationStatus).foregroundStyle(.secondary)
                        if connection.capturingPose { ProgressView("Measuring direction…") }
                        if !connection.pointingReady {
                            Button(connection.hasFirstPose ? "Capture upward pose" : "Capture downward pose") { connection.capturePose() }
                                .frame(minHeight: 44)
                                .disabled(connection.capturingPose || !connection.sensorReady)
                        }
                        Button(connection.pointingReady ? "Sensor moved · Set up again" : "Start setup over") { connection.resetCalibration() }
                            .frame(minHeight: 44).disabled(connection.capturingPose)
                        Text("During guidance, point forward within 30° of level. Lower your hand to stop vibration.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Glove guidance") {
                        if let sensor = connection.sensorSummary { Text(sensor).foregroundStyle(.secondary) }
                        Text(connection.firmwareMessage)
                        if connection.canTestMotor {
                            Button("Test glove vibration") { connection.testMotor() }
                                .frame(minHeight: 44)
                        }
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
                    Text("Use Point S3 firmware for glove controls. The Arduino circuit test uses USB only. Direction guidance also requires calibrated sensors and verified glove mounting.")
                }
            }
            .navigationTitle("Device setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: connection.phase) { _, _ in
                UIAccessibility.post(notification: .announcement,
                                     argument: connection.message ?? connection.title)
            }
            .onAppear { connection.beginSetup() }
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
