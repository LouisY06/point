import AVFoundation
import Combine
import CoreLocation
import PointCore
import SwiftUI
import UIKit

@MainActor final class PointViewModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    /// `armed`: the hand was tapped and the talk panel is up, but the microphone opens only while the panel is held.
    enum Stage { case home, armed, recording, searching, clarifying, choosing, journeyChoice, route, indoorDemo }
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
    enum RouteReplyState { case idle, listening, processing }
    @Published private(set) var routeReplyState: RouteReplyState = .idle
    @Published private(set) var routeStartMessage = ""
    private var routeStartID: UUID?
    private var recordingRouteID: UUID?
    var awaitingRouteStart: Bool { routeStartID != nil && routeStartID == route?.id && !journeyStarted }
    private var listening: Bool { stage == .recording || routeReplyState == .listening }
    @Published var pointingAligned = false
    @Published var demoInFlight = false
    @Published var currentLocation: CLLocation?
    @Published private(set) var journeyState: JourneyState = .idle
    @Published private(set) var activeBeaconIndex: Int?
    // Public transportation: walk → ride → walk, coordinated above the walking controller. There is
    // no mode switch: a short walk just walks, a long one asks "T or walk?", and the utterance can decide.
    static let offerTransitAboveMinutes = 10.0
    @Published private(set) var journeyCandidates: [JourneyPlan] = []
    /// Push to talk: the finger is on the microphone, and the current capture ends on release, not on a pause.
    private var microphoneHeld = false
    private var holdToTalkActive = false
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
    private var northReference = MagneticNorthCorrectionCache()
    #if DEBUG
    private var lastPhoneHeading: CLHeading?
    private var lastNorthDiagnostic = Date.distantPast
    private let northDiagnosticQueue = DispatchQueue(label: "point.north-diagnostics", qos: .utility)
    #endif
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
        guard let configuration = self?.developmentVoiceConfiguration else { return nil }
        guard configuration.deepgramKey != nil else { return nil }
        return DeepgramSpeech(configuration: configuration)
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
        deviceConnection.$phase.receive(on: RunLoop.main).sink { [weak self] phase in
            if phase == .connected { self?.refreshNorthCorrection() }
        }.store(in: &subscriptions)
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
            guard let self, listening else { return }
            transcript = text
        }.store(in: &subscriptions)
        recorder.$endpoint.sink { [weak self] endpoint in
            // Holding the microphone decides the end; pauses mid-sentence are the rider's to take.
            guard let self, listening, !isDemo, !holdToTalkActive else { return }
            switch endpoint {
            case .listening: break
            case .finished: finishRecording()
            case .noSpeech:
                if recordingRouteID != nil { deferRouteStart(announceReply: false); return }
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
        guard stage != .indoorDemo else { return }
        locationManager.requestWhenInUseAuthorization()
        if locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways {
            locationManager.startUpdatingLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if (manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways), stage != .indoorDemo {
            manager.startUpdatingLocation()
        } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            currentLocation = nil
            northReference.clear()
            deviceConnection.glove.northCorrection = nil
            pauseJourney()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        #if DEBUG
        lastPhoneHeading = newHeading
        #endif
        guard stage != .indoorDemo else { return }
        // Phone rotation cancels in this paired difference. Keep a valid local
        // reference through temporary GPS/compass noise instead of starting over.
        let now = Date()
        northReference.update(trueHeading: newHeading.trueHeading, magneticHeading: newHeading.magneticHeading,
                              accuracy: newHeading.headingAccuracy, timestamp: newHeading.timestamp,
                              location: currentLocation, now: now)
        refreshNorthCorrection(now: now)
    }

    private func refreshNorthCorrection(now: Date = Date()) {
        #if DEBUG
        defer { recordNorthDiagnostics(now: now) }
        #endif
        let authorized = locationManager.authorizationStatus == .authorizedWhenInUse
            || locationManager.authorizationStatus == .authorizedAlways
        guard authorized, stage != .indoorDemo else {
            deviceConnection.glove.northCorrection = nil
            return
        }
        deviceConnection.glove.northCorrection = northReference.correction(at: currentLocation, now: now)
    }

    #if DEBUG
    /// A local snapshot for connected-device troubleshooting; no coordinates, destinations or credentials.
    private func recordNorthDiagnostics(now: Date) {
        guard now.timeIntervalSince(lastNorthDiagnostic) >= 2 else { return }
        lastNorthDiagnostic = now
        func number(_ value: Double?) -> Any {
            guard let value, value.isFinite else { return NSNull() }
            return value
        }
        let glove = deviceConnection.glove
        let correction = glove.northCorrection
        let snapshot: [String: Any] = [
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "timestamp": now.timeIntervalSince1970,
            "stage": String(describing: stage),
            "journeyStarted": journeyStarted,
            "transitLeg": journeyPhase.legIndex as Any? ?? NSNull(),
            "transitWalking": { if case .walking = journeyPhase { return true }; return false }(),
            "transitAwaitingSignal": awaitingSignal,
            "navigationState": controller.navigation.state.rawValue,
            "gloveConnection": controller.connection.rawValue,
            "bluetoothPhase": String(describing: deviceConnection.phase),
            "bluetoothMessage": deviceConnection.message ?? "none",
            "firmwareState": String(describing: glove.state),
            "pointingSetupStatus": deviceConnection.calibrationStatus,
            "pointingCaptureOutcome": deviceConnection.lastCaptureOutcome,
            "pointingCaptureInProgress": deviceConnection.capturingPose,
            "pointingHasDownwardPose": deviceConnection.hasFirstPose,
            "pointingHasUnsavedResult": deviceConnection.hasPendingCalibration,
            "locationAuthorization": locationManager.authorizationStatus.rawValue,
            "locationAccuracy": number(currentLocation?.horizontalAccuracy),
            "locationAge": number(currentLocation.map { now.timeIntervalSince($0.timestamp) }),
            "phoneHeadingAccuracy": number(lastPhoneHeading?.headingAccuracy),
            "phoneTrueHeading": number(lastPhoneHeading?.trueHeading),
            "phoneMagneticHeading": number(lastPhoneHeading?.magneticHeading),
            "phoneHeadingAge": number(lastPhoneHeading.map { now.timeIntervalSince($0.timestamp) }),
            "correctionDegrees": number(correction?.degrees),
            "correctionUncertainty": number(correction?.uncertainty),
            "correctionAge": number(correction.map { now.timeIntervalSince($0.timestamp) }),
            "gloveMountUncertainty": number(glove.pointingCalibration?.uncertainty),
            "gloveCalibration": glove.sensorHealth.map { Int($0.calibration) } as Any? ?? NSNull(),
            "gloveSensorFlags": glove.sensorHealth.map { Int($0.flags) } as Any? ?? NSNull(),
            "gloveOrientationAge": number(glove.orientation.map { now.timeIntervalSince($0.timestamp) }),
            "gloveHeading": number(glove.lastHeading?.degrees),
            "gloveHeadingAge": number(glove.lastHeading.map { now.timeIntervalSince($0.timestamp) }),
            "gloveMessage": glove.message ?? "none",
            "hardwareCalibrationInProgress": glove.hardwareCalibrationInProgress,
            "hardwareCalibrationMessage": glove.hardwareCalibrationMessage ?? "none",
            "guidanceStatus": controller.feedback.status.rawValue,
            "pointingError": number(controller.feedback.angularErrorDegrees),
            "directionUncertainty": number(controller.feedback.uncertaintyDegrees),
            "conservativeError": number(controller.feedback.conservativeErrorDegrees),
            "beaconDistance": number(controller.feedback.distanceToBeaconMeters),
            "beaconIndex": controller.navigation.beaconIndex,
            "locationQuality": controller.navigation.locationQuality.rawValue,
            "lastQueuedHaptic": controller.lastQueuedHapticCommand.map { String(describing: $0) } ?? "none",
            "lastHapticQueuedAge": number(controller.lastHapticQueuedAt.map { now.timeIntervalSince($0) }),
            "lastMotorAcknowledgementAge": number(glove.lastMotorAcknowledgement.map { now.timeIntervalSince($0) }),
            "transportError": controller.lastTransportError ?? "none"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = URL.documentsDirectory.appending(path: "north-reference-diagnostics.json")
        northDiagnosticQueue.async { try? data.write(to: url, options: .atomic) }
    }
    #endif

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        deviceConnection.isConnected
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !isDemo, let location = locations.last else { return }
        currentLocation = location
        guard stage != .indoorDemo else { return }
        refreshNorthCorrection()
        let previouslyOffRoute = controller.navigation.rerouteRequired
        let arrival = journeyPlan != nil
            ? journey.updateLocation(location)
            : controller.updateLocation(location)
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

    /// VoiceOver's activation: tap to start, tap again to finish, and the pause detector also finishes.
    func microphone() {
        startListening(automatically: false, holdToTalk: false)
    }

    /// Tap on the hand: bring up the talk panel without opening the microphone yet.
    func armMicrophone() {
        guard !demoInFlight, stage == .home, UIApplication.shared.applicationState == .active else { return }
        work?.cancel()
        stopSpokenReply()
        transcript = ""
        stage = .armed
        UIAccessibility.post(notification: .announcement, argument: "Hold the panel while you speak, then let go.")
    }

    /// Finger down on the talk panel: record until `releaseMicrophone`, however long the pauses.
    func holdMicrophone() {
        guard !listening else { return }
        microphoneHeld = true
        startListening(automatically: false, holdToTalk: true)
    }

    func releaseMicrophone() {
        microphoneHeld = false
        // A release before capture started is handled when the start task resumes.
        if listening, holdToTalkActive { finishRecording() }
    }

    private func startListening(automatically: Bool, holdToTalk: Bool) {
        guard !demoInFlight, UIApplication.shared.applicationState == .active else { return }
        if listening { finishRecording(); return }
        // A hold interrupts a search in flight (and, via stopSpokenReply, whatever Point is saying).
        guard stage != .searching || holdToTalk else { return }
        work?.cancel()
        stopSpokenReply()
        transcript = ""
        holdToTalkActive = holdToTalk
        let replyRouteID = awaitingRouteStart && stage == .route ? routeStartID : nil
        recordingRouteID = replyRouteID
        work = Task {
            do {
                try await recorder.start()
                guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { recorder.cancel(); return }
                // A tap too short for capture to start: nothing was said, so do not search.
                guard !holdToTalk || microphoneHeld else { recorder.cancel(); return }
                if let replyRouteID {
                    guard awaitingRouteStart, routeStartID == replyRouteID else { recorder.cancel(); return }
                    routeReplyState = .listening
                } else { stage = .recording }
                // Do not play generated speech into our own recording.
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                if !automatically {
                    let instruction = replyRouteID != nil ? "Listening. Say yes to start, or no to wait."
                        : holdToTalk ? "Listening. Say a destination, then let go."
                        : "Listening. Say a destination. I'll finish when you pause."
                    UIAccessibility.post(notification: .announcement, argument: instruction)
                }
                recordingLimit = Task {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled, listening else { return }
                    finishRecording()
                }
            } catch { fail(error) }
        }
    }

    private func finishRecording() {
        guard listening else { return }
        recordingLimit?.cancel()
        let replyRouteID = recordingRouteID
        if replyRouteID != nil { routeReplyState = .processing }
        else { stage = .searching }
        work = Task {
            do {
                let recording = try await recorder.finish()
                guard !Task.isCancelled else { return }
                if let replyRouteID {
                    guard awaitingRouteStart, routeStartID == replyRouteID else { return }
                }
                // OpenAI gives the final transcript when configured; the live Apple Speech text
                // is the fallback, so voice still works without a key or when the request fails.
                var text = recording.transcript
                let configuration = developmentVoiceConfiguration
                // Deepgram first (Nova-3 with Boston place-name keyterms), then OpenAI, then the live Apple text.
                let transcriber: (any SpeechTranscribing)? = if let key = configuration.deepgramKey {
                    DeepgramTranscriber(apiKey: key)
                } else if let key = configuration.openAIKey {
                    OpenAITranscriber(model: configuration.transcriptionModel, authorization: { "Bearer \(key)" })
                } else { nil }
                if let transcriber {
                    do { text = try await transcriber.transcribe(audio: recording.audio) }
                    catch { if text.isEmpty { throw error } }
                }
                guard !Task.isCancelled else { return }
                if let replyRouteID {
                    guard awaitingRouteStart, routeStartID == replyRouteID else { return }
                }
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
        guard !Task.isCancelled else { return }
        if IndoorDemoCommand.matches(text) { enterIndoorDemo(); return }
        let reply = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if ["cancel", "never mind", "nevermind", "stop"].contains(reply) { cancel(); return }
        if awaitingRouteStart, let answer = RouteStartReply.parse(text) {
            routeReplyState = .idle
            switch answer {
            case .start: startJourney()
            case .wait: deferRouteStart()
            case .repeatQuestion: promptToStartRoute(routeStartAnnouncement)
            }
            return
        }
        // A new destination supersedes the old start question before any service request.
        routeStartID = nil
        recordingRouteID = nil
        routeReplyState = .idle
        routeStartMessage = ""
        stage = .searching
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
                    // Belt and braces: a model that leaves "near me" in the query sends MapKit hunting for those words.
                    let cleaned = VoiceDestination.destinationQuery(from: intent.query)
                    query = cleaned.isEmpty ? intent.query : cleaned
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

    private func showRoute(_ plan: RoutePlan, to place: PlaceCandidate, introduction: String? = nil) {
        pendingTransitOffer = false
        pendingRoute = nil
        followUpPrompt = nil
        requestedCity = nil
        candidates = []
        selectedPlace = place
        journeyPlan = nil
        journeyStarted = false
        route = plan
        stage = .route
        locationManager.startUpdatingHeading()
        let prefix = introduction.map { "\($0) " } ?? ""
        promptToStartRoute(prefix + NavigationSpeech.routeReady(for: place))
    }

    private var routeStartAnnouncement: String {
        if let journeyPlan { return "Transit route ready. \(journeyPlan.summary) \(NavigationSpeech.startQuestion)" }
        return selectedPlace.map { NavigationSpeech.routeReady(for: $0) } ?? NavigationSpeech.startQuestion
    }

    private func promptToStartRoute(_ announcement: String) {
        guard let route, !journeyStarted else { return }
        routeStartID = route.id
        routeReplyState = .idle
        routeStartMessage = "Would you like to start?"
        stage = .route
        announce(announcement, listensForReply: true)
    }

    func deferRouteStart(announceReply: Bool = true) {
        guard awaitingRouteStart else { return }
        work?.cancel()
        recordingLimit?.cancel()
        stopSpokenReply()
        recorder.cancel()
        recordingRouteID = nil
        microphoneHeld = false
        routeReplyState = .idle
        routeStartMessage = "Ready when you are. Say start to begin."
        stage = .route
        if announceReply { announce("Okay. Your route is ready whenever you are. Say start when you're ready.") }
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
                showRoute(walk, to: place, introduction: transitRequested
                          ? "I couldn't find a bus or train for that trip, so here's the walk."
                          : "That's close enough to walk.")
                return
            }
            // Plans arrive fastest first; take it rather than asking the rider to compare routes.
            pendingJourneyPlace = place
            selectJourney(plans[0])
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
        journeyStarted = false
        stage = .route
        locationManager.startUpdatingHeading()
        promptToStartRoute(routeStartAnnouncement)
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
            announce("If you boarded, tap I'm on board. If not, tap Not on board.")
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
            announce("Live tracking isn't available. Tap I'm off when you reach \(ride.alight.name).")
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
            announce("\(reason) Tap Replan to plan again from here.")
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

    func preview() { playVoiceDemo() }

    #if DEBUG
    func previewRouteStart() {
        cancel()
        showSampleRoute(askToStart: true)
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--preview-route-answer"), arguments.indices.contains(index + 1) {
            // A simulated transcript exercises the same reply path without microphone/network input.
            searchTyped(arguments[index + 1])
        }
    }

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

    private func showSampleRoute(askToStart: Bool = false) {
        isDemo = true
        transcript = "Take me to Shake Shack"
        selectedPlace = PlaceCandidate(id: "demo", name: "Shake Shack", address: "Sample walking route · Cambridge", coordinate: DemoRoute.coordinates.last!)
        route = DemoRoute.plan
        stage = .route
        if askToStart { promptToStartRoute("Sample route to Shake Shack. \(NavigationSpeech.startQuestion)") }
        else { announce("Sample route to Shake Shack. This is a preview, not live directions.") }
    }

    func startJourney() {
        guard let route, !journeyStarted else { return }
        stopSpokenReply()
        recordingLimit?.cancel()
        recorder.cancel()
        // Invalidate a recording/transcription already in flight before starting.
        work?.cancel()
        routeStartID = nil
        recordingRouteID = nil
        microphoneHeld = false
        routeReplyState = .idle
        routeStartMessage = ""
        followUpPrompt = nil
        stage = .route
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
                if let currentLocation { journey.updateLocation(currentLocation) }
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
                self?.refreshNorthCorrection()
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
        routeStartID = nil
        recordingRouteID = nil
        routeReplyState = .idle
        routeStartMessage = ""
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
        if awaitingRouteStart { deferRouteStart(announceReply: false) }
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
        deviceConnection.enteredForeground()
        controller.setOutputEnabled(true)
        guard stage != .indoorDemo else { return }
        requestLocation()
        locationManager.startUpdatingHeading()
        refreshNorthCorrection()
        if stage == .route, !isDemo {
            if journeyStarted { startGloveWatchdog() }
            if journeyPlan != nil { journey.tick() }
        }
    }

    func enterIndoorDemo() {
        // End any walk/transit plan and pending confirmations before switching coordinate systems.
        cancel()
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
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
        refreshNorthCorrection()
    }

    private func fail(_ error: Error) {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        if awaitingRouteStart {
            deferRouteStart(announceReply: false)
            routeStartMessage = "I couldn't hear your answer. Hold to reply or use Start."
            announce("I couldn't hear your answer. Your route is still ready. Hold to reply or use the Start button.")
            return
        }
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
            self.startListening(automatically: true, holdToTalk: false)
        }
    }

    private func announce(_ text: String, listensForReply: Bool = false) {
        stopSpokenReply()
        guard UIApplication.shared.applicationState == .active else { displayedReply = text; return }
        let expectedStage = stage
        let expectedRouteID = routeStartID
        let finished: () -> Void = { [weak self] in
            guard let self, listensForReply else { return }
            if expectedStage == .route, let expectedRouteID {
                guard self.awaitingRouteStart, self.routeStartID == expectedRouteID, !self.isDemo else { return }
                self.listenAfterReply(expectedStage: .route)
                return
            }
            guard expectedStage == .clarifying || expectedStage == .choosing else { return }
            // Only VoiceOver gets a hands-free reply; everyone else holds the microphone to answer.
            guard UIAccessibility.isVoiceOverRunning else { return }
            self.listenAfterReply(expectedStage: expectedStage)
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
