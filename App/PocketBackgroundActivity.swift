import ActivityKit
import AVFoundation
import UIKit
import PointCore

@MainActor final class PocketBackgroundActivity {
    private var activity: Activity<PocketActivityAttributes>?
    private var lastUpdate = -Double.infinity
    private var lastStatus: String?
    private var bridge: UIBackgroundTaskIdentifier = .invalid
    private(set) var failure: String?
    var running: Bool {
        guard let activity else { return false }
        switch activity.activityState {
        case .active, .stale: return true
        case .ended, .dismissed: return false
        @unknown default: return false
        }
    }

    func start(total: Int) {
        end()
        failure = nil
        guard #available(iOS 26.0, *) else {
            failure = "The locked-screen Bluetooth test requires iOS 26. Touch guard remains available."; return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            failure = "Enable Live Activities for Point in Settings for the lock-screen test."; return
        }
        do {
            let state = PocketActivityAttributes.ContentState(beacon: 1, total: total, steps: 0,
                                                              status: "Pocket your phone · Stay still", distance: nil)
            activity = try Activity.request(attributes: PocketActivityAttributes(sessionID: UUID()),
                                            content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(15)), pushType: nil)
        } catch { failure = "Live Activity could not start: \(error.localizedDescription)" }
    }

    func update(beacon: Int, total: Int, steps: Int, status: String, distance: Double?) {
        guard let activity else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastUpdate >= 2 || status != lastStatus else { return }
        lastUpdate = now; lastStatus = status
        let state = PocketActivityAttributes.ContentState(beacon: beacon, total: total, steps: steps,
                                                          status: status, distance: distance)
        Task { await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(10))) }
    }

    // Only a bounded hand-off window. Ongoing execution uses real Bluetooth
    // sensor exchanges; this does not claim an unlimited background assertion.
    func enteredBackground() {
        guard bridge == .invalid else { return }
        bridge = UIApplication.shared.beginBackgroundTask(withName: "Pocket sensor handoff") { [weak self] in
            MainActor.assumeIsolated { self?.endBridge() }
        }
    }
    func endBridge() {
        if bridge != .invalid { UIApplication.shared.endBackgroundTask(bridge); bridge = .invalid }
    }
    func end() {
        endBridge()
        guard let activity else { return }
        self.activity = nil
        lastUpdate = -.infinity; lastStatus = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}

/// Actual navigation announcements may play while locked. No silent audio is
/// used to keep the process alive.
@MainActor final class PocketRouteSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var ownsSession = false
    override init() { super.init(); synthesizer.delegate = self }
    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        if !ownsSession {
            do { try AudioSessionCoordinator.shared.acquire(.speaking); ownsSession = true }
            catch { return }
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, !self.synthesizer.isSpeaking else { return }
            self.releaseSession()
        }
    }
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        releaseSession()
    }
    private func releaseSession() {
        guard ownsSession else { return }
        ownsSession = false
        AudioSessionCoordinator.shared.release(.speaking)
    }
}
