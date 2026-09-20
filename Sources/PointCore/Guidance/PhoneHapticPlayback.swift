import Foundation

public enum PhoneHapticInterruption { case engineStopped, playbackFailed }

/// Platform output boundary, injectable so repeated playback and recovery can be tested.
public protocol PhoneHapticOutput: AnyObject {
    func prepare(onInterruption: @escaping (PhoneHapticInterruption) -> Void) throws
    func startBurst(intensity: Double, duration: TimeInterval) throws
    func changeIntensity(_ intensity: Double) throws
    func silence()
    func shutdown()
}

/// One foreground output stream. All calls and output callbacks must use the same serial queue.
/// The app uses PhoneHapticWorker so hardware calls never block UI/sensor delivery.
public final class PhoneHapticPlayback {
    public private(set) var errorMessage: String?
    public private(set) var submittedIntensity: Double = 0
    private let output: any PhoneHapticOutput
    private var ready = false
    private var burstStarted: TimeInterval?
    private var retryAfter: TimeInterval = 0
    private var generation = UUID()
    private var latestTime: TimeInterval = 0
    public static let burstDuration: TimeInterval = 0.35

    public init(output: any PhoneHapticOutput) { self.output = output }

    public func prepare(now: TimeInterval) {
        latestTime = now
        silence()
        if !ready { _ = ensureReady(now: now) }
    }

    public func update(intensity: Double, isActive: Bool, now: TimeInterval, shouldPlay: () -> Bool = { true }) {
        if now.isFinite { latestTime = now }
        guard isActive, intensity.isFinite, intensity > 0.005, now.isFinite else { silence(); return }
        guard ensureReady(now: now) else { return }
        // Engine startup may take time. Never play a command superseded while it was starting.
        guard shouldPlay() else { silence(); return }
        let value = min(0.8, intensity)
        do {
            if burstStarted.map({ now < $0 || now - $0 >= Self.burstDuration }) ?? true {
                // The previous finite burst has ended. Do not schedule a stop and start
                // for the same cached player at the same immediate timestamp.
                try output.startBurst(intensity: value, duration: Self.burstDuration)
                burstStarted = now
            } else {
                try output.changeIntensity(value)
            }
            submittedIntensity = value
            errorMessage = nil
        } catch { failed(now: now) }
    }

    public func silence() {
        submittedIntensity = 0
        if burstStarted != nil { output.silence() }
        burstStarted = nil
    }

    public func shutdown() {
        generation = UUID()
        output.shutdown()
        submittedIntensity = 0
        ready = false
        burstStarted = nil
        retryAfter = 0
        errorMessage = nil
    }

    private func ensureReady(now: TimeInterval) -> Bool {
        if ready { return true }
        guard now.isFinite, now >= retryAfter else { return false }
        let request = generation
        do {
            try output.prepare { [weak self] reason in
                guard let self, generation == request else { return }
                if reason == .playbackFailed {
                    // An asynchronous start failure must clear the successful-command meter
                    // and rebuild output with the same retry limit as a synchronous failure.
                    failed(now: latestTime)
                    return
                }
                submittedIntensity = 0
                ready = false
                burstStarted = nil
                errorMessage = "Vibration interrupted · Retrying"
            }
            ready = true
            retryAfter = 0
            errorMessage = nil
            return true
        } catch {
            failed(now: now)
            return false
        }
    }

    private func failed(now: TimeInterval) {
        // A poisoned player/engine must not be retried forever. Replace it on the next attempt.
        generation = UUID()
        output.shutdown()
        submittedIntensity = 0
        ready = false
        burstStarted = nil
        retryAfter = now + 1
        errorMessage = "Vibration interrupted · Retrying"
    }
}
