import Foundation

/// Platform output boundary, injectable so repeated playback and recovery can be tested.
@MainActor public protocol PhoneHapticOutput: AnyObject {
    func prepare(onInterruption: @escaping @MainActor () -> Void) throws
    func startBurst(intensity: Double, duration: TimeInterval) throws
    func changeIntensity(_ intensity: Double) throws
    func silence()
    func shutdown()
}

/// One foreground output stream shared by direction guidance and short arrival/test cues.
@MainActor public final class PhoneHapticPlayback {
    public private(set) var errorMessage: String?
    private let output: any PhoneHapticOutput
    private var ready = false
    private var burstStarted: TimeInterval?
    private var retryAfter: TimeInterval = 0
    private var generation = UUID()
    public static let burstDuration: TimeInterval = 0.35

    public init(output: any PhoneHapticOutput) { self.output = output }

    public func prepare(now: TimeInterval) {
        silence()
        if !ready { _ = ensureReady(now: now) }
    }

    public func update(intensity: Double, isActive: Bool, now: TimeInterval) {
        guard isActive, intensity.isFinite, intensity > 0.005, now.isFinite else { silence(); return }
        guard ensureReady(now: now) else { return }
        let value = min(0.8, intensity)
        do {
            if burstStarted.map({ now < $0 || now - $0 >= Self.burstDuration }) ?? true {
                output.silence()
                try output.startBurst(intensity: value, duration: Self.burstDuration)
                burstStarted = now
            } else {
                try output.changeIntensity(value)
            }
            errorMessage = nil
        } catch { failed(now: now) }
    }

    public func silence() {
        if burstStarted != nil { output.silence() }
        burstStarted = nil
    }

    public func shutdown() {
        generation = UUID()
        output.shutdown()
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
            try output.prepare { [weak self] in
                guard let self, generation == request else { return }
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
        ready = false
        burstStarted = nil
        retryAfter = now + 1
        errorMessage = "Vibration interrupted · Retrying"
    }
}
