import Foundation
import Testing
@testable import PointCore

/// Opt-in only: makes paid provider requests using a local, ignored environment file.
@MainActor struct LiveVoiceTests {
    private func configuration() throws -> VoiceConfiguration {
        let path = try #require(ProcessInfo.processInfo.environment["POINT_ENV_FILE"])
        return VoiceConfiguration(fileContents: try String(contentsOfFile: path, encoding: .utf8))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["POINT_LIVE_SPEECH_CHECK"] == "1"))
    func generatesShortReplyThroughProductionClient() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["POINT_SPEECH_SAMPLE_PATH"])
        let speech = ElevenLabsSpeech(configuration: try configuration())
        let data = try await speech.synthesize("Your route to Shake Shack on Cambridge Street is ready. Tap Start when you're ready.")
        #expect(data.data.count > 1_000)
        #expect(data.words.count > 10)
        try data.data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["POINT_LIVE_TRANSCRIPTION_CHECK"] == "1"))
    func transcribesPreparedClipThroughProductionClient() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["POINT_TRANSCRIPTION_SAMPLE_PATH"])
        let configuration = try configuration()
        let key = try #require(configuration.openAIKey)
        let service = OpenAITranscriber(model: configuration.transcriptionModel, authorization: { "Bearer \(key)" })
        let text = try await service.transcribe(audio: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(text.localizedCaseInsensitiveContains("Shake Shack"))
        #expect(text.localizedCaseInsensitiveContains("Cambridge"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["POINT_LIVE_INTENT_CHECK"] == "1"))
    func interpretsCitiesFollowUpsAndCorrections() async throws {
        let service = OpenAIDestinationInterpreter(configuration: try configuration())
        let city = try await service.interpret("Take me to Boston", context: DestinationContext())
        #expect(city.action == .area)
        #expect(city.city.localizedCaseInsensitiveContains("Boston"))
        let followUp = try await service.interpret("Shake Shack", context: DestinationContext(requestedCity: "Boston"))
        #expect(followUp.action == .destination)
        #expect(followUp.query.localizedCaseInsensitiveContains("Boston"))
        let correction = try await service.interpret("Yes, but I meant the one on Newbury Street", context: DestinationContext(confirmationPending: true, destinationName: "Shake Shack"))
        #expect(correction.action == .destination)
        #expect(correction.query.localizedCaseInsensitiveContains("Newbury"))
        #expect(correction.query.localizedCaseInsensitiveContains("Shake Shack"))
        let uncertain = try await service.interpret("I'm not sure", context: DestinationContext(confirmationPending: true))
        #expect(uncertain.action == .clarify)
    }
}
