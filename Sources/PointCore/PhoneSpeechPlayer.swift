#if os(iOS)
import AVFoundation
import Foundation

@MainActor public final class PhoneSpeechPlayer: NSObject, SpeechPlaying, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    private var audioPlayer: AVAudioPlayer?
    private let systemVoice = AVSpeechSynthesizer()
    private var ownsSession = false
    private var currentUtterance: AVSpeechUtterance?
    private var interruption: NSObjectProtocol?
    private var captionTask: Task<Void, Never>?
    private var progress: ((String) -> Void)?
    private var completion: ((Bool) -> Void)?
    private var fullText = ""

    public override init() {
        super.init()
        systemVoice.delegate = self
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    deinit { if let interruption { NotificationCenter.default.removeObserver(interruption) } }

    public func play(_ audio: SpeechAudio, progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) throws {
        stop()
        let player = try AVAudioPlayer(data: audio.data)
        player.delegate = self
        try activateSession()
        audioPlayer = player
        self.progress = progress
        self.completion = completion
        fullText = audio.text
        guard player.play() else { stop(); throw ServiceError.invalidResponse }
        captionTask = Task { [weak self] in
            var previous = ""
            while !Task.isCancelled {
                guard let self, self.audioPlayer === player else { return }
                let visible = audio.visibleText(at: player.currentTime)
                if visible != previous { progress(visible); previous = visible }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    public func speakSystem(_ text: String, progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        stop()
        do { try activateSession() } catch { progress(text); completion(false); return }
        self.progress = progress
        self.completion = completion
        fullText = text
        let utterance = AVSpeechUtterance(string: text)
        let voices = AVSpeechSynthesisVoice.speechVoices()
        utterance.voice = voices.first { $0.language == "en-US" && $0.gender == .male }
            ?? voices.first { $0.language.hasPrefix("en") && $0.gender == .male }
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        currentUtterance = utterance
        systemVoice.speak(utterance)
    }

    public func stop() {
        captionTask?.cancel()
        captionTask = nil
        progress = nil
        completion = nil
        audioPlayer?.stop()
        audioPlayer = nil
        currentUtterance = nil
        systemVoice.stopSpeaking(at: .immediate)
        deactivateSession()
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try session.setActive(true)
        ownsSession = true
    }

    private func deactivateSession() {
        guard ownsSession else { return }
        ownsSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.audioPlayer === player else { return }
            self.finishPlayback(successfully: flag)
        }
    }

    nonisolated public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard self.audioPlayer === player else { return }
            self.finishPlayback(successfully: false)
        }
    }

    private func finishPlayback(successfully succeeded: Bool) {
        let finished = completion
        progress?(fullText)
        // Release the output audio session before a completion callback starts microphone input.
        stop()
        finished?(succeeded)
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.currentUtterance === utterance else { return }
            self.finishPlayback(successfully: true)
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.currentUtterance === utterance else { return }
            self.finishPlayback(successfully: false)
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                              utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.currentUtterance === utterance else { return }
            let text = utterance.speechString as NSString
            self.progress?(text.substring(to: min(text.length, NSMaxRange(characterRange))))
        }
    }
}
#endif
