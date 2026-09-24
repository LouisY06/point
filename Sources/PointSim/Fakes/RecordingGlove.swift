import Foundation
import PointCore

/// `GloveTransport` with timestamped command capture and link faults. `SimulatedGlove` cannot be
/// reused directly because the trace needs the virtual time of every motor command.
@MainActor public final class RecordingGlove: GloveTransport {
    public struct Command {
        public let second: Double
        public let command: HapticCommand
    }

    public private(set) var connection: GloveConnection = .disconnected
    public var onEvent: ((GloveEvent) -> Void)?
    public private(set) var commands: [Command] = []
    public private(set) var rejectedCommands = 0
    public var now: Double = 0
    /// Set when the firmware link should reject writes even though the app believes it is ready.
    public var failWrites = false

    private let capabilities: GloveCapabilities

    public init(capabilities: GloveCapabilities) { self.capabilities = capabilities }

    public func connect() {
        guard connection != .ready else { return }
        connection = .connecting
        onEvent?(.connection(.connecting))
        connection = .ready
        onEvent?(.connection(.ready))
        onEvent?(.capabilities(capabilities))
    }

    public func disconnect() {
        guard connection != .disconnected else { return }
        connection = .disconnected
        onEvent?(.connection(.disconnected))
    }

    public func send(_ command: HapticCommand) throws {
        guard connection == .ready else {
            rejectedCommands += 1
            throw GloveTransportError.notConnected
        }
        if failWrites {
            rejectedCommands += 1
            throw GloveTransportError.unsupported
        }
        commands.append(Command(second: now, command: command))
    }

    public func emit(_ event: GloveEvent) {
        guard connection == .ready else { return }
        onEvent?(event)
    }

    /// Drains commands recorded since the last call, so each tick attributes its own output.
    public func drain() -> [Command] {
        defer { commands.removeAll(keepingCapacity: true) }
        return commands
    }
}
