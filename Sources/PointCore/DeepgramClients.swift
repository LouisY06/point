import Foundation

/// Deepgram Flux text-to-speech (`/v2/speak`). Returns compressed audio in one response; there
/// are no word timings, so captions are estimated from the audio length at playback.
/// Direct provider client for local development; a distributed app must use a backend.
@MainActor public final class DeepgramSpeech: SpeechSynthesizing {
    private let configuration: VoiceConfiguration
    private let session: URLSession
    private let endpoint: URL

    public init(configuration: VoiceConfiguration, session: URLSession = .shared,
                endpoint: URL = URL(string: "https://api.deepgram.com/v2/speak")!) {
        self.configuration = configuration
        self.session = session
        self.endpoint = endpoint
    }

    public func synthesize(_ text: String) async throws -> SpeechAudio {
        try Task.checkCancellation()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 1_000 else { throw SpeechError.invalidText }
        guard let key = configuration.deepgramKey else { throw ServiceError.missingCredential }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "model", value: configuration.deepgramVoice),
            URLQueryItem(name: "speed", value: String(format: "%.2f", configuration.speed)),
            URLQueryItem(name: "expressivity", value: String(configuration.deepgramExpressivity))
        ] // Default output is MP3 (audio/mpeg); the API rejects an explicit container.
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw ServiceError.http(response.statusCode) }
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard !data.isEmpty, data.count <= 5_000_000, !type.contains("json") else { throw ServiceError.invalidResponse }
        return SpeechAudio(data: data, text: text)
    }
}

/// Deepgram Nova-3 pre-recorded transcription (`/v1/listen`) with keyterm prompting, so station,
/// line and chain names around Boston are recognised instead of guessed.
@MainActor public final class DeepgramTranscriber: SpeechTranscribing {
    private let endpoint: URL
    private let session: URLSession
    private let key: String
    private let keyterms: [String]

    public init(apiKey: String, keyterms: [String] = DeepgramTranscriber.bostonKeyterms,
                session: URLSession = .shared, endpoint: URL = URL(string: "https://api.deepgram.com/v1/listen")!) {
        self.key = apiKey; self.keyterms = keyterms; self.session = session; self.endpoint = endpoint
    }

    public func transcribe(audio: Data) async throws -> String {
        guard !audio.isEmpty, audio.count <= 24_000_000 else { throw ServiceError.invalidAudio }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "language", value: "en")
        ] + keyterms.prefix(100).map { URLQueryItem(name: "keyterm", value: $0) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, from: audio)
        guard let response = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw ServiceError.http(response.statusCode) }
        let text = try Self.transcript(from: data)
        guard !text.isEmpty else { throw ServiceError.emptyTranscript }
        return text
    }

    static func transcript(from data: Data) throws -> String {
        struct Envelope: Decodable {
            struct Results: Decodable {
                struct Channel: Decodable {
                    struct Alternative: Decodable { let transcript: String }
                    let alternatives: [Alternative]
                }
                let channels: [Channel]
            }
            let results: Results
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return (envelope.results.channels.first?.alternatives.first?.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Names a rider is likely to say that generic models mishear. Up to 100 terms are accepted.
    public static let bostonKeyterms: [String] = [
        "MBTA", "the T", "Red Line", "Green Line", "Orange Line", "Blue Line", "Silver Line", "commuter rail",
        "Alewife", "Davis", "Porter", "Harvard Square", "Central Square", "Kendall", "Charles MGH", "Park Street",
        "Downtown Crossing", "South Station", "Broadway", "Andrew", "JFK UMass", "Ashmont", "Braintree", "Quincy",
        "Boylston", "Arlington", "Copley", "Hynes", "Kenmore", "Fenway", "Longwood", "Brookline", "Coolidge Corner",
        "Boston College", "Cleveland Circle", "Riverside", "Heath Street", "Prudential", "Symphony", "Northeastern",
        "Museum of Fine Arts", "Lechmere", "Union Square", "North Station", "Haymarket", "State Street", "Government Center",
        "Back Bay", "Massachusetts Avenue", "Mass Ave", "Ruggles", "Roxbury Crossing", "Jackson Square", "Forest Hills",
        "Nubian", "Dudley", "Chinatown", "Tufts Medical Center", "Wonderland", "Airport", "Maverick", "Aquarium",
        "Seaport", "Fenway Park", "Faneuil Hall", "Quincy Market", "Newbury Street", "Beacon Hill", "Somerville",
        "Cambridge", "Allston", "Brighton", "Dorchester", "Jamaica Plain", "Charlestown", "East Boston", "Roslindale",
        "McDonald's", "Dunkin", "Starbucks", "CVS", "Walgreens", "Trader Joe's", "Whole Foods", "Star Market", "Shake Shack",
        "Tatte", "Pavement", "Flour Bakery", "Chipotle", "Sweetgreen", "Target", "Walmart"
    ]
}
