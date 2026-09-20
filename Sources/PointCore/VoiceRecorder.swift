#if os(iOS)
import AVFoundation
import Combine
import Foundation
import Speech

/// Explicit destination recordings with a live on-device transcript. The view owns start/finish/cancel;
/// there is no always-on microphone. Audio is also written to a temporary M4A for batch transcription.
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

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var holdsSession = false
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

    public func start() async throws {
        cancel()
        let requestID = UUID()
        recordingID = requestID
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard recordingID == requestID, !Task.isCancelled else { throw CancellationError() }
        guard allowed else { throw RecorderError.permissionDenied }
        let speechStatus = await Self.speechAuthorization()
        guard recordingID == requestID, !Task.isCancelled else { throw CancellationError() }

        try AudioSessionCoordinator.shared.acquire(.recording)
        holdsSession = true
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Release the session hold taken above; this exit does not run the block below.
        guard format.sampleRate > 0, format.channelCount > 0 else { cancel(); throw RecorderError.couldNotRecord }
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
                request.taskHint = .search
                speech = request
                self.request = request
                task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in self?.receive(result, error: error, id: requestID) }
                }
            }
            endpointDetector = SpeechEndpointDetector(startedAt: ProcessInfo.processInfo.systemUptime)
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                try? file.write(from: buffer)
                speech?.append(buffer)
                let level = Self.levelDB(buffer)
                let time = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in
                    guard let self, self.recordingID == requestID, self.isRecording else { return }
                    self.endpointDetector.observeAudio(levelDB: level, at: time)
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
                    let result = self.endpointDetector.endpoint(at: ProcessInfo.processInfo.systemUptime)
                    if result != .listening { self.endpoint = result; return }
                }
            }
        } catch { cancel(); throw error }
    }

    private func receive(_ result: SFSpeechRecognitionResult?, error: Error?, id: UUID) {
        guard recordingID == id else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            if !text.isEmpty, text != liveTranscript {
                liveTranscript = text
                endpointDetector.observeTranscript(at: ProcessInfo.processInfo.systemUptime)
            }
            if result.isFinal { finalTranscript = text }
        }
        // Ending audio can surface an error instead of a final result; keep the last partial.
        if error != nil, finalTranscript == nil { finalTranscript = liveTranscript }
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
        if holdsSession {
            holdsSession = false
            AudioSessionCoordinator.shared.release(.recording)
        }
    }

    private func stopCapture() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
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
