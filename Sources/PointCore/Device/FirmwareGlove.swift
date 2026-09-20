import Foundation

/// Testable BLE session, independent of CoreBluetooth. One exchange and one latest
/// motor command are retained; route size never affects this buffer.
@MainActor public final class FirmwareGlove: GloveTransport {
    public enum State: Equatable { case disconnected, negotiating, echoOnly, ready, failed }
    public private(set) var state: State = .disconnected
    public private(set) var connection: GloveConnection = .disconnected
    public private(set) var capabilities: GloveCapabilities?
    public private(set) var lastHeading: HeadingReading?
    public private(set) var sensorHealth: FirmwareSensorHealth?
    public private(set) var orientation: GloveOrientationSample?
    public private(set) var calibrationID = UUID()
    public private(set) var relativeCalibrationID = UUID()
    public private(set) var relativeReference = RelativeOrientationReference()
    public private(set) var pointingCalibration: PointingCalibration?
    public var onHeadingChange: ((HeadingReading?) -> Void)?
    public var northCorrection: MagneticNorthCorrection?
    public private(set) var message: String?
    public private(set) var lastMotorAcknowledgement: Date?
    public var onEvent: ((GloveEvent) -> Void)?
    public var onChange: (() -> Void)?
    public var write: ((Data) throws -> Void)?

    private struct Exchange {
        let operation: FirmwareProtocol.Operation
        let token: UInt32
        let sent: Date
    }
    private var exchange: Exchange?
    private var queued: (command: HapticCommand, time: Date, requiresPointing: Bool, relativeDemo: Bool)?
    private var token = UInt32.random(in: 1...UInt32.max / 2)
    private var supportsArrival = false
    private var supportsAttitude = false
    public private(set) var supportsOrientation = false
    public private(set) var supportsHardwareCalibration = false
    public private(set) var hardwareCalibrationInProgress = false
    public private(set) var hardwareCalibrationMessage: String?
    private var calibrationQueued = false
    private var calibrationAccepted = false
    private var lastPoll = Date.distantPast
    private var motorBusyUntil = Date.distantPast
    private var automaticMotorUntil = Date.distantPast
    private var automaticRelativeDemo = false

    public init() {}

    /// Called only after the physical BLE link has passed its echo test.
    public func beginLink(now: Date = Date()) {
        disconnect()
        state = .negotiating
        connection = .connecting
        message = "Checking glove support…"
        onEvent?(.connection(.connecting))
        transmit(.hello, now: now)
        onChange?()
    }

    /// Replays negotiated state when a walking controller selects this transport.
    /// DeviceConnection owns discovery and reconnecting the remembered peripheral.
    public func connect() {
        onEvent?(.connection(connection))
        if let capabilities { onEvent?(.capabilities(capabilities)) }
    }

    public func disconnect() {
        exchange = nil
        queued = nil
        capabilities = nil
        lastHeading = nil
        sensorHealth = nil
        orientation = nil
        pointingCalibration = nil
        calibrationID = UUID()
        relativeCalibrationID = UUID()
        relativeReference = RelativeOrientationReference()
        onHeadingChange?(nil)
        northCorrection = nil
        lastMotorAcknowledgement = nil
        supportsHardwareCalibration = false
        hardwareCalibrationInProgress = false; hardwareCalibrationMessage = nil
        calibrationQueued = false; calibrationAccepted = false
        supportsArrival = false
        supportsAttitude = false
        supportsOrientation = false
        lastPoll = .distantPast
        motorBusyUntil = .distantPast
        automaticMotorUntil = .distantPast
        state = .disconnected
        connection = .disconnected
        message = nil
        onEvent?(.connection(.disconnected))
        onChange?()
    }

    /// Restarts sensor offsets/fusion, preserving the separately saved mounting vector.
    public func recalibrateHardware(now: Date = Date()) throws {
        guard connection == .ready else { throw GloveTransportError.notConnected }
        guard supportsHardwareCalibration else { throw GloveTransportError.unsupported }
        guard !hardwareCalibrationInProgress else { throw GloveTransportError.busy }
        hardwareCalibrationInProgress = true; calibrationQueued = true; calibrationAccepted = false
        hardwareCalibrationMessage = "Restarting sensors. Keep the glove still."
        orientation = nil; sensorHealth = nil
        calibrationID = UUID(); relativeCalibrationID = UUID()
        relativeReference = RelativeOrientationReference()
        invalidateHeading("Hardware calibration restarting · Guidance paused")
        // Stop takes precedence, then reset is sent after the stop acknowledgement.
        if capabilities?.vibration == true { queued = (.stop, now, false, false) }
        tick(now: now)
        onChange?()
    }

