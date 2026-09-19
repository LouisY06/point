import CoreLocation
import PointCore
import SwiftUI
import UIKit

@MainActor final class PointViewModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    enum Stage { case home, recording, searching, choosing, route }
    @Published var stage: Stage = .home
    @Published var transcript = ""
    @Published var candidates: [PlaceCandidate] = []
    @Published var selectedPlace: PlaceCandidate?
    @Published var route: RoutePlan?
    @Published var message: String?
    @Published var isDemo = false
    @Published var journeyStarted = false
    @Published var pointingAligned = false
    @Published var demoInFlight = false
    @Published var currentLocation: CLLocation?
    let recorder = VoiceRecorder()
    let glove = SimulatedGlove()
    private(set) var controller: PointController!
    private let locationManager = CLLocationManager()
    private var work: Task<Void, Never>?
    private var recordingLimit: Task<Void, Never>?

    private let maps = AppleMapsService()

    // Local development only. Production app should inject authenticated backend implementations
    // of SpeechTranscribing, keeping the OpenAI secret on the server. MapKit needs no key.
    private var developmentVoiceKey: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        #else
        nil
        #endif
    }
    override init() {
        super.init()
        controller = PointController(glove: glove)
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
    }

    func requestLocation() {
        locationManager.requestWhenInUseAuthorization()
        if locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways {
            locationManager.startUpdatingLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !isDemo, let location = locations.last else { return }
        currentLocation = location
        controller.updateLocation(location)
        pointingAligned = controller.feedback.shouldConfirm
    }

    func microphone() {
        // Temporary interaction preview requested by the user. No microphone or network access.
        // Opt into the real recorder explicitly when the service configuration is ready.
        guard ProcessInfo.processInfo.environment["POINT_LIVE_VOICE"] == "1" else {
            playVoiceDemo()
            return
        }
        if stage == .recording { finishRecording(); return }
        guard stage != .searching else { return }
        guard let key = developmentVoiceKey, !key.isEmpty else {
            message = "Voice search isn't connected yet. You can explore the sample walk below."
            return
        }
        work?.cancel()
        work = Task {
            do {
                try await recorder.start()
                guard !Task.isCancelled else { recorder.cancel(); return }
                stage = .recording
                announce("Listening. Say a destination, then tap to finish.")
                recordingLimit = Task {
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled, stage == .recording else { return }
                    finishRecording()
                }
            } catch { if !(error is CancellationError) { message = error.localizedDescription } }
        }
    }

    private func finishRecording() {
        recordingLimit?.cancel()
        do {
            let audio = try recorder.finish()
            guard let key = developmentVoiceKey else { throw ServiceError.missingCredential }
            stage = .searching
            work = Task {
                do {
                    let text = try await OpenAITranscriber(authorization: { "Bearer \(key)" }).transcribe(audio: audio)
                    guard !Task.isCancelled else { return }
                    transcript = text
                    await search(text)
                } catch { fail(error) }
            }
        } catch { fail(error) }
    }

    func searchTyped(_ text: String) {
        work?.cancel()
        transcript = text
        stage = .searching
        work = Task { await search(text) }
    }

    private func search(_ text: String) async {
        guard let location = currentLocation, location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 100, abs(location.timestamp.timeIntervalSinceNow) < 30 else {
            requestLocation()
            message = "Waiting for your location. Allow location access, then try again."
            stage = .home
            return
        }
        do {
            let places = try await maps.search(VoiceDestination.destinationQuery(from: text), near: location.coordinate)
            guard !Task.isCancelled else { return }
            isDemo = false
            candidates = places
            stage = .choosing
            announce(places.isEmpty ? "No places found. Try another name." : "Choose your destination. \(places.count) places found.")
        } catch { fail(error) }
    }

    func select(_ place: PlaceCandidate) {
        guard let location = currentLocation, location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 100, abs(location.timestamp.timeIntervalSinceNow) < 30 else {
            requestLocation()
            message = "Waiting for your location. Allow location access, then try again."
            stage = .home
            return
        }
        work?.cancel()
        stage = .searching
        work = Task {
            do {
                let plan = try await maps.walkingRoute(from: location.coordinate, to: place.coordinate, name: place.name)
                guard !Task.isCancelled else { return }
                selectedPlace = place
                route = plan
                stage = .route
                announce("Route to \(place.name) ready. Start when you're ready.")
            } catch { fail(error) }
        }
    }

    func playVoiceDemo() {
        guard !demoInFlight else { return }
        cancel()
        isDemo = true
        demoInFlight = true
        stage = .recording
        work = Task {
            do {
                // Let the hand finish opening the speech surface before the sample starts.
                // Live capture remains independent of the decorative movie.
                try await Task.sleep(for: .milliseconds(2550))
                for word in ["Take", "me", "to", "Shake", "Shack"] {
                    try Task.checkCancellation()
                    transcript += transcript.isEmpty ? word : " " + word
                    try await Task.sleep(for: .milliseconds(word == "Shake" ? 420 : 270))
                }
                try await Task.sleep(for: .milliseconds(450))
                stage = .searching
                try await Task.sleep(for: .milliseconds(1500))
                try Task.checkCancellation()
                showSampleRoute()
                demoInFlight = false
            } catch {
                // Cancel/home owns resetting the visible state; never resume an old demo.
            }
        }
    }

    func preview() { playVoiceDemo() }

    private func showSampleRoute() {
        isDemo = true
        transcript = "Take me to Shake Shack"
        selectedPlace = PlaceCandidate(id: "demo", name: "Shake Shack", address: "Sample walking route · Cambridge", coordinate: DemoRoute.coordinates.last!)
        route = DemoRoute.plan
        stage = .route
        announce("Sample route to Shake Shack. This is a preview, not live directions.")
    }

    func startJourney() {
        guard let route else { return }
        do {
            try controller.start(route)
            if isDemo { glove.connect() }
            journeyStarted = true
            announce(isDemo ? "Demo started. Try the pointing control." : "Navigation started. The glove is not connected yet.")
        } catch { fail(error) }
    }

    func setDemoAlignment(_ aligned: Bool) {
        guard isDemo, journeyStarted else { return }
        pointingAligned = aligned
        // Demo preview only; never presented as physical-device telemetry.
        if aligned { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    }

    func cancel() {
        work?.cancel()
        recordingLimit?.cancel()
        recorder.cancel()
        controller.stop()
        glove.disconnect()
        route = nil
        selectedPlace = nil
        candidates = []
        transcript = ""
        journeyStarted = false
        pointingAligned = false
        demoInFlight = false
        isDemo = false
        stage = .home
        message = nil
    }

    func sceneInactive() {
        if stage == .recording || demoInFlight { cancel() }
    }

    private func fail(_ error: Error) {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        stage = .home
        message = error.localizedDescription
    }

    private func announce(_ text: String) { UIAccessibility.post(notification: .announcement, argument: text) }
}

enum DemoRoute {
    // Synthetic geometry for interface review. Not live directions or a verified store location.
    static let coordinates: [CLLocationCoordinate2D] = [
        .init(latitude: 42.3652, longitude: -71.1035),
        .init(latitude: 42.3647, longitude: -71.1027),
        .init(latitude: 42.3641, longitude: -71.1016),
        .init(latitude: 42.3634, longitude: -71.1004),
        .init(latitude: 42.3628, longitude: -71.1013),
        .init(latitude: 42.3622, longitude: -71.1024)
    ]
    static var plan: RoutePlan {
        RoutePlan(destinationName: "Shake Shack", checkpoints: coordinates.enumerated().map { index, coordinate in
            RouteCheckpoint(coordinate: coordinate, distanceFromStartMeters: Double(index) * 80,
                            stepIndex: index < 3 ? 0 : 1, stepInstruction: "Continue to the next point", bearingToNextDegrees: 135)
        }, beacons: [
            PingTarget(coordinate: coordinates[3], instruction: "Follow the next point", isFinalDestination: false, bearingAfterTurnDegrees: 225),
            PingTarget(coordinate: coordinates[5], instruction: "Destination", isFinalDestination: true, bearingAfterTurnDegrees: 225)
        ])
    }
}
