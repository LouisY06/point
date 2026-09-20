import Foundation
import CoreLocation
import Testing
@testable import PointCore

struct VoiceConfigurationTests {
    @Test func spokenConfirmationStopsBeforeCity() {
        let place = PlaceCandidate(id: "one", name: "Shake Shack",
                                   address: "88 Cambridge Street, Boston, MA 02114, United States",
                                   coordinate: CLLocationCoordinate2D(latitude: 42.36, longitude: -71.06),
                                   streetAddress: "88 Cambridge Street")
        let reply = NavigationSpeech.routeReady(for: place)
        #expect(reply.contains("on 88 Cambridge Street"))
        #expect(!reply.contains("Boston"))
        #expect(!reply.contains("02114"))
        let park = PlaceCandidate(id: "park", name: "Boston Common", address: "Boston, MA",
                                  coordinate: place.coordinate)
        #expect(NavigationSpeech.routeReady(for: park) == "Your route to Boston Common is ready. Tap Start when you're ready.")
    }

    @Test func readsQuotedValuesAndEnvironmentOverridesWithoutTreatingBlankAsAKey() {
        let configuration = VoiceConfiguration(environment: ["OPENAI_API_KEY": "environment-key", "DEEPGRAM_API_KEY": ""], fileContents: """
            # ignored
            export OPENAI_API_KEY = "file-key"
            DEEPGRAM_API_KEY = 'test-key' # comment
            DEEPGRAM_VOICE_SPEED=0.9 # comment
            """)
        #expect(configuration.openAIKey == "environment-key")
        #expect(configuration.deepgramKey == "test-key")
        #expect(configuration.speed == 0.9)
        #expect(VoiceConfiguration(fileContents: "DEEPGRAM_API_KEY=  ").deepgramKey == nil)
        #expect(VoiceConfiguration(fileContents: "DEEPGRAM_VOICE_SPEED=nan").speed == 0.95)
        #expect(VoiceConfiguration(fileContents: "DEEPGRAM_VOICE_SPEED=1.1").speed == 1.1)
        #expect(VoiceConfiguration(fileContents: "DEEPGRAM_VOICE_SPEED=9").speed == 1.2) // clamped
    }
}

@MainActor private final class RecordingSpeechPlayer: SpeechPlaying {
    var outputs: [String] = []
    var completions: [(Bool) -> Void] = []
    func play(_ audio: SpeechAudio, progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) throws {
        outputs.append(audio.text); progress(audio.text); completions.append(completion)
    }
    func speakSystem(_ text: String, progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        outputs.append("system: \(text)"); progress(text); completions.append(completion)
    }
    // Retain callbacks deliberately to simulate delegates arriving after cancellation.
    func stop() {}
}

@MainActor private final class PendingSpeech: SpeechSynthesizing {
    var pending: [String: CheckedContinuation<SpeechAudio, any Error>] = [:]
    func synthesize(_ text: String) async throws -> SpeechAudio {
        try await withCheckedThrowingContinuation { pending[text] = $0 }
    }
    func finish(_ text: String, error: Error? = nil) {
        let continuation = pending.removeValue(forKey: text)
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: SpeechAudio(data: Data(text.utf8), text: text)) }
    }
    func waitForRequest(_ text: String) async {
        for _ in 0..<100 where pending[text] == nil { await Task.yield() }
        #expect(pending[text] != nil)
    }
}

@MainActor struct SpokenFeedbackTests {
    @Test func handsBackToListenerOnlyAfterPlaybackFinishesOnce() async throws {
        let player = RecordingSpeechPlayer(), service = PendingSpeech()
        let feedback = SpokenFeedback(player: player, synthesizer: { service })
        var listeningStarts = 0
        feedback.speak("Which place?") { listeningStarts += 1 }
        await service.waitForRequest("Which place?")
        #expect(listeningStarts == 0)
        service.finish("Which place?")
        for _ in 0..<20 { await Task.yield() }
        let finished = try #require(player.completions.first)
        #expect(listeningStarts == 0) // Downloaded audio and even the final caption are not completion.
        finished(true)
        finished(true)
        #expect(listeningStarts == 1)
    }

    @Test func cancelledSupersededAndFailedPlaybackNeverReopensMicrophone() throws {
        let player = RecordingSpeechPlayer()
        let feedback = SpokenFeedback(player: player, synthesizer: { nil })
        var listeningStarts = 0
        feedback.speak("Old question?") { listeningStarts += 1 }
        let old = try #require(player.completions.last)
        feedback.speak("New question?") { listeningStarts += 1 }
        old(true)
        #expect(listeningStarts == 0)
        let cancelled = try #require(player.completions.last)
        feedback.stop()
        cancelled(true)
        feedback.speak("Failed question?") { listeningStarts += 1 }
        let failed = try #require(player.completions.last)
        failed(false)
        failed(true)
        #expect(listeningStarts == 0)
    }

    @Test func fallbackVoiceAlsoWaitsUntilSpokenQuestionFinishes() async throws {
        let player = RecordingSpeechPlayer(), service = PendingSpeech()
        let feedback = SpokenFeedback(player: player, synthesizer: { service })
        var listeningStarts = 0
        feedback.speak("Where instead?") { listeningStarts += 1 }
        await service.waitForRequest("Where instead?")
        service.finish("Where instead?", error: ServiceError.http(503))
        for _ in 0..<20 { await Task.yield() }
        #expect(feedback.usedSystemFallback)
        #expect(listeningStarts == 0)
        let finished = try #require(player.completions.last)
        finished(true)
        #expect(listeningStarts == 1)
    }

    @Test func unavailableServiceUsesPhoneSpeech() {
        let player = RecordingSpeechPlayer()
        let feedback = SpokenFeedback(player: player, synthesizer: { nil })
        feedback.speak("Route ready.")
        #expect(player.outputs == ["system: Route ready."])
        #expect(feedback.usedSystemFallback)
    }

    @Test func cancellingPendingSpeechNeverPlaysOrFallsBack() async {
        let player = RecordingSpeechPlayer(), service = PendingSpeech()
        let feedback = SpokenFeedback(player: player, synthesizer: { service })
        feedback.speak("Old route")
        await service.waitForRequest("Old route")
        feedback.stop()
        service.finish("Old route", error: ServiceError.http(500))
        for _ in 0..<20 { await Task.yield() }
        #expect(player.outputs.isEmpty)
    }

    @Test func newerDestinationSupersedesSlowPreviousReply() async {
        let player = RecordingSpeechPlayer(), service = PendingSpeech()
        let feedback = SpokenFeedback(player: player, synthesizer: { service })
        feedback.speak("Old route")
        await service.waitForRequest("Old route")
        feedback.speak("New route")
        await service.waitForRequest("New route")
        service.finish("New route")
        service.finish("Old route")
        for _ in 0..<20 { await Task.yield() }
        #expect(player.outputs == ["New route"])
    }

    @Test func providerFailureSpeaksFallback() async {
        let player = RecordingSpeechPlayer(), service = PendingSpeech()
        let feedback = SpokenFeedback(player: player, synthesizer: { service })
        feedback.speak("Try another place.")
        await service.waitForRequest("Try another place.")
        service.finish("Try another place.", error: ServiceError.http(401))
        for _ in 0..<20 { await Task.yield() }
        #expect(player.outputs == ["system: Try another place."])
    }
}
