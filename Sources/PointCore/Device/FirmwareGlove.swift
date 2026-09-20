import Foundation

/// Testable BLE session, independent of CoreBluetooth. One exchange and one latest
/// motor command are retained; route size never affects this buffer.
@MainActor public final class FirmwareGlove: GloveTransport {
    public enum State: Equatable { case disconnected, negotiating, echoOnly, ready, failed }
    public private(set) var state: State = .disconnected
    public private(set) var connection: GloveConnection = .disconnected
    public private(set) var capabilities: GloveCapabilities?
    public private(set) var lastHeading: HeadingReading?
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
    private var queued: (command: HapticCommand, time: Date)?
    private var token = UInt32.random(in: 1...UInt32.max / 2)
    private var supportsArrival = false
    private var lastPoll = Date.distantPast

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
    /// Discovery/physical connection remains an explicit Device setup action.
    public func connect() {
        onEvent?(.connection(connection))
        if let capabilities { onEvent?(.capabilities(capabilities)) }
    }

    public func disconnect() {
        exchange = nil
        queued = nil
        capabilities = nil
        lastHeading = nil
        lastMotorAcknowledgement = nil
        supportsArrival = false
        lastPoll = .distantPast
        state = .disconnected
        connection = .disconnected
        message = nil
        onEvent?(.connection(.disconnected))
        onChange?()
    }

    public func send(_ command: HapticCommand) throws { try send(command, now: Date()) }

    public func send(_ command: HapticCommand, now: Date) throws {
        guard connection == .ready else { throw GloveTransportError.notConnected }
        guard capabilities?.vibration == true,
              command != .vehicleArrived || supportsArrival else { throw GloveTransportError.unsupported }
        _ = try FirmwareProtocol.request(.haptic, token: token, command: command)
        // A stop cannot be overwritten by another cue before it has been sent.
        guard queued?.command != .stop || command == .stop else { throw GloveTransportError.busy }
        queued = (command, now)
        tick(now: now)
    }

    public func tick(now: Date = Date()) {
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
        if let next = queued {
            queued = nil
            // Never replay an old cue after a slow reply. Stops do not expire.
            if next.command == .stop || (0...0.3).contains(now.timeIntervalSince(next.time)) {
                transmit(.haptic, command: next.command, now: now)
                return
            }
        }
        if capabilities?.heading == true, now.timeIntervalSince(lastPoll) >= 0.1 {
            lastPoll = now
            transmit(.heading, now: now)
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
            supportsArrival = data.last.map { $0 & 4 != 0 } ?? false
            state = .ready
            connection = .ready
            message = value.vibration ? "Glove vibration available" : "Motor support pending"
            // Stop before advertising readiness, since a controller may synchronously send.
            if value.vibration { queued = (.stop, now) }
            tick(now: now)
            onEvent?(.connection(.ready))
            onEvent?(.capabilities(value))
        case .heading(let degrees, let accuracy, let reference, let age):
            // Bound sample age conservatively by FULL request round trip plus firmware
            // sample age. A buffered/late sample never becomes fresh just on receipt.
            guard elapsed + age <= 0.5 else { onChange?(); return }
            let reading = HeadingReading(degrees: degrees, accuracyDegrees: accuracy,
                                         timestamp: now.addingTimeInterval(-(elapsed + age)), reference: reference)
            lastHeading = reading
            message = reference == .trueNorth ? "Glove heading available" : "Glove needs a north reference for navigation"
            onEvent?(.heading(reading))
        case .haptic(let accepted):
            guard accepted else { fail("The glove rejected a motor command. Check its firmware."); return }
            lastMotorAcknowledgement = now
        }
        onChange?()
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
