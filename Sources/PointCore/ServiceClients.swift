import CoreLocation
import Foundation

/// REST clients for a trusted host/development runner. A distributed iOS app must use an
/// authenticated backend, not store provider API keys. Endpoints and headers are injectable.
@MainActor public final class OpenAITranscriber: SpeechTranscribing {
    private let endpoint: URL
    private let authorization: () async throws -> String
    private let session: URLSession
    private let model: String

    public init(endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
                model: String = "gpt-transcribe", session: URLSession = .shared,
                authorization: @escaping () async throws -> String) {
        self.endpoint = endpoint; self.model = model; self.session = session
        self.authorization = authorization
    }

    public func transcribe(audio: Data) async throws -> String {
        guard !audio.isEmpty, audio.count <= 24_000_000 else { throw ServiceError.invalidAudio }
        let boundary = "Point-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"destination.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(try await authorization(), forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, from: body)
        try requireSuccess(response)
        struct Transcript: Decodable { let text: String }
        let text = try JSONDecoder().decode(Transcript.self, from: data).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ServiceError.emptyTranscript }
        return text
    }
}

private func requireSuccess(_ response: URLResponse) throws {
    guard let response = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
    guard (200..<300).contains(response.statusCode) else { throw ServiceError.http(response.statusCode) }
}
