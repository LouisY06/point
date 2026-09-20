import Foundation

public enum SpeechEndpoint: Equatable { case listening, finished, noSpeech }

/// Wait for observed quiet audio, not a gap in recognition callbacks.
/// Times use a monotonic clock. The recorder owns the separate hard duration limit.
public struct SpeechEndpointDetector {
    private let startedAt: TimeInterval
    private let pauseDuration: TimeInterval
    private var lastWord: TimeInterval?
    private var lastVoice: TimeInterval?
    private var lastSample: TimeInterval?
    private var quietSince: TimeInterval?
    private var voiceRunStarted: TimeInterval?
    private var heardSustainedAudio = false
    private var noiseFloor = -65.0

    public init(startedAt: TimeInterval, pauseDuration: TimeInterval = 3) {
        self.startedAt = startedAt
        self.pauseDuration = max(1.2, pauseDuration)
    }

    public mutating func observeTranscript(at time: TimeInterval) {
        lastWord = time
        // Delayed recognition must also get a full thinking pause.
        if quietSince != nil { quietSince = time }
    }

    public mutating func observeAudio(levelDB: Double, at time: TimeInterval) {
        guard levelDB.isFinite, time.isFinite, time >= startedAt,
              lastSample.map({ time >= $0 }) ?? true else { return }
        if lastSample.map({ time - $0 > 0.5 }) ?? false { quietSince = nil; voiceRunStarted = nil }
        lastSample = time
        let threshold = min(-30, max(-55, noiseFloor + 9))
        if levelDB > threshold {
            quietSince = nil
            if let previous = lastVoice, time - previous > 0.18 { voiceRunStarted = nil }
            if voiceRunStarted == nil { voiceRunStarted = time }
            lastVoice = time
            if time - (voiceRunStarted ?? time) >= 0.25 { heardSustainedAudio = true }
        } else {
            voiceRunStarted = nil
            if quietSince == nil { quietSince = time }
            noiseFloor += (max(-80, levelDB) - noiseFloor) * 0.08
        }
    }

    public func endpoint(at time: TimeInterval) -> SpeechEndpoint {
        guard let lastSample, (0...0.5).contains(time - lastSample),
              let quietSince else { return .listening }
        let quietDuration = time - quietSince
        if let lastWord {
            // Slow speech is allowed: both sound and new words restart this 3-second window.
            if quietDuration >= pauseDuration, time - lastWord >= pauseDuration { return .finished }
        } else if heardSustainedAudio {
            // Allow extra time for the first recognition result; batch transcription is a fallback.
            if quietDuration >= 4 { return .finished }
        } else if time - startedAt >= 12, quietDuration >= 3 {
            return .noSpeech
        }
        return .listening
    }
}
