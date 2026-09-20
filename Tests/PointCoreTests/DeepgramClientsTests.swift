import Foundation
import Testing
@testable import PointCore

/// Serves canned responses so the Deepgram clients are tested without the network.
final class DeepgramURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    body.append(buffer, count: count)
                }
            }
            let (response, data) = try Self.handler!(request, body)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct DeepgramClientsTests {
    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepgramURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func configurationReadsDeepgramSettings() {
        let configuration = VoiceConfiguration(fileContents: "DEEPGRAM_API_KEY=dg-key\nDEEPGRAM_VOICE=flux-miles-en\nDEEPGRAM_EXPRESSIVITY=5")
        #expect(configuration.deepgramKey == "dg-key")
        #expect(configuration.deepgramVoice == "flux-miles-en")
        #expect(configuration.deepgramExpressivity == 2) // clamped
        let defaults = VoiceConfiguration()
        #expect(defaults.deepgramKey == nil && defaults.deepgramVoice == "flux-hannah-en" && defaults.deepgramExpressivity == 0)
    }

    @Test func speechPostsTextToFluxAndReturnsAudio() async throws {
        DeepgramURLProtocol.handler = { request, body in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v2/speak")
            let query = request.url?.query ?? ""
            #expect(query.contains("model=flux-hannah-en") && query.contains("expressivity=0") && query.contains("speed=0.95"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Token dg-key")
            #expect(query.contains("dg-key") == false)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json == ["text": "Route ready."])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "audio/mpeg"])!, Data("ID3audio".utf8))
        }
        let speech = DeepgramSpeech(configuration: VoiceConfiguration(environment: ["DEEPGRAM_API_KEY": "dg-key"]), session: session)
        let audio = try await speech.synthesize("Route ready.")
        #expect(audio.data == Data("ID3audio".utf8) && audio.words.isEmpty)
        // No timings from Deepgram: captions are spread over the clip at playback.
        let captioned = audio.withEstimatedCues(duration: 2)
        #expect(captioned.visibleText(at: 0) == "Route")
        #expect(captioned.visibleText(at: 1.9) == "Route ready.")
    }

    @Test func speechRejectsErrorsAndJSONBodies() async {
        for (status, type) in [(401, "application/json"), (500, "audio/mpeg"), (200, "application/json")] {
            DeepgramURLProtocol.handler = { request, _ in
                (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!, Data("{}".utf8))
            }
            let speech = DeepgramSpeech(configuration: VoiceConfiguration(environment: ["DEEPGRAM_API_KEY": "dg-key"]), session: session)
            await #expect(throws: (any Error).self) { try await speech.synthesize("Route ready.") }
        }
    }

    @Test func transcriberSendsKeytermsAndReadsTheTranscript() async throws {
        DeepgramURLProtocol.handler = { request, body in
            #expect(request.url?.path == "/v1/listen")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.contains(URLQueryItem(name: "model", value: "nova-3")))
            #expect(items.filter { $0.name == "keyterm" }.map(\.value) == ["Kendall", "Copley"])
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Token dg-key")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "audio/mp4")
            #expect(body == Data("m4a".utf8))
            let json = ["results": ["channels": [["alternatives": [["transcript": " Take me to Copley ", "confidence": 0.98]]]]]]
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    try JSONSerialization.data(withJSONObject: json))
        }
        let transcriber = DeepgramTranscriber(apiKey: "dg-key", keyterms: ["Kendall", "Copley"], session: session)
        #expect(try await transcriber.transcribe(audio: Data("m4a".utf8)) == "Take me to Copley")
        #expect(DeepgramTranscriber.bostonKeyterms.count <= 100)
    }

    @Test func transcriberTreatsSilenceAsEmpty() async {
        DeepgramURLProtocol.handler = { request, _ in
            let json = ["results": ["channels": [["alternatives": [["transcript": ""]]]]]]
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONSerialization.data(withJSONObject: json))
        }
        let transcriber = DeepgramTranscriber(apiKey: "dg-key", session: session)
        await #expect(throws: ServiceError.self) { try await transcriber.transcribe(audio: Data("m4a".utf8)) }
    }
}