    public func send(_ command: HapticCommand) throws { try send(command, now: Date()) }

    /// Explicit setup test; like transit alerts, it does not require pointing forward.
    public func testMotor(now: Date = Date()) throws {
        guard now >= motorBusyUntil else { throw GloveTransportError.busy }
        try enqueue(.confirm(durationMs: 180, intensity: 160), now: now, requiresPointing: false)
    }

    public func send(_ command: HapticCommand, now: Date) throws {
        // Transit alerts must be felt while waiting with the hand lowered, too.
        try enqueue(command, now: now, requiresPointing: command != .vehicleArrived)
    }

    /// Only the explicitly aligned indoor demo may use relative yaw. Outdoor send
    /// remains north-gated. Freshness, mounting health and hand elevation still apply.
    public func sendRelativeDemo(_ command: HapticCommand, now: Date = Date()) throws {
        switch command {
        case .stop: break
        case .confirm(let duration, let intensity) where duration <= 180 && intensity <= 204: break
        default: throw GloveTransportError.unsupported
        }
        try enqueue(command, now: now, requiresPointing: true, relativeDemo: true)
    }

    private func pointingAvailable(now: Date, relativeDemo: Bool) -> Bool {
        relativeDemo ? relativePointing(now: now) != nil : magneticPointing(now: now) != nil
    }

    private func enqueue(_ command: HapticCommand, now: Date, requiresPointing: Bool, relativeDemo: Bool = false) throws {
        guard connection == .ready else { throw GloveTransportError.notConnected }
        guard command == .stop || !hardwareCalibrationInProgress else { throw GloveTransportError.busy }
        guard capabilities?.vibration == true,
              command != .vehicleArrived || supportsArrival else { throw GloveTransportError.unsupported }
        if command != .stop, requiresPointing, (supportsOrientation || relativeDemo), !pointingAvailable(now: now, relativeDemo: relativeDemo) {
            throw GloveTransportError.unsupported
        }
        _ = try FirmwareProtocol.request(.haptic, token: token, command: command)
        // A stop cannot be overwritten by another cue before it has been sent.
        guard queued?.command != .stop || command == .stop else { throw GloveTransportError.busy }
        queued = (command, now, requiresPointing, relativeDemo)
        tick(now: now)
    }

    public func tick(now: Date = Date()) {
        if supportsOrientation, automaticMotorUntil > now, !pointingAvailable(now: now, relativeDemo: automaticRelativeDemo) {
            queued = (.stop, now, false, false)
        }
        if let heading = lastHeading, !(0...0.5).contains(now.timeIntervalSince(heading.timestamp)) {
            invalidateHeading("Waiting for a fresh glove heading")
            onChange?()
        }
        if let pending = exchange {
            let limit: TimeInterval = pending.operation == .hello ? 2 : 0.5
            guard now.timeIntervalSince(pending.sent) > limit else { return }
            if pending.operation == .hello {
                exchange = nil
                state = .echoOnly
                connection = .disconnected
                message = "Bluetooth works · Glove firmware support pending"
                onEvent?(.connection(.disconnected))
                onChange?()
            } else { fail("Glove stopped replying. Reconnect before continuing.") }
            return
        }
        guard state == .ready else { return }
        if let next = queued, next.command == .stop || now >= motorBusyUntil {
            queued = nil
            // Never replay an old cue after a slow reply. Stops do not expire.
            if next.command == .stop || ((0...0.3).contains(now.timeIntervalSince(next.time)) &&
                (!next.requiresPointing || (!supportsOrientation && !next.relativeDemo) || pointingAvailable(now: now, relativeDemo: next.relativeDemo))) {
                automaticRelativeDemo = next.relativeDemo
                switch next.command {
                case .stop: motorBusyUntil = .distantPast; automaticMotorUntil = .distantPast
                case .confirm(let duration, _):
                    motorBusyUntil = now.addingTimeInterval(Double(duration) / 1000 + 0.05)
                    automaticMotorUntil = next.requiresPointing ? motorBusyUntil : .distantPast
                case .vehicleArrived:
                    // Keep the older four-pulse firmware's cooldown until it is updated.
                    // Current firmware plays three pulses in 560 ms with the same command.
                    motorBusyUntil = now.addingTimeInterval(0.83)
                    automaticMotorUntil = next.requiresPointing ? motorBusyUntil : .distantPast
                }
                transmit(.haptic, command: next.command, now: now)
                return
            }
        }
        if calibrationQueued {
            calibrationQueued = false
            transmit(.recalibrateSensors, now: now)
            return
        }
        if capabilities?.heading == true, now.timeIntervalSince(lastPoll) >= 0.1 {
            lastPoll = now
            transmit(supportsOrientation ? .orientation : supportsAttitude ? .attitude : .heading, now: now)
        }
    }

