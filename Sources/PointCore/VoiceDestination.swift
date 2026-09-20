import Combine
import CoreLocation
import Foundation

@MainActor public protocol SpeechTranscribing {
    func transcribe(audio: Data) async throws -> String
}

public struct PlaceCandidate: Identifiable {
    public let id: String
    public let name: String
    public let address: String
    public let coordinate: CLLocationCoordinate2D
    /// Street only for spoken confirmation; the full address remains available visually.
    public let streetAddress: String?
    public let city: String?
    public let cityAliases: [String]
    public let isArea: Bool

    public init(id: String, name: String, address: String, coordinate: CLLocationCoordinate2D,
                streetAddress: String? = nil, city: String? = nil, cityAliases: [String] = [], isArea: Bool = false) {
        self.id = id; self.name = name; self.address = address; self.coordinate = coordinate
        self.streetAddress = streetAddress
        self.city = city; self.isArea = isArea
        self.cityAliases = cityAliases
    }
}

public enum NavigationSpeech {
    public static func routeReady(for place: PlaceCandidate, handsFree: Bool = false) -> String {
        let street = place.streetAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let location = street.isEmpty ? "" : " on \(street)"
        return "Your route to \(place.name)\(location) is ready. " + (handsFree ? "Say start when you’re ready." : "Tap Start when you're ready.")
    }
}

@MainActor public protocol PlaceSearching {
    func search(_ query: String, near location: CLLocationCoordinate2D) async throws -> [PlaceCandidate]
}

public enum VoiceSearchState: String { case idle, transcribing, searching, chooseDestination, failed }

/// Speech and typed input share the same editable search path. Navigation starts only after selection.
@MainActor public final class VoiceDestination: ObservableObject {
    @Published public private(set) var state: VoiceSearchState = .idle
    @Published public private(set) var transcript = ""
    @Published public private(set) var candidates: [PlaceCandidate] = []
    @Published public private(set) var errorMessage: String?
    private let transcriber: any SpeechTranscribing
    private let places: any PlaceSearching
    private var generation = UUID()

    public init(transcriber: any SpeechTranscribing, places: any PlaceSearching) {
        self.transcriber = transcriber; self.places = places
    }

    public func submit(audio: Data, near location: CLLocationCoordinate2D) async {
        let request = begin(.transcribing)
        do {
            let text = try await transcriber.transcribe(audio: audio)
            guard generation == request, !Task.isCancelled else { return }
            transcript = text
            try await search(text, near: location, request: request)
        } catch { fail(error, request: request) }
    }

    public func submit(text: String, near location: CLLocationCoordinate2D) async {
        let request = begin(.searching)
        transcript = text
        do { try await search(text, near: location, request: request) }
        catch { fail(error, request: request) }
    }

    public func cancel() {
        generation = UUID()
        state = .idle
        candidates = []
        errorMessage = nil
    }

    private func begin(_ state: VoiceSearchState) -> UUID {
        generation = UUID()
        self.state = state
        transcript = ""
        candidates = []
        errorMessage = nil
        return generation
    }

    private func search(_ text: String, near location: CLLocationCoordinate2D, request: UUID) async throws {
        let query = Self.destinationQuery(from: text)
        guard !query.isEmpty else { throw ServiceError.emptyTranscript }
        state = .searching
        let results = try await places.search(query, near: location)
        guard generation == request, !Task.isCancelled else { return }
        candidates = results
        state = .chooseDestination
    }

    private func fail(_ error: Error, request: UUID) {
        guard generation == request else { return }
        if error is CancellationError || Task.isCancelled { cancel(); return }
        state = .failed
        errorMessage = error.localizedDescription
    }

    /// Single-turn phrasing support; the user's transcript stays intact and editable. Strips the
    /// request wrapper, "nearest"/"near me" (handled by DestinationResolver) and end punctuation.
    nonisolated public static func destinationQuery(from text: String) -> String {
        let patterns = [
            #"(?i)^(?:(?:hey|ok|okay|hi)[,\s]+)?(?:(?:can|could|would) you\s+)?(?:please\s+)?"# +
            #"(?:take me to|navigate to|navigate me to|directions to|get directions to|i want to go to|"# +
            #"i need to go to|i'd like to go to|bring me to|get me to|walk me to|guide me to|go to|find me|find|where is|where's)\s+"#,
            #"(?i)^(?:the\s+|a\s+)?(?:nearest|closest)\s+"#,
            #"(?i)\s+(?:near me|nearby|close to me|closest to me|nearest to me)\s*$"#,
            #"(?i)(?:,?\s*please)?[\s.!?,]*$"#
        ]
        return patterns.reduce(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            $0.replacingOccurrences(of: $1, with: "", options: .regularExpression)
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ServiceError: LocalizedError {
    case http(Int), invalidResponse, emptyTranscript, invalidAudio, missingCredential, noRoute

    public var errorDescription: String? {
        switch self {
        case .http(let status): return "The service returned an error (\(status)). Please try again."
        case .invalidResponse: return "The service response could not be read."
        case .emptyTranscript: return "No destination was heard. Try again or type a place."
        case .invalidAudio: return "Record a short M4A clip before searching."
        case .missingCredential: return "The service has not been configured yet."
        case .noRoute: return "No walking route was found."
        }
    }
}
