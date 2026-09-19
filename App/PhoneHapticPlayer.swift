import AVFoundation
import CoreHaptics
import PointCore
import OSLog
import UIKit

/// Real iPhone output, separate from the future glove's pulse protocol.
@MainActor final class PhoneHapticPlayer {
    let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private let playback = PhoneHapticPlayback(output: CoreHapticOutput())
    var errorMessage: String? {
        supported ? playback.errorMessage : "Phone vibration needs a compatible iPhone."
    }

    func prepare() {
        guard supported else { return }
        playback.prepare(now: ProcessInfo.processInfo.systemUptime)
    }

    func update(intensity: Double, now: Date) {
        guard supported else { return }
        playback.update(intensity: intensity, isActive: UIApplication.shared.applicationState == .active,
                        now: ProcessInfo.processInfo.systemUptime)
    }

    func silence() { playback.silence() }
    func shutdown() { playback.shutdown() }
}

/// Keeps one finite pattern player for the lifetime of an engine, including across cues.
@MainActor private final class CoreHapticOutput: PhoneHapticOutput {
    private var engine: CHHapticEngine?
    private var player: (any CHHapticPatternPlayer)?
    private var generation = UUID()
    private let log = Logger(subsystem: "com.point.navigator", category: "PhoneHaptics")

    func prepare(onInterruption: @escaping @MainActor () -> Void) throws {
        do {
            let audio = AVAudioSession.sharedInstance()
            if audio.category == .record {
                try audio.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            }
            if engine == nil {
                let engine = try CHHapticEngine()
                engine.playsHapticsOnly = true
                engine.isAutoShutdownEnabled = false
                self.engine = engine
            }
            let request = generation
            engine?.stoppedHandler = { [weak self] reason in
                Task { @MainActor [weak self] in
                    guard let self, generation == request else { return }
                    log.notice("Engine stopped: \(reason.rawValue)")
                    player = nil
                    onInterruption()
                }
            }
            engine?.resetHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, generation == request else { return }
                    log.notice("Engine reset")
                    player = nil
                    onInterruption()
                }
            }
            try engine?.start()
        } catch {
            log.error("Engine start failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func startBurst(intensity: Double, duration: TimeInterval) throws {
        guard let engine else { throw PlaybackError.missingEngine }
        // start() is a no-op for a running engine. Reassert playback after an audio-session
        // transition even if its asynchronous stopped notification has not arrived yet.
        try engine.start()
        if player == nil {
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                .init(parameterID: .hapticIntensity, value: 0.8),
                .init(parameterID: .hapticSharpness, value: 0.15),
                .init(parameterID: .attackTime, value: 0.025),
                .init(parameterID: .releaseTime, value: 0.025)
            ], relativeTime: 0, duration: duration)
            player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
        }
        // Apply intensity on every restart; a completed finite event does not keep vibrating
        // merely because sendParameters succeeds. The event still expires if updates stall.
        try player?.start(atTime: CHHapticTimeImmediate)
        try changeIntensity(intensity)
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
        silence()
        player = nil
        engine?.stoppedHandler = { _ in }
        engine?.resetHandler = {}
        engine?.stop(completionHandler: nil)
        engine = nil
    }

    private enum PlaybackError: Error { case missingEngine, missingPlayer }
}