    public func receive(_ data: Data, now: Date = Date()) {
        guard let pending = exchange else { return }
        let elapsed = now.timeIntervalSince(pending.sent)
        guard elapsed >= 0, elapsed <= (pending.operation == .hello ? 2 : 0.5),
              let reply = try? FirmwareProtocol.reply(data, operation: pending.operation, token: pending.token) else { return }
        exchange = nil
        switch reply {
        case .capabilities(let value):
            capabilities = value
            supportsHardwareCalibration = data.last.map { $0 & 32 != 0 } ?? false
            supportsArrival = data.last.map { $0 & 4 != 0 } ?? false
            supportsOrientation = data.last.map { $0 & 16 != 0 } ?? false
            supportsAttitude = data.last.map { $0 & 8 != 0 } ?? false
            state = .ready
            connection = .ready
            message = value.vibration ? "Glove vibration available" : "Motor support pending"
            // Stop before advertising readiness, since a controller may synchronously send.
            if value.vibration { queued = (.stop, now, false, false) }
            tick(now: now)
            guard state == .ready else { return }
            onEvent?(.connection(.ready))
            onEvent?(.capabilities(value))
        case .orientation(let quaternion, let age, let health):
            // A reading already in flight before the restart must not restore readiness.
            if hardwareCalibrationInProgress, !calibrationAccepted { onChange?(); return }
            let previouslyNorthReady = sensorHealth?.fusionBlockingReason == nil && sensorHealth != nil
            sensorHealth = health
            guard elapsed + age <= 0.5 else {
                orientation = nil
                invalidateHeading("Waiting for a fresh glove orientation"); onChange?(); return
            }
            if hardwareCalibrationInProgress, calibrationAccepted {
                if let reason = health.mountingBlockingReason {
                    hardwareCalibrationMessage = "Hardware calibration: \(reason)"
                } else {
                    hardwareCalibrationInProgress = false
                    hardwareCalibrationMessage = "Gyro ready. Move the glove gently away from magnets if the compass still needs settling."
                }
            }
            let sample = GloveOrientationSample(quaternion: quaternion,
                timestamp: now.addingTimeInterval(-(elapsed + age)), health: health)
            relativeReference.update(previous: orientation, current: sample)
            orientation = sample
            if !previouslyNorthReady, health.fusionBlockingReason == nil { calibrationID = UUID() }
            if let reason = health.mountingBlockingReason {
                // A temporary sensor-quality dip does not change the physical mounting.
                // Retain the mapping while health gates directional haptics.
                invalidateHeading(reason); onChange?(); return
            }
            if let reason = health.fusionBlockingReason {
                // A yaw-reference change leaves the sensor-local finger vector
                // intact, but invalidates any AR-room-to-magnetic-north offset.
                if previouslyNorthReady { calibrationID = UUID() }
                invalidateHeading(reason); onChange?(); return
            }
            guard let pointingCalibration else {
                invalidateHeading("Glove pointing orientation needs setup"); onChange?(); return
            }
            guard let magnetic = pointingCalibration.magneticHeading(sample, now: now) else {
                invalidateHeading("Raise your hand and point forward · Keep your finger within 30° of level"); onChange?(); return
            }
            guard let reading = northCorrection?.apply(to: magnetic, now: now), reading.accuracyDegrees <= 25 else {
                invalidateHeading("Waiting for an accurate true-north correction"); onChange?(); return
            }
            lastHeading = reading
            message = "Glove pointing ready"
            onHeadingChange?(reading)
            onEvent?(.heading(reading))
        case .heading(let degrees, let accuracy, let reference, let age, let health):
            sensorHealth = health
            // Bound sample age conservatively by FULL request round trip plus firmware
            // sample age. A buffered/late sample never becomes fresh just on receipt.
            guard elapsed + age <= 0.5 else {
                invalidateHeading("Waiting for a fresh glove heading"); onChange?(); return
            }
            if let reason = health?.blockingReason {
                invalidateHeading(reason); onChange?(); return
            }
            var reading = HeadingReading(degrees: degrees, accuracyDegrees: accuracy,
                                         timestamp: now.addingTimeInterval(-(elapsed + age)), reference: reference)
            if health?.source == .bno055, reference == .magneticNorth {
                guard let corrected = northCorrection?.apply(to: reading, now: now) else {
                    invalidateHeading("Waiting for the phone’s true-north correction"); onChange?(); return
                }
                reading = corrected
            }
            guard reading.accuracyDegrees <= 25 else {
                invalidateHeading("Glove compass uncertainty is too high · Direction paused"); onChange?(); return
            }
            lastHeading = reading
            onHeadingChange?(reading)
            message = reading.reference == .trueNorth ? "Glove heading available" : "Glove needs a north reference for navigation"
            onEvent?(.heading(reading))
        case .recalibration(let accepted):
            calibrationAccepted = accepted
            hardwareCalibrationInProgress = accepted
            hardwareCalibrationMessage = accepted ? "Sensors restarting. Hold the glove still, then move gently to settle the compass."
                : "Sensor restart was rejected. Wait a moment and try again."
            orientation = nil; sensorHealth = nil
            invalidateHeading(hardwareCalibrationMessage!)
        case .haptic(let accepted):
            guard accepted else { fail("The glove rejected a motor command. Check its firmware."); return }
            lastMotorAcknowledgement = now
        }
        onChange?()
    }

