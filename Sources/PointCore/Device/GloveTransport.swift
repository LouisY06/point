import Foundation

public enum GloveConnection: String { case disconnected, connecting, ready }
public enum GloveGesture: String { case checkDirection, pauseResume }

public struct GloveCapabilities {
    public let heading: Bool
    public let gestures: Bool
    public let vibration: Bool

    public init(heading: Bool, gestures: Bool, vibration: Bool) {
        self.heading = heading
        self.gestures = gestures
        self.vibration = vibration
    }
}

public enum GloveEvent {
    case connection(GloveConnection)
    case capabilities(GloveCapabilities)
    case heading(HeadingReading)
    case gesture(GloveGesture)
    case battery(percent: Int)
}

/// App-side command model, not a finalized BLE wire format or DRV2605 effect number.
public enum HapticCommand: Equatable {
    case stop
    /// A finite, low-duty confirmation pulse; firmware must stop it locally after durationMs.
    case confirm(durationMs: UInt16, intensity: UInt8)
    /// Our bus/train is at the platform (or it is time to get off). A recognisably different,
    /// finite pattern; the firmware chooses the exact motor sequence.
    case vehicleArrived
}

@MainActor public protocol GloveTransport: AnyObject {
    var connection: GloveConnection { get }
    var onEvent: ((GloveEvent) -> Void)? { get set }
    func connect()
    func disconnect()
    func send(_ command: HapticCommand) throws
}

public enum GloveTransportError: Error { case notConnected, unsupported, busy }

/// Develop UI, route progression and feedback without access to a glove.
@MainActor public final class SimulatedGlove: GloveTransport {
    public private(set) var connection: GloveConnection = .disconnected
    public var onEvent: ((GloveEvent) -> Void)?
    public private(set) var commands: [HapticCommand] = []

    public init() {}

    public func connect() {
        connection = .connecting
        onEvent?(.connection(.connecting))
        connection = .ready
        onEvent?(.connection(.ready))
        onEvent?(.capabilities(GloveCapabilities(heading: true, gestures: true, vibration: true)))
    }

    public func disconnect() {
        connection = .disconnected
        onEvent?(.connection(.disconnected))
    }

    public func send(_ command: HapticCommand) throws {
        guard connection == .ready else { throw GloveTransportError.notConnected }
        commands.append(command)
    }

    public func emit(_ event: GloveEvent) {
        guard connection == .ready else { return }
        onEvent?(event)
    }
}

/// Prevents motor-command spam. Re-evaluate on sensor events and an active-session watchdog.
public struct HapticScheduler {
    private var lastPulse: Date?
    private var wasConfirming = false

    public init() {}

    public mutating func command(for feedback: DirectionFeedback, now: Date = Date()) -> HapticCommand? {
        guard feedback.shouldConfirm else {
            let needsStop = wasConfirming
            lastPulse = nil
            wasConfirming = false
            return needsStop ? .stop : nil
        }
        guard lastPulse.map({ now.timeIntervalSince($0) >= 0.9 }) ?? true else { return nil }
        lastPulse = now
        wasConfirming = true
        return .confirm(durationMs: 180, intensity: 160)
    }

    public mutating func reset() { lastPulse = nil; wasConfirming = false }
}
