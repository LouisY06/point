import Foundation

@MainActor public protocol SpeechSynthesizing {
    func synthesize(_ text: String) async throws -> SpeechAudio
}

/// Direct provider client for local development. Inject an authenticated backend for distribution.
@MainActor public final class ElevenLabsSpeech: SpeechSynthesizing {
    private let configuration: VoiceConfiguration
    private let session: URLSession
    private let baseURL: URL

    public init(configuration: VoiceConfiguration, session: URLSession = .shared,
                baseURL: URL = URL(string: "https://api.elevenlabs.io/v1/text-to-speech")!) {
        self.configuration = configuration
        self.session = session
        self.baseURL = baseURL
    }

    public func synthesize(_ text: String) async throws -> SpeechAudio {
        try Task.checkCancellation()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 1_000 else { throw SpeechError.invalidText }
        guard let key = configuration.elevenLabsKey else { throw ServiceError.missingCredential }
        var components = URLComponents(url: baseURL.appendingPathComponent(configuration.voiceID).appendingPathComponent("with-timestamps"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": configuration.speechModel,
            "voice_settings": ["stability": 0.55, "similarity_boost": 0.75,
                               "style": 0.0, "speed": configuration.speed, "use_speaker_boost": true]
        ])
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw ServiceError.http(response.statusCode) }
        guard !data.isEmpty, data.count <= 8_000_000 else {
            throw ServiceError.invalidResponse
        }
        struct TimedResponse: Decodable {
            struct Alignment: Decodable {
                let characters: [String]
                let character_start_times_seconds: [Double]
            }
            let audio_base64: String
            let alignment: Alignment?
        }
        let result = try JSONDecoder().decode(TimedResponse.self, from: data)
        guard let audio = Data(base64Encoded: result.audio_base64), !audio.isEmpty, audio.count <= 5_000_000,
              let alignment = result.alignment else { throw ServiceError.invalidResponse }
        let words = try SpeechAudio.wordCues(characters: alignment.characters, starts: alignment.character_start_times_seconds)
        return SpeechAudio(data: audio, text: text, words: words)
    }
}

public enum SpeechError: Error { case invalidText }