    public func pointingSetupBlockingReason(now: Date = Date()) -> String? {
        if hardwareCalibrationInProgress { return hardwareCalibrationMessage ?? "Hardware sensors are restarting." }
        guard connection == .ready else { return "Connect your glove to begin." }
        guard supportsOrientation else { return "Update glove firmware to enable pointing setup." }
        guard let orientation, (0...0.5).contains(now.timeIntervalSince(orientation.timestamp)) else {
            return "Waiting for a fresh glove reading…"
        }
        return orientation.health.mountingBlockingReason
    }

    public func magneticPointing(now: Date = Date()) -> HeadingReading? {
        guard connection == .ready, !hardwareCalibrationInProgress, let orientation else { return nil }
        return pointingCalibration?.magneticHeading(orientation, now: now)
    }

    public func relativePointing(now: Date = Date()) -> HeadingReading? {
        guard connection == .ready, !hardwareCalibrationInProgress, let orientation else { return nil }
        guard let reading = pointingCalibration?.relativeHeading(orientation, now: now) else { return nil }
        return relativeReference.apply(to: reading)
    }

    /// Restore fixed mounting geometry as soon as this glove negotiates orientation support.
    /// Live sensor readiness still gates readings and haptics, not the saved mounting map.
    @discardableResult public func restorePointingCalibration(from store: PointingCalibrationStore, for deviceID: UUID) -> Bool {
        guard pointingCalibration == nil, supportsOrientation, connection == .ready,
              let saved = store.load(for: deviceID) else { return false }
        calibrate(saved)
        return true
    }

    public func calibrate(_ calibration: PointingCalibration) {
        guard supportsOrientation, connection == .ready else { return }
        pointingCalibration = calibration
        calibrationID = UUID()
        relativeCalibrationID = UUID()
        relativeReference = RelativeOrientationReference()
        invalidateHeading("Checking calibrated glove direction…")
        onChange?()
    }

    public func resetPointingCalibration() {
        pointingCalibration = nil
        calibrationID = UUID()
        relativeCalibrationID = UUID()
        relativeReference = RelativeOrientationReference()
        invalidateHeading("Glove pointing orientation needs setup")
        try? send(.stop)
        onChange?()
    }

    private func invalidateHeading(_ reason: String) {
        let hadHeading = lastHeading != nil
        lastHeading = nil
        onHeadingChange?(nil)
        message = reason
        if hadHeading { onEvent?(.headingUnavailable) }
    }

    private func transmit(_ operation: FirmwareProtocol.Operation, command: HapticCommand? = nil, now: Date) {
        token &+= 1
        exchange = Exchange(operation: operation, token: token, sent: now)
        do {
            guard let write else { throw GloveTransportError.notConnected }
            try write(FirmwareProtocol.request(operation, token: token, command: command))
        } catch { fail("Could not send to the glove. Reconnect and try again.") }
    }

    public func writeFailed() {
        guard state == .ready || state == .negotiating else { return }
        fail("Bluetooth could not deliver the glove command. Reconnect and try again.")
    }

    private func fail(_ text: String) {
        exchange = nil
        queued = nil
        lastHeading = nil
        capabilities = nil
        sensorHealth = nil
        orientation = nil
        pointingCalibration = nil
        calibrationID = UUID()
        relativeCalibrationID = UUID()
        relativeReference = RelativeOrientationReference()
        onHeadingChange?(nil)
        northCorrection = nil
        supportsHardwareCalibration = false; hardwareCalibrationInProgress = false
        calibrationQueued = false; calibrationAccepted = false
        state = .failed
        connection = .disconnected
        message = text
        onEvent?(.connection(.disconnected))
        onChange?()
        // Firmware is required to stop locally; this is best effort only.
        token &+= 1
        if let packet = try? FirmwareProtocol.request(.haptic, token: token, command: .stop) { try? write?(packet) }
    }
}
