import AVFoundation
import CoreHaptics
import UIKit

/// Real iPhone output, separate from the future glove's pulse protocol.
@MainActor final class PhoneHapticPlayer {
    let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private(set) var errorMessage: String?
    private var engine: CHHapticEngine?
    private var player: (any CHHapticPatternPlayer)?
    private var pulseStarted: Date?
    private var generation = UUID()
    private var needsRestart = false
    private var lastRestartAttempt: Date?

    func prepare() {
        shutdown()
        errorMessage = nil
        guard supported else { errorMessage = "Phone vibration needs a compatible iPhone."; return }
        do {
            let engine = try CHHapticEngine()
            // Recording leaves the shared session in .record even after stopping capture.
            // Return it to a haptic-compatible category without disturbing an active voice prompt.
            let audio = AVAudioSession.sharedInstance()
            if audio.category == .record {
                try audio.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            }
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = false
            let request = generation
            engine.stoppedHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, generation == request else { return }
                    player = nil
                    pulseStarted = nil
                    needsRestart = true
                }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, generation == request else { return }
                    player = nil
                    pulseStarted = nil
                    needsRestart = true
                }
            }
            try engine.start()
            self.engine = engine
            needsRestart = false
        } catch { errorMessage = "Vibration unavailable. Pause, then resume to retry." }
    }

    func update(intensity: Double, now: Date) {
        guard let engine, UIApplication.shared.applicationState == .active,
              intensity.isFinite, intensity > 0.005 else { silence(); return }
        let value = Float(min(0.8, max(0, intensity)))
        do {
            if needsRestart {
                guard lastRestartAttempt.map({ now.timeIntervalSince($0) >= 1 }) ?? true else { return }
                lastRestartAttempt = now
                try engine.start()
                needsRestart = false
                errorMessage = nil
            }
            // Finite 350 ms bursts cannot latch if the app's foreground loop stalls.
            // Dynamic intensity changes within each burst follow the 20 Hz lerp.
            if player == nil || pulseStarted.map({ now.timeIntervalSince($0) >= 0.35 }) == true {
                silence()
                let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    .init(parameterID: .hapticIntensity, value: 1),
                    .init(parameterID: .hapticSharpness, value: 0.15),
                    .init(parameterID: .attackTime, value: 0.025),
                    .init(parameterID: .releaseTime, value: 0.025)
                ], relativeTime: 0, duration: 0.35)
                let pattern = try CHHapticPattern(events: [event], parameters: [
                    .init(parameterID: .hapticIntensityControl, value: value, relativeTime: 0)
                ])
                player = try engine.makePlayer(with: pattern)
                try player?.start(atTime: CHHapticTimeImmediate)
                pulseStarted = now
            } else {
                try player?.sendParameters([
                    .init(parameterID: .hapticIntensityControl, value: value, relativeTime: 0)
                ], atTime: CHHapticTimeImmediate)
            }
        } catch {
            silence()
            needsRestart = true
            errorMessage = "Vibration interrupted · Retrying"
        }
    }

    func silence() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        pulseStarted = nil
    }

    func shutdown() {
        generation = UUID()
        silence()
        engine?.stop(completionHandler: nil)
        engine = nil
        needsRestart = false
        lastRestartAttempt = nil
    }
}
