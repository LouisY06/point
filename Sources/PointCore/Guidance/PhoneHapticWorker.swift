import Foundation

/// UI-facing mailbox. Hardware state is confined to `queue`; the lock protects only the
/// latest request and status, never a hardware operation. Slow output cannot build a backlog.
public final class PhoneHapticWorker: @unchecked Sendable {
    public enum Command { case prepare, intensity(Double), silence, shutdown }
    public struct Snapshot {
        public var errorMessage: String?
        /// Last intensity accepted by the API, not a measurement of the physical motor.
        public var submittedIntensity: Double = 0
        public var timestamp: TimeInterval = 0
    }
    private struct Request {
        var command: Command
        var session: UUID
        var sequence: UInt64
        var timestamp: TimeInterval
    }
    private let queue = DispatchQueue(label: "com.point.haptic-output", qos: .userInteractive)
    private let lock = NSLock()
    private let makeOutput: (DispatchQueue) -> any PhoneHapticOutput
    private var pending: Request?
    private var draining = false
    private var sequence: UInt64 = 0
    private var status = Snapshot()
    // Accessed only on queue.
    private var playback: PhoneHapticPlayback?
    private var session: UUID?

    public init(makeOutput: @escaping (DispatchQueue) -> any PhoneHapticOutput) {
        self.makeOutput = makeOutput
    }

    public var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        var value = status
        if ProcessInfo.processInfo.systemUptime - value.timestamp > PhoneHapticPlayback.burstDuration {
            value.submittedIntensity = 0
        }
        return value
    }

    public func submit(_ command: Command, session: UUID) {
        lock.lock()
        sequence &+= 1
        pending = Request(command: command, session: session, sequence: sequence,
                          timestamp: ProcessInfo.processInfo.systemUptime)
        switch command {
        case .silence, .shutdown: status.submittedIntensity = 0
        default: break
        }
        let schedule = !draining
        draining = true
        lock.unlock()
        if schedule { queue.async { self.drain() } }
    }

    private func drain() {
        lock.lock()
        guard let request = pending else {
            draining = false
            lock.unlock()
            return
        }
        pending = nil
        lock.unlock()

        if playback == nil { playback = PhoneHapticPlayback(output: makeOutput(queue)) }
        let playback = playback!
        if session != request.session {
            playback.shutdown()
            session = request.session
        }
        let now = ProcessInfo.processInfo.systemUptime
        switch request.command {
        case .prepare: playback.prepare(now: now)
        case .intensity(let value):
            playback.update(intensity: value, isActive: isCurrent(request), now: now,
                            shouldPlay: { self.isCurrent(request) })
        case .silence: playback.silence()
        case .shutdown: playback.shutdown()
        }
        lock.lock()
        if sequence == request.sequence {
            status = Snapshot(errorMessage: playback.errorMessage, submittedIntensity: playback.submittedIntensity,
                              timestamp: ProcessInfo.processInfo.systemUptime)
        }
        lock.unlock()
        // Give stop/reset callbacks a chance to run between updates on the same queue.
        queue.async { self.drain() }
    }

    private func isCurrent(_ request: Request) -> Bool {
        lock.lock()
        let current = sequence == request.sequence
        lock.unlock()
        return current && ProcessInfo.processInfo.systemUptime - request.timestamp <= 0.3
    }
}
