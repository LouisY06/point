import AVFoundation
import CoreHaptics
import PointCore
import OSLog
import UIKit

/// Real iPhone output, separate from the future glove's pulse protocol.
@MainActor final class PhoneHapticPlayer {
    let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private let worker = PhoneHapticWorker { queue in CoreHapticOutput(queue: queue) }
    private var session = UUID()
    var submittedIntensity: Double { supported ? worker.snapshot.submittedIntensity : 0 }
    var errorMessage: String? {
        supported ? worker.snapshot.errorMessage : "Phone vibration needs a compatible iPhone."
    }

    func prepare() {
        guard supported else { return }
        worker.submit(.prepare, session: session)
    }

    func update(intensity: Double, now: Date) {
        guard supported else { return }
        worker.submit(UIApplication.shared.applicationState == .active ? .intensity(intensity) : .silence,
                      session: session)
    }

    func silence() { worker.submit(.silence, session: session) }
    func shutdown() {
        session = UUID()
        worker.submit(.shutdown, session: session)
    }

}

/// Keeps one finite pattern player for the lifetime of an engine, including across cues.
private final class CoreHapticOutput: PhoneHapticOutput, @unchecked Sendable {
    private let queue: DispatchQueue
    init(queue: DispatchQueue) { self.queue = queue }
    private var engine: CHHapticEngine?
    private var player: (any CHHapticAdvancedPatternPlayer)?
    private var generation = UUID()
    private var playerGeneration = UUID()
    private var onInterruption: ((PhoneHapticInterruption) -> Void)?
    private var diagnosticLines: [String] = []
    private var bursts = 0
    private var completions = 0
    private var lastDiagnosticTime: TimeInterval = 0
    private let log = Logger(subsystem: "com.point.navigator", category: "PhoneHaptics")

    func prepare(onInterruption: @escaping (PhoneHapticInterruption) -> Void) throws {
        self.onInterruption = onInterruption
        do {
            let audio = AVAudioSession.sharedInstance()
            if audio.category == .record {
                try audio.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            }
            if engine == nil {
                // Haptics use their own session, independent of spoken prompts' playback session.
                let engine = try CHHapticEngine(audioSession: nil)
                engine.playsHapticsOnly = true
                engine.isAutoShutdownEnabled = false
                self.engine = engine
            }
            let request = generation
            engine?.stoppedHandler = { [weak self] reason in
                self?.queue.async { [weak self] in
                    guard let self, generation == request else { return }
                    log.notice("Engine stopped: \(reason.rawValue)")
                    recordDiagnostic("engine stopped reason=\(reason.rawValue)")
                    playerGeneration = UUID()
                    player = nil
                    onInterruption(.engineStopped)
                }
            }
            engine?.resetHandler = { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self, generation == request else { return }
                    log.notice("Engine reset")
                    recordDiagnostic("engine reset")
                    playerGeneration = UUID()
                    player = nil
                    onInterruption(.engineStopped)
                }
            }
            try engine?.start()
            recordDiagnostic("engine started")
        } catch {
            log.error("Engine start failed: \(error.localizedDescription, privacy: .public)")
            recordDiagnostic("engine start failed \(error as NSError)")
            throw error
        }
    }

    func startBurst(intensity: Double, duration: TimeInterval) throws {
        guard let engine else { throw PlaybackError.missingEngine }
        // Engine startup belongs to prepare/recovery, never to the 20 Hz guidance loop.
        if player == nil {
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                .init(parameterID: .hapticIntensity, value: 0.8),
                .init(parameterID: .hapticSharpness, value: 0.15),
                .init(parameterID: .attackTime, value: 0.025),
                .init(parameterID: .releaseTime, value: 0.025)
            ], relativeTime: 0, duration: duration)
            let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
            let request = UUID()
            playerGeneration = request
            player.completionHandler = { [weak self] error in
                self?.queue.async { [weak self] in
                    guard let self, playerGeneration == request else { return }
                    completions += 1
                    if let error {
                        // start() returning successfully is not proof that playback succeeded.
                        // Core Haptics can deliver the actual failure asynchronously here.
                        log.error("Player completion failed: \(error.localizedDescription, privacy: .public)")
                        recordDiagnostic("async playback failure \(error as NSError)")
                        playerGeneration = UUID()
                        self.player = nil
                        self.onInterruption?(.playbackFailed)
                    }
                }
            }
            self.player = player
        }
        // Apply intensity on every restart; a completed finite event does not keep vibrating
        // merely because sendParameters succeeds. The event still expires if updates stall.
        try player?.start(atTime: CHHapticTimeImmediate)
        try changeIntensity(intensity)
        bursts += 1
        let time = ProcessInfo.processInfo.systemUptime
        if time - lastDiagnosticTime >= 5 {
            lastDiagnosticTime = time
            recordDiagnostic("burst accepted intensity=\(intensity) starts=\(bursts) completions=\(completions)")
        }
    }

    func changeIntensity(_ intensity: Double) throws {
        guard let player else { throw PlaybackError.missingPlayer }
        try player.sendParameters([
            .init(parameterID: .hapticIntensityControl, value: Float(intensity / 0.8), relativeTime: 0)
        ], atTime: CHHapticTimeImmediate)
    }

    func silence() { try? player?.stop(atTime: CHHapticTimeImmediate) }

    func shutdown() {
        generation = UUID()
        playerGeneration = UUID()
        onInterruption = nil
        silence()
        player = nil
        engine?.stoppedHandler = { _ in }
        engine?.resetHandler = {}
        engine?.stop(completionHandler: nil)
        engine = nil
    }

    /// Bounded hardware diagnostics for retrieval from a connected phone. No location,
    /// destination, microphone audio, credentials, or other conversation content is recorded.
    private func recordDiagnostic(_ event: String) {
        let audio = AVAudioSession.sharedInstance()
        let route = audio.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(event) engineMuted=\(engine?.isMutedForHaptics ?? false) playerMuted=\(player?.isMuted ?? false) audioCategory=\(audio.category.rawValue) audioMode=\(audio.mode.rawValue) audioRoute=\(route)"
        diagnosticLines.append(line)
        if diagnosticLines.count > 120 { diagnosticLines.removeFirst(diagnosticLines.count - 120) }
        let url = URL.documentsDirectory.appending(path: "haptics-diagnostics.log")
        try? diagnosticLines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private enum PlaybackError: Error { case missingEngine, missingPlayer }
}
