import Foundation

/// Why something needs the process's one audio session. Several uses can be held at once.
public enum AudioSessionUse: Hashable, Sendable, CaseIterable {
    /// A spoken prompt is playing; other audio ducks while it speaks.
    case speaking
    /// The microphone is capturing a destination.
    case recording
    /// A haptic engine is running. It plays no audio, but it does not survive the session
    /// being deactivated underneath it.
    case haptics
}

/// The session state a set of uses requires.
public enum AudioSessionPlan: Equatable, Sendable {
    /// Nothing holds the session; it is released so other apps recover the output.
    case inactive
    /// The microphone is live. Haptics may be suppressed by the system while it is.
    case recording
    /// A prompt is speaking: other audio ducks.
    case speaking
    /// Active but silent and mixable, so a running haptic engine never sees a teardown.
    case silentHold
}

/// Which plan a set of held uses adds up to. Pure, so the ordering rules are testable
/// without a device.
public struct AudioSessionPolicy: Equatable, Sendable {
    private var counts: [AudioSessionUse: Int] = [:]

    public init() {}

    /// Recording outranks speaking because the microphone cannot share the session with
    /// playback here; speaking outranks a haptics-only hold because it needs to duck.
    public var plan: AudioSessionPlan {
        if holds(.recording) { return .recording }
        if holds(.speaking) { return .speaking }
        if holds(.haptics) { return .silentHold }
        return .inactive
    }

    public func holds(_ use: AudioSessionUse) -> Bool { (counts[use] ?? 0) > 0 }

    @discardableResult public mutating func acquire(_ use: AudioSessionUse) -> AudioSessionPlan {
        counts[use, default: 0] += 1
        return plan
    }

    @discardableResult public mutating func release(_ use: AudioSessionUse) -> AudioSessionPlan {
        // An unbalanced release must not make a still-held use look free.
        counts[use] = max(0, (counts[use] ?? 0) - 1)
        return plan
    }
}

#if os(iOS)
import AVFoundation

/// The single owner of `AVAudioSession.sharedInstance()`.
///
/// Speech used to activate the session for each prompt and deactivate it on the last word,
/// and the recorder did the same around each recording. A running `CHHapticEngine` does not
/// survive that teardown: the engine stops, the worker rebuilds it, and the directional cue
/// around the prompt is dropped — which is why guidance only stuttered when Point spoke.
///
/// Holding the session for as long as the haptic engine runs removes the teardown. Other
/// apps still come back up the instant a prompt ends, because what ducks them is the
/// `.duckOthers` option, not the activation; dropping the option un-ducks immediately.
public final class AudioSessionCoordinator: @unchecked Sendable {
    public static let shared = AudioSessionCoordinator()

    /// Serialises transitions: haptics call in from their own queue, speech and the
    /// recorder from the main actor.
    private let queue = DispatchQueue(label: "com.point.audio-session")
    /// A release is followed almost immediately by a fresh hold whenever the engine
    /// rebuilds or one prompt follows another. Deactivating after a short grace keeps that
    /// round trip off the media server; the un-ducking part of it is applied at once.
    private static let releaseGrace: TimeInterval = 0.3
    private var policy = AudioSessionPolicy()
    private var applied: AudioSessionPlan?
    private var pendingRelease = 0

    private init() {}

    /// The plan the session is currently configured for. Diagnostics only.
    public var currentPlan: AudioSessionPlan { queue.sync { applied ?? .inactive } }

    /// Hold the session for `use`. Balance every successful call with `release`.
    public func acquire(_ use: AudioSessionUse) throws {
        try queue.sync {
            let plan = policy.acquire(use)
            do { try apply(plan) } catch {
                // Never leave a hold behind for a session we failed to configure.
                _ = policy.release(use)
                try? apply(policy.plan)
                throw error
            }
        }
    }

    public func release(_ use: AudioSessionUse) {
        queue.sync { try? apply(policy.release(use)) }
    }

    private func apply(_ plan: AudioSessionPlan) throws {
        // Any transition supersedes a deactivation that has not run yet.
        pendingRelease += 1
        if plan != applied {
            let session = AVAudioSession.sharedInstance()
            switch plan {
            case .recording:
                try session.setCategory(.record, mode: .measurement)
            case .speaking:
                try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
            case .inactive, .silentHold:
                // Same category and mode as a prompt, so only the ducking option changes. A
                // full category swap is more churn than a running engine needs to see, and
                // dropping `.duckOthers` is already what lets other apps come back up.
                try session.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers])
            }
            if plan != .inactive { try session.setActive(true) }
            applied = plan
        }
        guard plan == .inactive else { return }
        let request = pendingRelease
        queue.asyncAfter(deadline: .now() + Self.releaseGrace) { [weak self] in
            guard let self, request == pendingRelease, policy.plan == .inactive else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
#endif
