import CoreLocation
import Foundation
import PointCore

/// Scripted transcription. Latency is virtual: the scenario decides when the transcript lands,
/// the call itself returns immediately so the suite stays fast and deterministic.
@MainActor public final class ScriptedTranscriber: SpeechTranscribing {
    private let transcript: String
    private let fails: Bool
    public private(set) var callCount = 0

    public init(transcript: String, fails: Bool = false) {
        self.transcript = transcript
        self.fails = fails
    }

    public func transcribe(audio: Data) async throws -> String {
        callCount += 1
        if fails { throw ServiceError.emptyTranscript }
        return transcript
    }
}

@MainActor public final class ScriptedPlaces: PlaceSearching {
    private let candidates: [PlaceCandidate]
    public private(set) var queries: [String] = []

    public init(candidates: [PlaceCandidate]) { self.candidates = candidates }

    public func search(_ query: String, near location: CLLocationCoordinate2D) async throws -> [PlaceCandidate] {
        queries.append(query)
        return candidates
    }
}

/// Serves the scenario's route, plus optional replacements for reroute requests.
@MainActor public final class FixtureRouteProvider: RouteProviding {
    private let plans: [RoutePlan]
    private var served = 0
    public private(set) var requests: [CLLocationCoordinate2D] = []

    public init(plans: [RoutePlan]) { self.plans = plans }

    public func walkingRoute(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D,
                             name: String) async throws -> RoutePlan {
        requests.append(origin)
        guard !plans.isEmpty else { throw ServiceError.noRoute }
        let plan = plans[min(served, plans.count - 1)]
        served += 1
        return plan
    }
}

/// Speech never gates navigation, so the harness records replies and completes them immediately.
@MainActor public final class RecordingSpeechPlayer: SpeechPlaying {
    public private(set) var spoken: [String] = []
    public private(set) var stopCount = 0

    public init() {}

    public func play(_ audio: SpeechAudio, progress: @escaping (String) -> Void,
                     completion: @escaping (Bool) -> Void) throws {
        spoken.append(audio.text)
        completion(true)
    }

    public func speakSystem(_ text: String, progress: @escaping (String) -> Void,
                            completion: @escaping (Bool) -> Void) {
        spoken.append(text)
        completion(true)
    }

    public func stop() {
        stopCount += 1
    }
}
