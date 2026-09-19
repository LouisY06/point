#if os(iOS)
import AVFoundation
import Combine
import Foundation

/// Short, explicit recordings. The view owns start/finish/cancel; there is no always-on microphone.
@MainActor public final class VoiceRecorder: ObservableObject {
    @Published public private(set) var isRecording = false
    private var recorder: AVAudioRecorder?
    private var file: URL?
    private var recordingID = UUID()
    public init() {}

    public func start() async throws {
        cancel()
        let requestID = UUID()
        recordingID = requestID
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard recordingID == requestID, !Task.isCancelled else { throw CancellationError() }
        guard allowed else { throw RecorderError.permissionDenied }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .default)
        try audio.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("point-\(UUID().uuidString).m4a")
        file = url
        do {
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000,
                AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            guard recorder.record() else { throw RecorderError.couldNotRecord }
            self.recorder = recorder
            isRecording = true
        } catch { cancel(); throw error }
    }

    public func finish() throws -> Data {
        guard isRecording, let file else { throw RecorderError.couldNotRecord }
        recorder?.stop()
        defer { cancel() }
        let data = try Data(contentsOf: file)
        guard !data.isEmpty, data.count <= 24_000_000 else { throw ServiceError.invalidAudio }
        return data
    }

    public func cancel() {
        recordingID = UUID()
        recorder?.stop()
        recorder = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
