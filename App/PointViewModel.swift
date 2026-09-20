import AVFoundation
import Combine
import CoreLocation
import PointCore
import SwiftUI
import UIKit

@MainActor final class PointViewModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    enum Stage { case home, recording, searching, clarifying, choosing, journeyChoice, route, indoorDemo }
    enum VoicePhase { case idle, starting, listening, thinking, speaking }
    @Published private(set) var voicePhase: VoicePhase = .idle
    @Published private(set) var conversationActive = false
    private var voiceContext: Stage = .home
    private var replyStartTask: Task<Void, Never>?
    private var voiceGeneration = UUID()
    private var lastSpokenReply = ""
    var isListening: Bool { voicePhase == .listening }
    var voiceStatus: String {
        switch voicePhase {
        case .idle: return "Talk to Point"
        case .starting: return "Opening microphone"
        case .listening: return "Listening · Pause when you’re done"
        case .thinking: return "Thinking"
        case .speaking: return recorder.supportsInterruption && conversationActive ? "Point is speaking · You can interrupt" : "Point is speaking"
        }
    }
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
    @Published private(set) var journeyState: JourneyState = .idle
    @Published private(set) var activeBeaconIndex: Int?
    // Public transportation: walk → ride → walk, coordinated above the walking controller. There is
    // no mode switch: a short walk just walks, a long one asks "T or walk?", and the utterance can decide.
    static let offerTransitAboveMinutes = 10.0
    @Published private(set) var journeyCandidates: [JourneyPlan] = []
    @Published private(set) var journeyPlan: JourneyPlan?
    @Published private(set) var journeyPhase: JourneyCoordinator.Phase = .idle
    @Published private(set) var transitCountdown: JourneyCoordinator.Countdown?
    @Published private(set) var transitAlerts: [TransitAlert] = []
    @Published private(set) var awaitingSignal = false
    @Published private(set) var liveTransitData = true
    @Published private(set) var journeyReplanReason: String?
    private(set) var journey: JourneyCoordinator!
    private let transit: any TransitDataSource
    private var transitRequested = false
    private var walkingRequested = false
    /// The pending confirmation is "take transit instead?" rather than "is this the place?".
    @Published private(set) var pendingTransitOffer = false
    private var pendingJourneyPlace: PlaceCandidate?
    let mapTelemetry = RouteMapTelemetry()
    let recorder = VoiceRecorder()
    let glove = SimulatedGlove()
    let deviceConnection = DeviceConnection()
    @Published private(set) var gloveStatus = "Connect your glove in Device setup"
    private var gloveWatchdog: Task<Void, Never>?
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
    private var developmentVoiceConfiguration: VoiceConfiguration { Self.loadDevelopmentConfiguration() }

    private static func loadDevelopmentConfiguration() -> VoiceConfiguration {
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
        #if DEBUG
        transit = ProcessInfo.processInfo.arguments.contains("--preview-transit") ? TransitReviewDataSource() : MBTAClient(apiKey: Self.loadDevelopmentConfiguration().mbtaKey)
        #else
        transit = MBTAClient(apiKey: Self.loadDevelopmentConfiguration().mbtaKey)
        #endif
        super.init()
        controller = PointController(glove: deviceConnection.glove)
        deviceConnection.glove.onHeadingChange = { [weak self] reading in
            if let reading { self?.mapTelemetry.receive(reading) }
            else { self?.mapTelemetry.clearHeading() }
        }
        controller.$feedback.sink { [weak self] feedback in
            guard let self, !isDemo else { return }
            if pointingAligned != feedback.shouldConfirm { pointingAligned = feedback.shouldConfirm }
            let status: String
            switch feedback.status {
            case .aligned: status = "You're pointing the right way"
            case .checking: status = "Hold your pointing direction"
            case .offDirection: status = "Point toward the next beacon"
            case .calibrationRequired: status = "Glove needs a north reference"
            case .headingUnavailable: status = deviceConnection.glove.message ?? "Waiting for a fresh glove heading"
            case .locationUnavailable: status = feedback.locationIssue?.message ?? "Waiting for GPS"
            case .rerouteRequired: status = "Off route · Check the map before continuing"
            case .disconnected: status = "Glove guidance unavailable · Check Device setup"
            case .inactive: status = "Glove guidance paused"
            }
            if gloveStatus != status { gloveStatus = status }
        }.store(in: &subscriptions)
        journey = JourneyCoordinator(controller: controller, transit: transit)
        journey.onEvent = { [weak self] event in self?.handle(journeyEvent: event) }
        journey.$phase.sink { [weak self] in self?.journeyPhase = $0 }.store(in: &subscriptions)
        journey.$countdown.sink { [weak self] in self?.transitCountdown = $0 }.store(in: &subscriptions)
        journey.$alerts.sink { [weak self] in self?.transitAlerts = $0 }.store(in: &subscriptions)
        journey.$awaitingSignal.sink { [weak self] in self?.awaitingSignal = $0 }.store(in: &subscriptions)
        journey.$liveDataAvailable.sink { [weak self] in self?.liveTransitData = $0 }.store(in: &subscriptions)
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        // Paired magnetic/true readings provide declination only; pointing is glove-owned.
        locationManager.headingOrientation = .portrait
        locationManager.headingFilter = kCLHeadingFilterNone
        locationManager.activityType = .fitness
        controller.navigation.$state.sink { [weak self] state in
            guard let self else { return }
            journeyState = state
            // A transit journey's walking legs also "arrive" at each stop; the coordinator owns that.
            if state == .arrived, journeyPlan == nil { finishArrival() }
        }.store(in: &subscriptions)
        controller.navigation.$beaconIndex.sink { [weak self] index in
            self?.activeBeaconIndex = index
        }.store(in: &subscriptions)
        // Words appear as they are spoken; the final transcript replaces them after finishing.
        recorder.$liveTranscript.sink { [weak self] text in
            guard let self, voicePhase == .listening else { return }
            transcript = text
        }.store(in: &subscriptions)
        recorder.$endpoint.sink { [weak self] endpoint in
            guard let self, voicePhase == .listening, !isDemo else { return }
            switch endpoint {
            case .listening: break
            case .finished: finishRecording()
            case .noSpeech:
                endConversation()
                announce("I’ll pause here. Tap to talk again.")
            }
        }.store(in: &subscriptions)
        recorder.onInterruption = { [weak self] in
            guard let self, self.conversationActive, self.voicePhase == .speaking else { return }
            self.spokenFeedback.stop()
            self.replyListeningTask?.cancel()
            self.voicePhase = .listening
            self.transcript = ""
            self.beginListeningState()
        }
        // VoiceOver owns spoken announcements when active, avoiding two voices at once.
        NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.endConversation() }.store(in: &subscriptions)
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
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                self?.endConversation()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.endConversation() }.store(in: &subscriptions)
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
        if (manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways) {
            manager.startUpdatingLocation()
        } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            currentLocation = nil
            pauseJourney()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Use the difference of one paired reading, never the phone's direction as
        // the glove's direction. Only refresh the local correction with a fresh fix.
        let now = Date()
        if let location = currentLocation,
           CLLocationCoordinate2DIsValid(location.coordinate),
           (0...25).contains(location.horizontalAccuracy),
           (0...5).contains(now.timeIntervalSince(location.timestamp)),
           (0...5).contains(now.timeIntervalSince(newHeading.timestamp)) {
            deviceConnection.glove.northCorrection = MagneticNorthCorrection(
                trueHeading: newHeading.trueHeading, magneticHeading: newHeading.magneticHeading,
                accuracy: newHeading.headingAccuracy, timestamp: newHeading.timestamp)
        } else { deviceConnection.glove.northCorrection = nil }
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        deviceConnection.isConnected
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !isDemo, let location = locations.last else { return }
        currentLocation = location
        guard stage != .indoorDemo else { return }
        let previouslyOffRoute = controller.navigation.rerouteRequired
        let arrival = controller.updateLocation(location)
        if journeyPlan != nil { journey.updateLocation(location) }
        pointingAligned = controller.feedback.shouldConfirm
        if journeyStarted, let arrival {
            // On a transit journey the coordinator announces stops and the final arrival itself.
            if journeyPlan == nil || !arrival.isDestination {
                announce(arrival.isDestination ? "You've arrived at \(selectedPlace?.name ?? "your destination")."
                         : "Beacon \(arrival.index + 1) reached. Point toward beacon \(arrival.index + 2).")
            }
        } else if journeyStarted, !previouslyOffRoute, controller.navigation.rerouteRequired {
            announce("You seem to be off the route. Check the map before continuing.")
        }
    }

    func microphone() {
        startListening(automatically: false)
    }

    private func startListening(automatically: Bool) {
        guard !demoInFlight, UIApplication.shared.applicationState == .active else { return }
        if voicePhase == .listening { finishRecording(); return }
        work?.cancel()
        let context = stage == .recording || stage == .searching ? voiceContext : stage
        stopSpokenReply()
        conversationActive = true
        voiceContext = context
        transcript = ""
        voicePhase = .starting
        let generation = voiceGeneration
        replyStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await recorder.start()
                guard !Task.isCancelled, voiceGeneration == generation,
                      UIApplication.shared.applicationState == .active else { return }
                voicePhase = .listening
                beginListeningState()
                recorder.playListeningCue()
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            } catch {
                guard voiceGeneration == generation, !Task.isCancelled else { return }
                conversationActive = false
                voicePhase = .idle
                fail(error)
            }
        }
    }

    private func beginListeningState() {
        if stage == .home || stage == .clarifying || stage == .recording || stage == .searching { stage = .recording }
        recordingLimit?.cancel()
        recordingLimit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, self.voicePhase == .listening else { return }
            if self.transcript.isEmpty { self.endConversation() }
            else { self.finishRecording() }
        }
    }

    func endConversation() {
        conversationActive = false
        stopSpokenReply()
        if stage == .recording || stage == .searching {
            work?.cancel()
            stage = followUpPrompt == nil ? .home : .clarifying
        }
    }

    private func finishRecording() {
        guard voicePhase == .listening else { return }
        recordingLimit?.cancel()
        voicePhase = .thinking
        if stage != .route && stage != .journeyChoice && stage != .choosing { stage = .searching }
        work = Task {
            do {
                let recording = try await recorder.finish()
                guard !Task.isCancelled else { return }
                // Use the live transcript immediately. Batch transcription is a fallback when
                // Apple Speech produced no words, avoiding an extra network wait on every turn.
                var text = recording.transcript
                let configuration = developmentVoiceConfiguration
                if text.isEmpty, let key = configuration.openAIKey {
                    do { text = try await OpenAITranscriber(model: configuration.transcriptionModel,
                                                           authorization: { "Bearer \(key)" }).transcribe(audio: recording.audio) }
                    catch { if text.isEmpty { throw error } }
                }
                guard !Task.isCancelled else { return }
                guard !text.isEmpty else { throw ServiceError.emptyTranscript }
                transcript = text
                speechPlayer.conversationEngine = nil
                voicePhase = .idle
                await search(text)
            } catch { fail(error) }
        }
    }

    func searchTyped(_ text: String) {
        conversationActive = false
        work?.cancel()
        recordingLimit?.cancel()
        stopSpokenReply()
        recorder.cancel()
        transcript = text
        stage = .searching
        work = Task { await search(text) }
    }

    func prepareTypedReply() {
        conversationActive = false
        work?.cancel()
        recordingLimit?.cancel()
        stopSpokenReply()
        recorder.cancel()
        stage = followUpPrompt == nil ? .home : .clarifying
    }

    private func search(_ text: String) async {
        guard !Task.isCancelled else { return }
        if await handleConversationCommand(text) { return }
        if IndoorDemoCommand.matches(text) { enterIndoorDemo(); return }
        let reply = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if ["cancel", "never mind", "nevermind", "stop"].contains(reply) { cancel(); return }
        // "Take the T to…" plans transit; "walk me to…" skips the transit offer.
        if TransitPhrases.impliesTransit(text) { transitRequested = true; walkingRequested = false }
        else if TransitPhrases.impliesWalking(text) { walkingRequested = true; transitRequested = false }
        if pendingRoute != nil {
            // Answering the "T or walk?" offer: any transit or walking phrase is a complete answer.
            if pendingTransitOffer, TransitPhrases.impliesTransit(text) { await confirmPendingRoute(); return }
            if pendingTransitOffer, TransitPhrases.impliesWalking(text) { declineDestination(); return }
            if ["yes", "yeah", "yep", "sure", "correct", "that's right", "that is correct", "transit", "the t", "train", "bus"].contains(reply) {
                await confirmPendingRoute(); return
            }
            if ["no", "nope", "not right", "that's wrong", "walk", "i'll walk", "walking"].contains(reply) { declineDestination(); return }
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
        if !listensForReply { conversationActive = false }
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
        if pendingTransitOffer, let pending = pendingRoute {
            // "No" to the transit offer means walk.
            pendingTransitOffer = false
            showRoute(pending.plan, to: pending.place)
            return
        }
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
        if pendingTransitOffer {
            // "Yes" to the transit offer.
            pendingTransitOffer = false
            pendingRoute = nil
            stage = .searching
            await planJourney(to: pending.place, from: location)
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
        pendingTransitOffer = false
        pendingRoute = nil
        followUpPrompt = nil
        requestedCity = nil
        candidates = []
        selectedPlace = place
            route = plan
            stage = .route
            locationManager.startUpdatingHeading()
        announce(NavigationSpeech.routeReady(for: place, handsFree: conversationActive))
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
        if transitRequested {
            await planJourney(to: place, from: location)
            return
        }
        do {
            let originCity = await resolveOriginCity(at: location)
            try Task.checkCancellation()
            let plan = try await maps.walkingRoute(from: location.coordinate, to: place.coordinate, name: place.name)
            guard !Task.isCancelled else { return }
            // Reverse-geocode the destination the same way as the origin, so a place in the city
            // you are standing in never asks "are you sure" because of a neighbourhood label.
            let destinationCity = try? await maps.city(near: CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude))
            guard !Task.isCancelled else { return }
            let review = WalkingRouteReview.prompt(destination: place, originCity: originCity?.name,
                                                   originCityAliases: originCity?.aliases ?? [], duration: plan.expectedTravelTime,
                                                   routeDistanceMeters: plan.checkpoints.last?.distanceFromStartMeters,
                                                   destinationCityAliases: [destinationCity?.name].compactMap { $0 } + (destinationCity?.aliases ?? []))
            let minutes = plan.expectedTravelTime.map { Int(ceil($0 / 60)) }
            if !walkingRequested, let minutes, Double(minutes) > Self.offerTransitAboveMinutes {
                // Far enough for the T or a bus: ask, and let "yes"/"no" or a transit/walk phrase answer.
                pendingRoute = (place, plan, location, Date())
                pendingTransitOffer = true
                let city = review?.contains("is in") == true ? " in \(place.city ?? "")" : ""
                ask("\(place.name)\(city) is about a \(minutes) minute walk. Want to take the T or a bus instead? Say yes for transit, or no to walk.")
            } else if let review {
                pendingRoute = (place, plan, location, Date())
                ask(review)
            } else { showRoute(plan, to: place) }
        } catch {
            guard !Task.isCancelled else { return }
            pendingRoute = nil
            ask("I couldn't get a walking route there. Which place would you like to try instead?")
        }
    }

    // MARK: Public transportation

    private func planJourney(to place: PlaceCandidate, from location: CLLocation) async {
        do {
            var options = TransitPlanner.Options()
            if transitRequested { options.walkOnlyBelowMeters = 0 } // Asked for the T or a bus: try, even for a short hop.
            let plans = try await TransitPlanner.plan(from: location.coordinate, to: place.coordinate, destinationName: place.name,
                                                      walking: maps, transit: transit, options: options)
            guard !Task.isCancelled else { return }
            if plans.count == 1, plans[0].isWalkingOnly, let walk = plans[0].firstWalk {
                showRoute(walk, to: place)
                announce(transitRequested ? "I couldn't find a bus or train for that trip, so here's the walk. \(NavigationSpeech.routeReady(for: place, handsFree: conversationActive))"
                         : "That's close enough to walk. \(NavigationSpeech.routeReady(for: place, handsFree: conversationActive))")
                return
            }
            journeyCandidates = plans
            pendingJourneyPlace = place
            pendingRoute = nil
            followUpPrompt = nil
            candidates = []
            stage = .journeyChoice
            announce("Here's a route by transit. \(plans[0].summary) Say first, second, or third to choose a route.")
        } catch {
            guard !Task.isCancelled else { return }
            ask("I couldn't plan a transit trip there. Which place would you like to try instead?")
        }
    }

    func selectJourney(_ plan: JourneyPlan) {
        guard let place = pendingJourneyPlace, let walk = plan.firstWalk else { return }
        work?.cancel()
        stopSpokenReply()
        journeyCandidates = []
        journeyPlan = plan
        journeyReplanReason = nil
        pendingRoute = nil
        followUpPrompt = nil
        requestedCity = nil
        candidates = []
        selectedPlace = place
        route = walk
        stage = .route
        locationManager.startUpdatingHeading()
        announce("Transit route ready. \(plan.summary) Say start when you’re ready.")
    }

    var isWalkingLeg: Bool { if case .walking = journeyPhase { return true } else { return false } }

    var currentRideIsBus: Bool {
        guard let plan = journeyPlan, let index = journeyPhase.legIndex,
              plan.legs.indices.contains(index), case .ride(let ride) = plan.legs[index] else { return false }
        return ride.route.isBus
    }

    /// Plain-language state for the route panel and VoiceOver.
    var journeyStatusText: String {
        guard let journeyPlan else { return "" }
        func ride(_ leg: Int) -> RideLeg? { if case .ride(let ride) = journeyPlan.legs[leg] { return ride } else { return nil } }
        switch journeyPhase {
        case .idle: return "Ready"
        case .walking(let leg):
            if awaitingSignal { return "Head for the exit · Directions resume when GPS returns" }
            var text = "Walking"
            if case .walk(let walk) = journeyPlan.legs[leg] { text = "Walk to \(walk.destinationName)" }
            if let countdown = transitCountdown { text += " · \(countdown.routeName) \(Self.departures(countdown))" }
            return text
        case .waitingAtStop(let leg):
            guard let ride = ride(leg) else { return "Waiting" }
            if !liveTransitData { return "At \(ride.board.name) · No signal for live arrivals" }
            if let countdown = transitCountdown {
                return "\(ride.route.name) toward \(countdown.headsign) \(Self.departures(countdown))"
            }
            return "At \(ride.board.name) · Waiting for the \(ride.route.name)"
        case .vehicleArriving(let leg, _):
            guard let ride = ride(leg) else { return "Arriving" }
            return "\(ride.route.name) toward \(ride.headsign) is here · Board now"
        case .riding(let leg, let trip, let confirmed, let tracking):
            guard let ride = ride(leg) else { return "Riding" }
            if tracking == .lost { return "\(trip == nil ? "Live tracking unavailable" : "Live tracking lost") · Get off at \(ride.alight.name)" }
            return confirmed ? "Riding \(ride.route.name) · Get off at \(ride.alight.name)" : "Did you board the \(ride.route.name)?"
        case .alighting(let leg, _):
            return "Get off here at \(ride(leg)?.alight.name ?? "this stop")"
        case .needsReplan(let reason): return reason
        case .arrived: return "You've arrived"
        }
    }

    /// "now, then 8 and 14 min" — the first departure plus the next two.
    static func departures(_ countdown: JourneyCoordinator.Countdown) -> String {
        func minutes(_ seconds: Int) -> String { seconds < 60 ? "now" : "\(seconds / 60) min" }
        let first = countdown.status ?? countdown.secondsAway.map { $0 < 60 ? "now" : "in \($0 / 60) min" } ?? ""
        let rest = countdown.following.map(minutes)
        switch rest.count {
        case 0: return first
        case 1: return "\(first), then \(rest[0])"
        default: return "\(first), then \(rest[0]) and \(rest[1])"
        }
    }

    func confirmAtStop() { journey.confirmAtStop() }
    func confirmBoarded() { journey.confirmBoarded() }
    func notOnBoard() { journey.notOnBoard() }
    func confirmAlighted() { journey.confirmAlighted() }

    func replanJourney() {
        guard let place = selectedPlace, let location = currentLocation else { return }
        journey.stop()
        journeyPlan = nil
        journeyReplanReason = nil
        journeyStarted = false
        stage = .searching
        work?.cancel()
        work = Task { await planJourney(to: place, from: location) }
    }

    private func handle(journeyEvent event: JourneyCoordinator.Event) {
        guard let journeyPlan else { return }
        switch event {
        case .walkingLegStarted(let leg, let toward):
            if case .walk(let walk) = journeyPlan.legs[leg] { route = walk }
            guard leg > 0 else { return }
            if !awaitingSignal { announce("Now walk to \(toward). Point with your glove to feel the direction.") }
        case .reachedStop(let ride):
            announce("You're at \(ride.board.name). Wait for the \(ride.route.name) toward \(ride.headsign). I'll buzz when it arrives.")
        case .vehicleArriving(let ride):
            if isWalkingLeg { announce("\(ride.route.name) toward \(ride.headsign) is arriving at \(ride.board.name).") }
            else { announce("Your \(ride.route.name) toward \(ride.headsign) is here. Board now.") }
        case .departedTentatively:
            announce("If you boarded, say I’m on board. Otherwise, say not on board.")
        case .boarded(let ride):
            let stops = ride.stopsRidden == 1 ? "one stop" : "\(ride.stopsRidden) stops"
            announce("On the \(ride.route.name). \(stops) to \(ride.alight.name). I'll tell you when to get off.")
        case .notOnBoard(let ride):
            announce("Okay. Waiting for the next \(ride.route.name).")
        case .nextStopIsYours(let ride):
            announce("Next stop is \(ride.alight.name). Get ready.")
        case .alightHere(let ride):
            announce("Get off here at \(ride.alight.name).")
        case .alighted: break
        case .trackingLost(let ride):
            announce("Live tracking isn't available. Say I’m off when you reach \(ride.alight.name).")
        case .awaitingSignal:
            announce("Head for the exit. Directions resume once GPS returns.")
        case .signalRestored(let leg):
            let toward: String = { if case .walk(let walk) = journeyPlan.legs[leg] { return walk.destinationName } else { return "your destination" } }()
            announce("GPS is back. Walk to \(toward).")
        case .liveDataLost:
            announce("No signal for live arrivals. Listen for your ride; I'll update when signal returns.")
        case .liveDataRestored:
            announce("Live arrivals are back.")
        case .notice(let text):
            announce(text)
        case .needsReplan(let reason):
            journeyReplanReason = reason
            announce("\(reason) Say replan to plan again from here.")
        case .arrived:
            finishArrival()
            announce("You've arrived at \(journeyPlan.destinationName).")
        }
    }

    private func finishArrival() {
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.stopUpdatingHeading()
        mapTelemetry.clearHeading()
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

    #if DEBUG
    /// Physical-device regression for the Send/cancel audio-graph crash. Does not
    /// call transcription/search services or retain microphone audio/transcripts.
    func verifyVoiceAudioLifecycle() async {
        let capture = VoiceRecorder()
        let player = PhoneSpeechPlayer()
        player.conversationEngine = capture.audioEngine
        let report = URL.documentsDirectory.appending(path: "voice-audio-check.txt")
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("voice-check.caf")
        var lines: [String] = []
        func record(_ line: String) {
            lines.append(line)
            try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
        }
        defer { player.stop(); capture.cancel(); try? FileManager.default.removeItem(at: fixture) }
        record("START build 8")
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9600)!
            buffer.frameLength = 9600
            for i in 0..<9600 { buffer.floatChannelData![0][i] = 0 }
            do {
                let file = try AVAudioFile(forWriting: fixture, settings: format.settings)
                try file.write(from: buffer)
            }
            let audio = SpeechAudio(data: try Data(contentsOf: fixture), text: "Audio lifecycle check")
            for cycle in 1...3 {
                record("Cycle \(cycle): starting microphone")
                try await capture.start()
                record("Cycle \(cycle): microphone started")
                capture.playListeningCue()
                try await Task.sleep(for: .milliseconds(150))
                capture.playListeningCue()
                try await Task.sleep(for: .milliseconds(150))
                try player.play(audio, progress: { _ in }, completion: { _ in })
                player.stop()
                try player.play(audio, progress: { _ in }, completion: { _ in })
                try await Task.sleep(for: .milliseconds(500))
                record("Cycle \(cycle): reply finished, engine running = \(capture.audioEngine.isRunning)")
                guard capture.audioEngine.isRunning else { throw RecorderError.couldNotRecord }
                let recording = try await capture.finish()
                record("Cycle \(cycle): recording finished (\(recording.audio.count) bytes)")
                guard !recording.audio.isEmpty else { throw RecorderError.couldNotRecord }
                capture.cancel(); capture.cancel()
                record("PASS cycle \(cycle): repeated cue, reply stop/replay, finish, repeated cancel")
            }
            record("PASS all audio lifecycle checks")
            message = "Voice audio check passed."
        } catch { record("FAIL \(error.localizedDescription)"); message = "Voice audio check failed." }
    }
    #endif

    func preview() { playVoiceDemo() }

    #if DEBUG
    func previewTransit() {
        cancel()
        currentLocation = CLLocation(coordinate: TransitReviewFixtures.origin, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
        pendingJourneyPlace = PlaceCandidate(id: "review-destination", name: "Nubian Station", address: "Sample journey · Simulated arrivals",
                                            coordinate: TransitReviewFixtures.destination)
        journeyCandidates = [TransitReviewFixtures.plan]
        transcript = "Sample bus journey · UI review"
        stage = .journeyChoice
    }

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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-transit"), let journeyPlan {
            do { try journey.start(journeyPlan, at: currentLocation); journeyStarted = true }
            catch { fail(error) }
            return
        }
        #endif
        controller.setOutputEnabled(true)
        controller.useTransport(isDemo ? glove : deviceConnection.glove)
        startGloveWatchdog()
        if let journeyPlan {
            do {
                try journey.start(journeyPlan, at: currentLocation)
                journeyStarted = true
                locationManager.allowsBackgroundLocationUpdates = true
                locationManager.showsBackgroundLocationIndicator = true
                locationManager.pausesLocationUpdatesAutomatically = false
                if let currentLocation { controller.updateLocation(currentLocation); journey.updateLocation(currentLocation) }
                let first = journeyPlan.rides.first.map { "Walk to \($0.board.name) first." } ?? ""
                announce("Trip started. \(first) Point with your glove to feel the direction.")
            } catch { fail(error) }
            return
        }
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
            announce(isDemo ? "Demo started. Try the pointing control." : "Navigation started. \(deviceConnection.firmwareMessage).")
        } catch { fail(error) }
    }

    private func startGloveWatchdog() {
        gloveWatchdog?.cancel()
        guard !isDemo else { return }
        // Needed for local declination even though pointing comes from the glove.
        locationManager.startUpdatingHeading()
        gloveWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                self?.controller.tick()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    func pauseJourney() {
        guard journeyStarted, !isDemo, journeyState == .navigating else { return }
        controller.navigation.pause()
        controller.tick()
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.stopUpdatingHeading()
        mapTelemetry.clearHeading()
    }

    func resumeJourney() {
        guard journeyStarted, !isDemo, journeyState == .paused else { return }
        controller.navigation.resume()
        locationManager.allowsBackgroundLocationUpdates = true
        startGloveWatchdog(); controller.tick()
    }

    func setDemoAlignment(_ aligned: Bool) {
        guard isDemo, journeyStarted else { return }
        pointingAligned = aligned
        // Demo preview only; never presented as physical-device telemetry.
        if aligned { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    }

    func cancel() {
        conversationActive = false
        gloveWatchdog?.cancel()
        gloveWatchdog = nil
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.stopUpdatingHeading()
        mapTelemetry.clearHeading()
        work?.cancel()
        recordingLimit?.cancel()
        stopSpokenReply()
        recorder.cancel()
        journey.stop()
        journeyPlan = nil
        journeyCandidates = []
        journeyReplanReason = nil
        pendingJourneyPlace = nil
        transitRequested = false
        walkingRequested = false
        pendingTransitOffer = false
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
        if stage == .indoorDemo, deviceConnection.keepsDemoRunningInBackground { return }
        endConversation()
        deviceConnection.glove.northCorrection = nil
        gloveWatchdog?.cancel()
        gloveWatchdog = nil
        controller.setOutputEnabled(false)
        stopSpokenReply()
        if let followUpPrompt { displayedReply = followUpPrompt }
        if stage == .recording || demoInFlight { cancel() }
        else {
            locationManager.stopUpdatingHeading()
            mapTelemetry.clearHeading()
        }
    }

    func sceneActive() {
        controller.setOutputEnabled(true)
        requestLocation()
        locationManager.startUpdatingHeading()
        if stage == .route, !isDemo {
            if journeyStarted { startGloveWatchdog() }
            if journeyPlan != nil { journey.tick() }
        }
    }

    func enterIndoorDemo() {
        // End any walk/transit plan and pending confirmations before switching coordinate systems.
        cancel()
        requestLocation()
        locationManager.startUpdatingHeading()
        stage = .indoorDemo
    }

    func leaveIndoorDemo() {
        guard stage == .indoorDemo else { return }
        cancel()
    }

    func indoorDemoInstruction(_ text: String) {
        guard stage == .indoorDemo else { return }
        announce(text)
    }

    func openDeviceSetup() {
        stopSpokenReply()
        if stage == .recording || stage == .searching { cancel() }
        requestLocation()
        locationManager.startUpdatingHeading()
    }

    private func fail(_ error: Error) {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        message = error.localizedDescription
        // Permission failures and silence need an explicit retry, not a repeating microphone loop.
        ask(error.localizedDescription, listensForReply: false)
    }

    private func stopSpokenReply() {
        voiceGeneration = UUID()
        replyStartTask?.cancel()
        replyStartTask = nil
        replyListeningTask?.cancel()
        replyListeningTask = nil
        recordingLimit?.cancel()
        voiceOverReply = nil
        spokenFeedback.stop()
        recorder.cancel()
        speechPlayer.conversationEngine = nil
        voicePhase = .idle
    }

    private func listenAfterReply(expectedStage: Stage) {
        guard stage == expectedStage, UIApplication.shared.applicationState == .active else { return }
        startListening(automatically: true)
    }

    private func announce(_ text: String, listensForReply: Bool = false) {
        stopSpokenReply()
        lastSpokenReply = text
        guard UIApplication.shared.applicationState == .active else { displayedReply = text; return }
        let expectedStage = stage
        let generation = voiceGeneration
        let conversational = (conversationActive || listensForReply) && stage != .indoorDemo && !isDemo
        let finished: () -> Void = { [weak self] in
            guard let self, self.voiceGeneration == generation else { return }
            self.replyListeningTask?.cancel()
            if conversational, self.recorder.isRecording {
                self.voicePhase = .listening
                self.recorder.assistantFinished()
                self.beginListeningState()
            } else { self.voicePhase = .idle }
        }
        if conversational {
            conversationActive = true
            voiceContext = expectedStage
            voicePhase = .starting
            replyStartTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await recorder.start(whileReplyingTo: text)
                    guard !Task.isCancelled, voiceGeneration == generation else { return }
                    speechPlayer.conversationEngine = recorder.audioEngine
                } catch {
                    guard !Task.isCancelled, voiceGeneration == generation else { return }
                    conversationActive = false
                    recorder.cancel()
                    speechPlayer.conversationEngine = nil
                }
                voicePhase = .speaking
                replyListeningTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(45))
                    guard !Task.isCancelled, let self, self.voiceGeneration == generation,
                          self.voicePhase == .speaking else { return }
                    self.spokenFeedback.stop()
                    self.displayedReply = text
                    finished()
                }
                // In a conversation Point owns its voice, including with VoiceOver enabled,
                // so it can stop immediately. Don't duplicate it with an accessibility announcement.
                spokenFeedback.speak(text, onFailed: { [weak self] in
                    guard let self, self.voiceGeneration == generation else { return }
                    self.displayedReply = text
                    finished()
                }, onFinished: finished)
            }
        } else if UIAccessibility.isVoiceOverRunning {
            displayedReply = text
            voicePhase = .speaking
            voiceOverReply = (text, finished)
            UIAccessibility.post(notification: .announcement, argument: text)
        } else {
            voicePhase = .speaking
            spokenFeedback.speak(text, onFailed: finished, onFinished: finished)
        }
    }

    private func handleConversationCommand(_ text: String) async -> Bool {
        if let command = ConversationCommand.parse(text) {
            switch command {
            case .endConversation: endConversation(); return true
            case .cancelRoute: cancel(); return true
            case .repeatReply:
                announce(lastSpokenReply.isEmpty ? "Say a destination, or ask for demo mode." : lastSpokenReply, listensForReply: true)
                return true
            case .start where stage == .route && !journeyStarted: startJourney(); return true
            case .pause where stage == .route && journeyStarted && journeyState == .navigating:
                pauseJourney(); announce("Route paused. Say resume when you’re ready."); return true
            case .resume where stage == .route && journeyState == .paused:
                resumeJourney(); announce("Resuming your route."); return true
            case .atStop where stage == .route:
                if case .walking(let leg) = journeyPhase, let plan = journeyPlan,
                   plan.legs.dropFirst(leg + 1).contains(where: { if case .ride = $0 { return true }; return false }) {
                    confirmAtStop(); return true
                }
            case .boarded where stage == .route:
                switch journeyPhase {
                case .waitingAtStop, .vehicleArriving, .riding(_, _, false, _): confirmBoarded(); return true
                default: break
                }
            case .notBoarded where stage == .route:
                if case .riding(_, _, false, _) = journeyPhase { notOnBoard(); return true }
            case .alighted where stage == .route:
                switch journeyPhase { case .riding, .alighting: confirmAlighted(); return true; default: break }
            case .replan where stage == .route: replanJourney(); return true
            default: break
            }
            announce("That action isn’t available here. Say a destination, or say stop listening.", listensForReply: true)
            return true
        }
        let choice = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let indices = ["first": 0, "the first one": 0, "one": 0, "second": 1, "the second one": 1, "two": 1, "third": 2, "the third one": 2, "three": 2]
        if stage == .journeyChoice {
            let index = indices[choice] ?? (["yes", "that one", "take it"].contains(choice) ? 0 : -1)
            if journeyCandidates.indices.contains(index) { selectJourney(journeyCandidates[index]); return true }
        }
        if stage == .choosing, let index = indices[choice], candidates.indices.contains(index) {
            await route(to: candidates[index]); return true
        }
        return false
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
