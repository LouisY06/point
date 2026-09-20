import Foundation

/// Reads values only; callers decide where development credentials may be loaded.
public struct VoiceConfiguration {
    public static let recommendedVoiceID = "AaOhDHYJ1XLZk74lXhdE" // Caleb — Trusted Guide
    public let openAIKey: String?
    public let transcriptionModel: String
    public let intentModel: String
    public let elevenLabsKey: String?
    public let voiceID: String
    public let speechModel: String
    public let speed: Double
    /// Optional; the MBTA API works without a key at 20 requests/min.
    public let mbtaKey: String?
    /// Deepgram: preferred for both the final transcript (Nova-3 with place-name keyterms) and
    /// spoken replies (Flux TTS) when set; OpenAI and ElevenLabs remain the fallbacks.
    public let deepgramKey: String?
    public let deepgramVoice: String
    /// Flux TTS delivery, -2 (calm) to 2 (animated).
    public let deepgramExpressivity: Int

    public init(environment: [String: String] = [:], fileContents: String = "") {
        let file = Self.parse(fileContents)
        func value(_ name: String) -> String? {
            for candidate in [environment[name], file[name]] {
                if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
            }
            return nil
        }
        openAIKey = value("OPENAI_API_KEY")
        transcriptionModel = value("OPENAI_TRANSCRIPTION_MODEL") ?? "gpt-transcribe"
        intentModel = value("OPENAI_INTENT_MODEL") ?? "gpt-4.1-mini"
        elevenLabsKey = value("ELEVENLABS_API_KEY")
        voiceID = value("ELEVENLABS_VOICE_ID") ?? Self.recommendedVoiceID
        speechModel = value("ELEVENLABS_MODEL_ID") ?? "eleven_flash_v2_5"
        let requestedSpeed = value("ELEVENLABS_VOICE_SPEED").flatMap(Double.init) ?? 0.95
        speed = requestedSpeed.isFinite ? min(1.2, max(0.7, requestedSpeed)) : 0.95
        mbtaKey = value("MBTA_API_KEY")
        deepgramKey = value("DEEPGRAM_API_KEY")
        deepgramVoice = value("DEEPGRAM_VOICE") ?? "flux-hannah-en"
        deepgramExpressivity = min(2, max(-2, value("DEEPGRAM_EXPRESSIVITY").flatMap(Int.init) ?? 0))
    }

    private static func parse(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'",
               let end = value.dropFirst().firstIndex(of: quote) {
                value = String(value[value.index(after: value.startIndex)..<end])
            } else if let comment = value.range(of: " #") {
                value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            values[key] = value
        }
        return values
    }
}
