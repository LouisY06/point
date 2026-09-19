import AVFoundation
import Combine
import CoreLocation
import PointCore
import SwiftUI
import UIKit

@MainActor final class PointViewModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    enum Stage { case home, recording, searching, clarifying, choosing, route }
    @Published var stage: Stage = .home
    @Published var transcript = ""
    @Published var candidates: [PlaceCandidate] = []
    @Published var selectedPlace: PlaceCandidate?
    @Published var route: RoutePlan?
    @Published var message: String?
    @Published private(set) var followUpPrompt: String?
    @Published private(set) var displayedReply = ""
    private var requestedCity: String?
    private var originCityCache: (context: AppleMapsService.CityContext, fix: CLLocation, resolvedAt: Date)?
    private var pendingRoute: (place: PlaceCandidate, plan: RoutePlan, origin: CLLocation, created: Date)?
    var needsConfirmation: Bool { pendingRoute != nil }
    @Published var isDemo = false
    @Published var journeyStarted = false
    @Published var pointingAligned = false
    @Published var demoInFlight = false
    @Published var currentLocation: CLLocation?
    @Published var usePhoneAsGlove = true
    @Published private(set) var journeyState: JourneyState = .idle
    @Published private(set) var activeBeaconIndex: Int?
    let mapTelemetry = RouteMapTelemetry()
    let phoneTester = PhoneBeaconTester()
    let recorder = VoiceRecorder()
    let glove = SimulatedGlove()
    private(set) var controller: PointController!
    private let locationManager = CLLocationManager()
    private var work: Task<Void, Never>?
    private var recordingLimit: Task<Void, Never>?
    private var replyListeningTask: Task<Void, Never>?
    private var voiceOverReply: (text: String, finished: () -> Void)?
    private var subscriptions = Set<AnyCancellable>()

    private let maps = AppleMapsService()
    private let speechPlayer = PhoneSpeechPlayer()
    private lazy var spokenFeedback = SpokenFeedback(player: speechPlayer, onProgress: { [weak self] text in
        self?.displayedReply = text
    }) { [weak self] in
        guard let configuration = self?.developmentVoiceConfiguration, configuration.elevenLabsKey != nil else { return nil }
        return ElevenLabsSpeech(configuration: configuration)
    }

    // Local development only. Production app should inject authenticated backend implementations
    // of SpeechTranscribing and SpeechSynthesizing. MapKit needs no key.
    private var developmentVoiceConfiguration: VoiceConfiguration {
        #if DEBUG
        // A launch from the home screen has no Xcode environment, so also accept a dev.env file
        // copied into the app's Documents folder (see README). Never bundled or committed.
        let file = URL.documentsDirectory.appending(path: "dev.env")
        return VoiceConfiguration(environment: ProcessInfo.processInfo.environment,
                                  fileContents: (try? String(contentsOf: file, encoding: .utf8)) ?? "")
        #else
        return VoiceConfiguration()
        #endif
    }
    override init() {
        super.init()
        controller = PointController(glove: glove)
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        // Physical camera/top edge is forward, independent of UI rotation or screen-down grip.
        locationManager.headingOrientation = .portrait
        locationManager.headingFilter = kCLHeadingFilterNone
        locationManager.activityType = .fitness
        controller.navigation.$state.sink { [weak self] state in
            guard let self else { return }
            journeyState = state
            if state == .arrived {
                locationManager.allowsBackgroundLocationUpdates = false
                locationManager.stopUpdatingHeading()
                mapTelemetry.clearHeading()
                phoneTester.stop(status: "You’ve arrived")
            }
        }.store(in: &subscriptions)
        controller.navigation.$beaconIndex.sink { [weak self] index in
            self?.activeBeaconIndex = index
        }.store(in: &subscriptions)
        // Words appear as they are spoken; the final transcript replaces them after finishing.
        recorder.$liveTranscript.sink { [weak self] text in
            guard let self, stage == .recording else { return }
            transcript = text
        }.store(in: &subscriptions)
        recorder.$endpoint.sink { [weak self] endpoint in
            guard let self, stage == .recording, !isDemo else { return }
            switch endpoint {
            case .listening: break
            case .finished: finishRecording()
            case .noSpeech:
                recordingLimit?.cancel()
                recorder.cancel()
                // Cancelling capture also cancels the endpoint task delivering this event.
                // Set the retry state directly; fail() deliberately ignores cancelled tasks.
                message = ServiceError.emptyTranscript.localizedDescription
                ask(ServiceError.emptyTranscript.localizedDescription, listensForReply: false)
            }
        }.store(in: &subscriptions)
        // VoiceOver owns spoken announcements when active, avoiding two voices at once.
        NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.stopSpokenReply() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIAccessibility.announcementDidFinishNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, let reply = voiceOverReply,
                      notification.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String == reply.text else { return }
                voiceOverReply = nil
                if notification.userInfo?[UIAccessibility.announcementWasSuccessfulUserInfoKey] as? Bool == true {
                    reply.finished()
                }
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let kind = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
                if kind == AVAudioSession.InterruptionType.began.rawValue { self?.sceneInactive() }
                else if UIApplication.shared.applicationState == .active { self?.sceneActive() }
            }.store(in: &subscriptions)
    }

    /// Ask for every permission on first launch, so no prompt interrupts a live voice request.
    func requestPermissions() async {
        _ = await VoiceRecorder.requestPermissions()
        requestLocation()
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
        } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            currentLocation = nil
            pauseJourney()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        mapTelemetry.receive(newHeading)
        phoneTester.receive(newHeading)
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        phoneTester.running
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !isDemo, let location = locations.last else { return }
        currentLocation = location
        let previouslyOffRoute = controller.navigation.rerouteRequired
        let arrival = controller.updateLocation(location)
        pointingAligned = controller.feedback.shouldConfirm
        if journeyStarted, let arrival {
            announce(arrival.isDestination ? "You've arrived at \(selectedPlace?.name ?? "your destination")."
                     : "Beacon \(arrival.index + 1) reached. Point toward beacon \(arrival.index + 2).")
            if usePhoneAsGlove { phoneTester.reachedBeacon(arrival) }
        } else if journeyStarted, !previouslyOffRoute, controller.navigation.rerouteRequired {
            announce("You seem to be off the route. Check the map before continuing.")
        }
    }

    func microphone() {
        startListening(automatically: false)
    }

    private func startListening(automatically: Bool) {
        guard !demoInFlight, UIApplication.shared.applicationState == .active else { return }
        if stage == .recording { finishRecording(); return }
        guard stage != .searching else { return }
        work?.cancel()
        stopSpokenReply()
        transcript = ""
        work = Task {
            do {
                try await recorder.start()
                guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { recorder.cancel(); return }
                stage = .recording
                // Do not play generated speech into our own recording.
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                if !automatically {
                    UIAccessibility.post(notification: .announcement, argument: "Listening. Say a destination. I'll finish when you pause.")
                }
                recordingLimit = Task {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled, stage == .recording else { return }
                    finishRecording()
                }
            } catch { fail(error) }
        }
    }

    private func finishRecording() {
        guard stage == .recording else { return }
        recordingLimit?.cancel()
        stage = .searching
        work = Task {
            do {
                let recording = try await recorder.finish()
                guard !Task.isCancelled else { return }
                // OpenAI gives the final transcript when configured; the live Apple Speech text
                // is the fallback, so voice still works without a key or when the request fails.
                var text = recording.transcript
                let configuration = developmentVoiceConfiguration
                if let key = configuration.openAIKey {
                    do { text = try await OpenAITranscriber(model: configuration.transcriptionModel,
                                                           authorization: { "Bearer \(key)" }).transcribe(audio: recording.audio) }
                    catch { if text.isEmpty { throw error } }
                }
                guard !Task.isCancelled else { return }
                guard !text.isEmpty else { throw ServiceError.emptyTranscript }
                transcript = text
                await search(text)
            } catch { fail(error) }
        }
    }

    func searchTyped(_ text: String) {
        work?.cancel()
        recordingLimit?.cancel()
        stopSpokenReply()
        recorder.cancel()
        transcript = text
        stage = .searching
        work = Task { await search(text) }
    }

    func prepareTypedReply() {
        work?.cancel()
        recordingLimit?.cancel()
        stopSpokenReply()
        recorder.cancel()
        stage = followUpPrompt == nil ? .home : .clarifying
    }

    private func search(_ text: String) async {
        let reply = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if ["cancel", "never mind", "nevermind", "stop"].contains(reply) { cancel(); return }
        if pendingRoute != nil {
            if ["yes", "yeah", "yep", "sure", "correct", "that's right", "that is correct"].contains(reply) {
                await confirmPendingRoute(); return
            }
            if ["no", "nope", "not right", "that's wrong"].contains(reply) { declineDestination(); return }
        }
        var query = VoiceDestination.destinationQuery(from: text)
        let configuration = developmentVoiceConfiguration
        if configuration.openAIKey != nil {
            do {
                let currentCity: AppleMapsService.CityContext?
                if let fix = currentLocation, (0...100).contains(fix.horizontalAccuracy),
                   (0...30).contains(Date().timeIntervalSince(fix.timestamp)) {
                    currentCity = await resolveOriginCity(at: fix)
                } else { currentCity = nil }
                try Task.checkCancellation()
                let context = DestinationContext(requestedCity: requestedCity ?? pendingRoute?.place.city,
                                                 currentCity: currentCity?.name,
                                                 confirmationPending: pendingRoute != nil,
                                                 destinationName: pendingRoute?.place.name, candidates: candidates)
                let intent = try await OpenAIDestinationInterpreter(configuration: configuration).interpret(text, context: context)
                guard !Task.isCancelled else { return }
                switch intent.action {
                case .cancel: cancel(); return
                case .area:
                    let area = intent.city.isEmpty ? query : intent.city
                    pendingRoute = nil
                    requestedCity = area
                    ask("Which place in \(area) would you like to go to?")
                    return
                case .affirm:
                    if pendingRoute != nil { await confirmPendingRoute() }
                    else { ask("Which place would you like to go to?") }
                    return
                case .reject: declineDestination(); return
                case .choose:
                    if let place = candidates.first(where: { $0.id == intent.candidateID }) { await route(to: place) }
                    else { ask("Which location did you mean? Say its name or street.") }
                    return
                case .clarify:
                    ask(followUpPrompt ?? "Which place or street address would you like to go to?")
                    return
                case .destination:
                    guard !intent.query.isEmpty else { ask("Which place would you like to go to?"); return }
                    query = intent.query
                }
            } catch {
                guard !Task.isCancelled else { return }
                // A service failure must never accept a pending route on the user's behalf.
                if pendingRoute != nil {
                    ask(followUpPrompt ?? "Is this the walk you wanted? Say yes or no.")
                    return
                }
                if let requestedCity, !DestinationResolver.hasQualifier(query) { query += " in \(requestedCity)" }
            }
        } else if let requestedCity, !DestinationResolver.hasQualifier(query) {
            query += " in \(requestedCity)"
        }
        if ["yes", "no", "maybe", "home", "work"].contains(reply) {
            ask("Which place or street address would you like to go to?"); return
        }
        pendingRoute = nil
        followUpPrompt = nil
        candidates = []
        guard let location = currentLocation, location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 100, abs(location.timestamp.timeIntervalSinceNow) < 30 else {
            requestLocation()
            ask("I need your location to find a nearby place. Allow location access, then try again.", listensForReply: false)
            return
        }
        do {
            let places = try await maps.search(query, near: location.coordinate)
            guard !Task.isCancelled else { return }
            isDemo = false
            switch DestinationResolver.resolve(request: query, candidates: places, from: location.coordinate) {
            case .go(let place):
                await route(to: place)
            case .choose(let places):
                candidates = places
                if places.isEmpty {
                    ask("I couldn't find that place. Can you give a name or street?")
                    return
                }
                stage = .choosing
                let options = places.prefix(3).map { place in
                    place.name + (place.streetAddress.map { " on \($0)" } ?? "")
                }.joined(separator: "; ")
                announce("Which location did you mean? \(options).", listensForReply: true)
            }
        } catch { fail(error) }
    }

    func select(_ place: PlaceCandidate) {
        work?.cancel()
        stopSpokenReply()
        recordingLimit?.cancel()
        recorder.cancel()
        stage = .searching
        work = Task { await route(to: place) }
    }

    private func ask(_ question: String, listensForReply: Bool = true) {
        displayedReply = ""
        followUpPrompt = question
        stage = .clarifying
        announce(question, listensForReply: listensForReply)
    }

    func confirmDestination() {
        work?.cancel()
        stopSpokenReply()
        recordingLimit?.cancel()
        recorder.cancel()
        stage = .searching
        work = Task { await confirmPendingRoute() }
    }

    func declineDestination() {
        work?.cancel()
        stopSpokenReply()
        recordingLimit?.cancel()
        recorder.cancel()
        pendingRoute = nil
        requestedCity = nil
        candidates = []
        // Schedule the announcement outside any cancelled search task.
        ask("Where would you like to go instead?")
    }

    private func confirmPendingRoute() async {
        guard let pending = pendingRoute else { return }
        guard let location = currentLocation, location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 100, abs(location.timestamp.timeIntervalSinceNow) < 30 else {
            ask("I need your current location before confirming this walk. Allow location access, then try again.", listensForReply: false)
            requestLocation()
            return
        }
        if Date().timeIntervalSince(pending.created) > 120 || location.distance(from: pending.origin) > 100 {
            // Recalculate and ask again when the facts behind the confirmation have changed.
            pendingRoute = nil
            await route(to: pending.place)
            return
        }
        showRoute(pending.plan, to: pending.place)
    }

    private func showRoute(_ plan: RoutePlan, to place: PlaceCandidate) {
        pendingRoute = nil
        followUpPrompt = nil
        requestedCity = nil
        candidates = []
        selectedPlace = place
            route = plan
            stage = .route
            locationManager.startUpdatingHeading()
        announce(NavigationSpeech.routeReady(for: place))
    }

    private func resolveOriginCity(at fix: CLLocation) async -> AppleMapsService.CityContext? {
        if let cached = originCityCache,
           (0...30).contains(Date().timeIntervalSince(cached.resolvedAt)),
           fix.distance(from: cached.fix) <= 100 {
            return cached.context
        }
        // Share one recent lookup between intent interpretation and route review, but
        // never carry a city indefinitely or reuse it after appreciable movement.
        guard let context = try? await maps.city(near: fix), !Task.isCancelled else { return nil }
        originCityCache = (context, fix, Date())
        return context
    }

    private func route(to place: PlaceCandidate) async {
        if place.isArea {
            requestedCity = place.name
            pendingRoute = nil
            candidates = []
            ask("Which place in \(place.name) would you like to go to?")
            return
        }
        guard let location = currentLocation, location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 100, abs(location.timestamp.timeIntervalSinceNow) < 30 else {
            requestLocation()
            ask("I need your location to plan this walk. Allow location access, then try again.", listensForReply: false)
            return
        }
        stage = .searching
        do {
            let originCity = await resolveOriginCity(at: location)
            try Task.checkCancellation()
            let plan = try await maps.walkingRoute(from: location.coordinate, to: place.coordinate, name: place.name)
            guard !Task.isCancelled else { return }
            if let prompt = WalkingRouteReview.prompt(destination: place, originCity: originCity?.name,
                                                     originCityAliases: originCity?.aliases ?? [], duration: plan.expectedTravelTime,
                                                     routeDistanceMeters: plan.checkpoints.last?.distanceFromStartMeters) {
                pendingRoute = (place, plan, location, Date())
                ask(prompt)
            } else { showRoute(plan, to: place) }
        } catch {
            guard !Task.isCancelled else { return }
            pendingRoute = nil
            ask("I couldn't get a walking route there. Which place would you like to try instead?")
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

    #if DEBUG
    func previewPointAI() {
        cancel()
        let place = PlaceCandidate(id: "voice-preview", name: "Shake Shack", address: "Preview only",
                                   coordinate: DemoRoute.coordinates.last!, city: "Providence")
        pendingRoute = (place, DemoRoute.plan, CLLocation(latitude: 42.363, longitude: -71.103), Date())
        ask("The walk to Shake Shack in Providence is about 1 hour, longer than 45 minutes. Are you sure you want to walk there?")
    }
    #endif

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
            try controller.start(route, at: isDemo ? nil : currentLocation)
            if isDemo { glove.connect() }
            journeyStarted = true
            if !isDemo {
                locationManager.allowsBackgroundLocationUpdates = true
                locationManager.showsBackgroundLocationIndicator = true
                locationManager.pausesLocationUpdatesAutomatically = false
            }
            if !isDemo, let currentLocation { controller.updateLocation(currentLocation) }
            if !isDemo, usePhoneAsGlove { startPhonePointing() }
            announce(isDemo ? "Demo started. Try the pointing control." : usePhoneAsGlove
                     ? "Phone pointing test started. Hold the screen down and point the camera end along your finger. Vibration gets stronger toward the beacon."
                     : "Navigation started. The glove is not connected yet.")
        } catch { fail(error) }
    }

    private func startPhonePointing() {
        requestLocation()
        phoneTester.start(session: controller.navigation)
        if phoneTester.running { locationManager.startUpdatingHeading() }
    }

    func pauseJourney() {
        guard journeyStarted, !isDemo, usePhoneAsGlove, journeyState == .navigating else { return }
        controller.navigation.pause()
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.stopUpdatingHeading()
        mapTelemetry.clearHeading()
        phoneTester.stop(status: "Paused · Resume to test pointing")
    }

    func resumeJourney() {
        guard journeyStarted, !isDemo, usePhoneAsGlove, journeyState == .paused else { return }
        controller.navigation.resume()
        locationManager.allowsBackgroundLocationUpdates = true
        startPhonePointing()
    }

    func setDemoAlignment(_ aligned: Bool) {
        guard isDemo, journeyStarted else { return }
        pointingAligned = aligned
        // Demo preview only; never presented as physical-device telemetry.
        if aligned { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    }

    func cancel() {
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.stopUpdatingHeading()
        mapTelemetry.clearHeading()
        phoneTester.stop()
        work?.cancel()
        recordingLimit?.cancel()
        stopSpokenReply()
        recorder.cancel()
        controller.stop()
        glove.disconnect()
        route = nil
        selectedPlace = nil
        pendingRoute = nil
        requestedCity = nil
        followUpPrompt = nil
        candidates = []
        transcript = ""
        journeyStarted = false
        activeBeaconIndex = nil
        pointingAligned = false
        demoInFlight = false
        isDemo = false
        stage = .home
        message = nil
    }

    func sceneInactive() {
        stopSpokenReply()
        if let followUpPrompt { displayedReply = followUpPrompt }
        if stage == .recording || demoInFlight { cancel() }
        else {
            locationManager.stopUpdatingHeading()
            mapTelemetry.clearHeading()
            phoneTester.stop(status: journeyState == .arrived ? "You’ve arrived" : journeyState == .navigating
                             ? "Route tracking continues · Unlock Point for vibration" : "Paused · Resume to test pointing")
        }
    }

    func sceneActive() {
        guard stage == .route, !isDemo else { return }
        if journeyStarted, journeyState == .navigating, usePhoneAsGlove {
            startPhonePointing()
        } else if !journeyStarted {
            locationManager.startUpdatingHeading()
        }
    }

    func openBeaconTest() {
        cancel()
    }

    func openDeviceSetup() {
        stopSpokenReply()
        if stage == .recording || stage == .searching { cancel() }
    }

    private func fail(_ error: Error) {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        message = error.localizedDescription
        // Permission failures and silence need an explicit retry, not a repeating microphone loop.
        ask(error.localizedDescription, listensForReply: false)
    }

    private func stopSpokenReply() {
        replyListeningTask?.cancel()
        replyListeningTask = nil
        voiceOverReply = nil
        spokenFeedback.stop()
    }

    private func listenAfterReply(expectedStage: Stage) {
        replyListeningTask?.cancel()
        replyListeningTask = Task { [weak self] in
            // Allow the speaker's short acoustic tail to settle before switching to input.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.stage == expectedStage,
                  UIApplication.shared.applicationState == .active else { return }
            self.startListening(automatically: true)
        }
    }

    private func announce(_ text: String, listensForReply: Bool = false) {
        stopSpokenReply()
        guard UIApplication.shared.applicationState == .active else { displayedReply = text; return }
        let expectedStage = stage
        let finished: () -> Void = { [weak self] in
            guard listensForReply, expectedStage == .clarifying || expectedStage == .choosing else { return }
            self?.listenAfterReply(expectedStage: expectedStage)
        }
        if UIAccessibility.isVoiceOverRunning {
            displayedReply = text
            voiceOverReply = (text, finished)
            UIAccessibility.post(notification: .announcement, argument: text)
        } else {
            spokenFeedback.speak(text, onFinished: finished)
        }
    }
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
