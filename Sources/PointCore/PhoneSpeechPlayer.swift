#if os(iOS)
import AVFoundation
import Foundation

@MainActor public final class PhoneSpeechPlayer: NSObject, SpeechPlaying, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    /// Set only while a foreground conversation owns the microphone audio session.
    public weak var conversationEngine: AVAudioEngine?
    private var enginePlayer: AVAudioPlayerNode?
    private var outputGeneration = UUID()
    private var renderedFile: AVAudioFile?
    private var renderedURL: URL?
    private var renderingSystemVoice = false
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
        if let engine = conversationEngine, engine.isRunning {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("point-reply-\(UUID().uuidString).audio")
            try audio.data.write(to: url)
            renderedURL = url
            let file = try AVAudioFile(forReading: url)
            try playOnEngine(file, engine: engine, text: audio.text, audio: audio, progress: progress, completion: completion)
            return
        }
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
        if conversationEngine?.isRunning != true {
            do { try activateSession() } catch { progress(text); completion(false); return }
        }
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
        if conversationEngine?.isRunning == true {
            renderingSystemVoice = true
            let generation = outputGeneration
            systemVoice.write(utterance) { [weak self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                Task { @MainActor in
                    guard let self, self.outputGeneration == generation else { return }
                    do {
                        if pcm.frameLength > 0 {
                            if self.renderedFile == nil {
                                let url = FileManager.default.temporaryDirectory.appendingPathComponent("point-system-\(UUID().uuidString).caf")
                                self.renderedURL = url
                                self.renderedFile = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                                                   commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                            }
                            try self.renderedFile?.write(from: pcm)
                        } else {
                            self.renderedFile = nil
                            guard let url = self.renderedURL, let engine = self.conversationEngine, engine.isRunning else {
                                self.finishPlayback(successfully: false); return
                            }
                            let file = try AVAudioFile(forReading: url)
                            try self.playOnEngine(file, engine: engine, text: text, audio: nil, progress: progress, completion: completion)
                        }
                    } catch { self.finishPlayback(successfully: false) }
                }
            }
        } else { systemVoice.speak(utterance) }
    }

    private func playOnEngine(_ file: AVAudioFile, engine: AVAudioEngine, text: String, audio: SpeechAudio?,
                              progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) throws {
        guard file.length > 0 else { throw ServiceError.invalidAudio }
        let player: AVAudioPlayerNode
        if let existing = enginePlayer, existing.engine === engine { player = existing }
        else {
            player = AVAudioPlayerNode()
            engine.attach(player)
        }
        enginePlayer = player
        self.progress = progress
        self.completion = completion
        fullText = text
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        let generation = outputGeneration
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.outputGeneration == generation else { return }
                self.finishPlayback(successfully: true)
            }
        }
        player.play()
        if let audio {
            captionTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.outputGeneration == generation else { return }
                    if let time = player.lastRenderTime, let position = player.playerTime(forNodeTime: time) {
                        progress(audio.visibleText(at: Double(position.sampleTime) / position.sampleRate))
                    }
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        } else { progress(text) }
    }

    public func stop() {
        outputGeneration = UUID()
        // Stopping playback must not remove a source from the live recording graph.
        // Reuse the node on the next reply; the engine releases it at teardown.
        enginePlayer?.stop()
        renderedFile = nil
        if let renderedURL { try? FileManager.default.removeItem(at: renderedURL) }
        renderedURL = nil
        renderingSystemVoice = false
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
            guard self.currentUtterance === utterance, !self.renderingSystemVoice else { return }
            self.finishPlayback(successfully: true)
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.currentUtterance === utterance, !self.renderingSystemVoice else { return }
            self.finishPlayback(successfully: false)
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                              utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.currentUtterance === utterance, !self.renderingSystemVoice else { return }
            let text = utterance.speechString as NSString
            self.progress?(text.substring(to: min(text.length, NSMaxRange(characterRange))))
        }
    }
}
#endif
