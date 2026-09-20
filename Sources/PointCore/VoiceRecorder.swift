#if os(iOS)
import AVFoundation
import Combine
import Foundation
import Speech

/// Foreground voice turns. The same echo-cancelling engine carries replies and microphone input.
/// Capture starts only in an explicit conversation and ends on silence, cancellation, or backgrounding.
@MainActor public final class VoiceRecorder: ObservableObject {
    public struct Recording {
        public let audio: Data
        /// Best Apple Speech transcript; empty when speech recognition is unavailable or denied.
        public let transcript: String
    }

    @Published public private(set) var isRecording = false
    /// Updated word by word while recording.
    @Published public private(set) var liveTranscript = ""
    @Published public private(set) var endpoint: SpeechEndpoint = .listening

    public let audioEngine = AVAudioEngine()
    public private(set) var supportsInterruption = false
    public var onInterruption: (() -> Void)?
    private var assistantText: String?
    private var interruptionDetector = SpeechInterruptionDetector()
    private var ignoredTranscript = ""
    private var lastRawTranscript = ""
    private var cuePlayer: AVAudioPlayerNode?
    private var engine: AVAudioEngine { audioEngine }
    private var tapInstalled = false
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalTranscript: String?
    private var recordingID = UUID()
    private var endpointDetector = SpeechEndpointDetector(startedAt: 0)
    private var endpointMonitor: Task<Void, Never>?
    public init() {}

    /// Ask for microphone and speech recognition up front so the prompts appear during onboarding.
    public static func requestPermissions() async -> Bool {
        let microphone = await AVAudioApplication.requestRecordPermission()
        let speech = await speechAuthorization()
        return microphone && speech == .authorized
    }

    private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    public func start(whileReplyingTo reply: String? = nil) async throws {
        cancel()
        let requestID = UUID()
        recordingID = requestID
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard recordingID == requestID, !Task.isCancelled else { throw CancellationError() }
        guard allowed else { throw RecorderError.permissionDenied }
        let speechStatus = await Self.speechAuthorization()
        guard recordingID == requestID, !Task.isCancelled else { throw CancellationError() }

        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try audio.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try audio.setActive(true)
        let input = engine.inputNode
        do { try input.setVoiceProcessingEnabled(true); supportsInterruption = true }
        catch { supportsInterruption = false }
        assistantText = reply
        interruptionDetector = SpeechInterruptionDetector()
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.couldNotRecord }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("point-\(UUID().uuidString).m4a")
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            self.file = file
            fileURL = url

