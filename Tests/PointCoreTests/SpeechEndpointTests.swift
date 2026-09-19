import Testing
@testable import PointCore

struct SpeechEndpointTests {
    private func quiet(_ detector: inout SpeechEndpointDetector, from start: Double, through end: Double) {
        for tick in 0...Int(((end - start) * 10).rounded()) {
            detector.observeAudio(levelDB: -70, at: min(end, start + Double(tick) / 10))
        }
    }

    @Test func waitsForThreeSecondsOfActualSilence() {
        var detector = SpeechEndpointDetector(startedAt: 0)
        detector.observeTranscript(at: 1)
        quiet(&detector, from: 1, through: 3.9)
        #expect(detector.endpoint(at: 3.9) == .listening)
        quiet(&detector, from: 4, through: 4.1)
        #expect(detector.endpoint(at: 4.1) == .finished)
    }

    @Test func slowWordsAndRecognitionDelaysDoNotCutOffSpeech() {
        var detector = SpeechEndpointDetector(startedAt: 0)
        detector.observeTranscript(at: 1)
        quiet(&detector, from: 1, through: 3)
        #expect(detector.endpoint(at: 3) == .listening)
        for tick in 31...70 { detector.observeAudio(levelDB: -40, at: Double(tick) / 10) }
        // No text callback for six seconds, but speech is still audible.
        #expect(detector.endpoint(at: 7) == .listening)
        detector.observeTranscript(at: 7.1)
        quiet(&detector, from: 7.1, through: 10.2)
        #expect(detector.endpoint(at: 10.2) == .finished)
    }

    @Test func ongoingAudioNeverProducesNoDestinationOrForcedEndpoint() {
        var detector = SpeechEndpointDetector(startedAt: 0)
        for tick in 0...200 { detector.observeAudio(levelDB: -40, at: Double(tick) / 10) }
        #expect(detector.endpoint(at: 20) == .listening)
        quiet(&detector, from: 20.1, through: 24.2)
        #expect(detector.endpoint(at: 24.2) == .finished)
    }

    @Test func noSpeechRequiresTwelveSecondsAndFreshQuietAudio() {
        var detector = SpeechEndpointDetector(startedAt: 0)
        #expect(detector.endpoint(at: 20) == .listening) // Missing samples are not silence.
        quiet(&detector, from: 0, through: 11.9)
        #expect(detector.endpoint(at: 11.9) == .listening)
        detector.observeAudio(levelDB: -70, at: 12)
        #expect(detector.endpoint(at: 12) == .noSpeech)
    }

    @Test func lateStartAndAudioGapsRestartQuietWindow() {
        var detector = SpeechEndpointDetector(startedAt: 0)
        quiet(&detector, from: 0, through: 11.8)
        detector.observeAudio(levelDB: -40, at: 11.9)
        #expect(detector.endpoint(at: 12) == .listening)
        detector.observeTranscript(at: 12)
        quiet(&detector, from: 12, through: 13)
        #expect(detector.endpoint(at: 16) == .listening)
        quiet(&detector, from: 16, through: 18.9)
        #expect(detector.endpoint(at: 18.9) == .listening)
        detector.observeAudio(levelDB: -70, at: 19.1)
        #expect(detector.endpoint(at: 19.1) == .finished)
    }
}