            // Live words come from Apple Speech; it is optional, so recording works without it.
            var speech: SFSpeechAudioBufferRecognitionRequest?
            if speechStatus == .authorized,
               let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(), recognizer.isAvailable {
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true
                request.taskHint = .dictation
                if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
                speech = request
                self.request = request
                task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in self?.receive(result, error: error, id: requestID) }
                }
            }
            if speech == nil { supportsInterruption = false }
            endpointDetector = SpeechEndpointDetector(startedAt: ProcessInfo.processInfo.systemUptime, pauseDuration: 1.6)
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                try? file.write(from: buffer)
                speech?.append(buffer)
                let level = Self.levelDB(buffer)
                let time = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in
                    guard let self, self.recordingID == requestID, self.isRecording else { return }
                    self.interruptionDetector.observeAudio(levelDB: level, at: time)
                    if self.assistantText == nil { self.endpointDetector.observeAudio(levelDB: level, at: time) }
                }
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            isRecording = true
            endpointMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self, self.recordingID == requestID, self.isRecording else { return }
                    guard self.assistantText == nil else { continue }
                    let result = self.endpointDetector.endpoint(at: ProcessInfo.processInfo.systemUptime)
                    if result != .listening { self.endpoint = result; return }
                }
            }
        } catch { cancel(); throw error }
    }

    private func receive(_ result: SFSpeechRecognitionResult?, error: Error?, id: UUID) {
        guard recordingID == id else { return }
        if let result {
            let raw = result.bestTranscription.formattedString
            lastRawTranscript = raw
            var text = raw
            if !ignoredTranscript.isEmpty, raw.hasPrefix(ignoredTranscript) {
                text = String(raw.dropFirst(ignoredTranscript.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let assistantText {
                guard supportsInterruption,
                      interruptionDetector.shouldInterrupt(transcript: text, assistantText: assistantText,
                                                           at: ProcessInfo.processInfo.systemUptime) else {
                    if !raw.isEmpty, assistantText.localizedCaseInsensitiveContains(raw) { ignoredTranscript = raw }
                    return
                }
                self.assistantText = nil
                endpointDetector = SpeechEndpointDetector(startedAt: ProcessInfo.processInfo.systemUptime, pauseDuration: 1.6)
                onInterruption?() // Keep capture and the recognizer alive: don't lose the first words.
            }
            if !text.isEmpty, text != liveTranscript {
                liveTranscript = text
                endpointDetector.observeTranscript(at: ProcessInfo.processInfo.systemUptime)
            }
            if result.isFinal { finalTranscript = text }
        }
        // Ending audio can surface an error instead of a final result; keep the last partial.
        if error != nil, finalTranscript == nil { finalTranscript = liveTranscript }
    }

    /// Natural completion hands back to the already-open microphone, without a guessed timer.
    public func assistantFinished() {
        guard isRecording, let spoken = assistantText else { return }
        assistantText = nil
        let possibleReply = lastRawTranscript.hasPrefix(ignoredTranscript)
            ? String(lastRawTranscript.dropFirst(ignoredTranscript.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            : lastRawTranscript
        let userAlreadyStarted = !possibleReply.isEmpty && !spoken.localizedCaseInsensitiveContains(possibleReply)
        if !userAlreadyStarted { ignoredTranscript = lastRawTranscript }
        liveTranscript = userAlreadyStarted ? possibleReply : ""
        finalTranscript = nil
        endpointDetector = SpeechEndpointDetector(startedAt: ProcessInfo.processInfo.systemUptime, pauseDuration: 1.6)
        if userAlreadyStarted { endpointDetector.observeTranscript(at: ProcessInfo.processInfo.systemUptime) }
        else { playListeningCue() }
    }

    public func playListeningCue() {
        guard engine.isRunning else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3840),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = 3840
        for i in 0..<3840 {
            let envelope = sin(Double.pi * Double(i) / 3840)
            samples[i] = Float(sin(2 * Double.pi * 880 * Double(i) / 48000) * envelope * 0.12)
        }
        // Keep this source attached across turns. Removing the last live source
        // can invalidate the voice-processing graph and raises an Obj-C exception.
        let node: AVAudioPlayerNode
        if let cuePlayer { node = cuePlayer; node.stop() }
        else {
            node = AVAudioPlayerNode()
            cuePlayer = node
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        node.scheduleBuffer(buffer)
        node.play()
    }

    public func finish() async throws -> Recording {
        guard isRecording, let fileURL else { throw RecorderError.couldNotRecord }
        let id = recordingID
        endpointMonitor?.cancel()
        endpointMonitor = nil
        stopCapture()
        isRecording = false
        request?.endAudio()
        // Give the recognizer a moment for its final result; the last partial is the fallback.
        var waited = 0
        // A partial transcript is already usable; do not add 1.5s of latency after endpointing.
        let finalWait = liveTranscript.isEmpty ? 10 : 3
        while finalTranscript == nil, request != nil, waited < finalWait {
            try? await Task.sleep(for: .milliseconds(100))
            guard recordingID == id else { throw CancellationError() }
            waited += 1
        }
        let transcript = (finalTranscript ?? liveTranscript).trimmingCharacters(in: .whitespacesAndNewlines)
        defer { cancel() }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty, data.count <= 24_000_000 else { throw ServiceError.invalidAudio }
        return Recording(audio: data, transcript: transcript)
    }

    public func cancel() {
        recordingID = UUID()
        assistantText = nil
        ignoredTranscript = ""
        lastRawTranscript = ""
        endpointMonitor?.cancel()
        endpointMonitor = nil
        stopCapture()
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        finalTranscript = nil
        liveTranscript = ""
        endpoint = .listening
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func stopCapture() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        cuePlayer?.stop()
        if engine.isRunning { engine.stop() }
        // Releasing the file finalizes the M4A container so it can be read back.
        file = nil
    }

    nonisolated private static func levelDB(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -80 }
        var energy = 0.0
        var count = 0
        for index in stride(from: 0, to: Int(buffer.frameLength), by: 4) {
            let sample = Double(samples[index])
            energy += sample * sample
            count += 1
        }
        return 10 * log10(max(energy / Double(max(1, count)), 1e-8))
    }
}

public enum RecorderError: LocalizedError {
    case permissionDenied, couldNotRecord
    public var errorDescription: String? {
        self == .permissionDenied ? "Allow microphone access in Settings, or type a destination."
            : "Could not record audio. Please try again."
    }
}
#endif
