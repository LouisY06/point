import Combine
import CoreLocation
import Foundation

/// App composition boundary: map/session → direction feedback → replaceable glove transport.
@MainActor public final class PointController: ObservableObject {
    public let navigation: NavigationSession
    public private(set) var glove: any GloveTransport
    @Published public private(set) var feedback = DirectionFeedback(status: .inactive, angularErrorDegrees: nil, distanceToBeaconMeters: nil)
    @Published public private(set) var connection: GloveConnection = .disconnected
    @Published public private(set) var batteryPercent: Int?
    @Published public private(set) var lastTransportError: String?
    /// The mode actually applied to the glove: the chosen mode, or cycling once sustained speed says so.
    @Published public private(set) var effectiveTravelMode: TravelMode = .walking
    /// Chosen by the wearer. Walking may be overridden to cycling by sustained GPS speed,
    /// because the walking gesture would buzz continuously with a hand resting on a handlebar.
    public var travelMode: TravelMode = .walking {
        didSet { clearSpeedOverride(); applyTravelMode() }
    }

    private var capabilities: GloveCapabilities?
    private var gloveHeading: HeadingReading?
    private var engine = DirectionFeedbackEngine()
    private var scheduler = HapticScheduler()
    private var previousTarget: Int?
    private var routeRequestID = UUID()
    private var lastGestureAt: Date?
    private var outputEnabled = true
    private var speedOverride: TravelMode?
    private var fastSince: Date?
    private var slowSince: Date?
    /// Sustained speed thresholds (m/s) and dwell for the automatic cycling override.
    public static let cyclingSpeed = 4.0
    public static let walkingSpeed = 2.0
    public static let speedDwell: TimeInterval = 5

    public init(glove: any GloveTransport) {
        self.glove = glove
        navigation = NavigationSession()
        connection = glove.connection
        glove.onEvent = { [weak self] event in self?.receive(event) }
        applyTravelMode()
    }

    /// Real navigation uses hardware; the explicit sample route uses a simulator. Never transfer heading or pending cues between devices.
    public func useTransport(_ transport: any GloveTransport, activate: Bool = true) {
        resetFeedback()
        glove.onEvent = nil
        glove = transport
        connection = .disconnected
        capabilities = nil
        gloveHeading = nil
        batteryPercent = nil
        lastGestureAt = nil
        lastTransportError = nil
        clearSpeedOverride()
        applyTravelMode()
        glove.onEvent = { [weak self] event in self?.receive(event) }
        if activate { glove.connect() }
        else { glove.disconnect(); tick() }
    }

    public func setOutputEnabled(_ enabled: Bool) {
        outputEnabled = enabled
        if !enabled { resetFeedback() }
        tick()
    }

    public func start(_ route: RoutePlan, at location: CLLocation? = nil) throws {
        routeRequestID = UUID()
        try navigation.start(route, at: location)
        resetFeedback()
        tick()
    }

    public func stop() {
        routeRequestID = UUID()
        navigation.stop()
        resetFeedback()
        clearSpeedOverride()
        applyTravelMode()
        tick()
    }

    private func clearSpeedOverride() {
        speedOverride = nil
        fastSince = nil
        slowSince = nil
    }

    private func applyTravelMode() {
        let mode = speedOverride ?? travelMode
        if effectiveTravelMode != mode { effectiveTravelMode = mode }
        if glove.travelMode != mode { glove.travelMode = mode }
    }

    /// Only a walking choice is overridden, and only after sustained speed, never a single fix.
    private func observeSpeed(_ location: CLLocation, now: Date) {
        guard travelMode == .walking, location.speed.isFinite, location.speed >= 0 else { return }
        if location.speed >= Self.cyclingSpeed {
            slowSince = nil
            if fastSince == nil { fastSince = now }
            if speedOverride == nil, now.timeIntervalSince(fastSince!) >= Self.speedDwell {
                speedOverride = .cycling
                applyTravelMode()
            }
        } else if location.speed <= Self.walkingSpeed {
            fastSince = nil
            if slowSince == nil { slowSince = now }
            if speedOverride != nil, now.timeIntervalSince(slowSince!) >= Self.speedDwell {
                speedOverride = nil
                applyTravelMode()
            }
        } else {
            fastSince = nil
            slowSince = nil
        }
    }

    /// Guards against an in-flight reroute reviving a stopped/replaced journey.
    public func reroute(using provider: any RouteProviding) async throws {
        guard navigation.state == .navigating, let location = navigation.location,
              let route = navigation.route, let destination = route.beacons.last?.coordinate else { return }
        let requestID = UUID()
        routeRequestID = requestID
        let replacement = try await provider.walkingRoute(from: location.coordinate, to: destination,
                                                           name: route.destinationName)
        guard routeRequestID == requestID, navigation.state == .navigating,
              navigation.route?.id == route.id else { return }
        try start(replacement)
    }

    @discardableResult public func updateLocation(_ location: CLLocation, now: Date = Date()) -> BeaconArrival? {
        observeSpeed(location, now: now)
        let arrival = navigation.updateLocation(location, now: now)
        tick(now: now)
        return arrival
    }

    public func receive(_ event: GloveEvent, now: Date = Date()) {
        switch event {
        case .connection(let state):
            connection = state
            gloveHeading = nil
            capabilities = nil
                lastGestureAt = nil
            resetFeedback()
        case .capabilities(let value):
            guard connection == .ready else { return }
            capabilities = value
        case .heading(let reading):
            guard connection == .ready, capabilities?.heading == true else { return }
            guard gloveHeading.map({ reading.timestamp > $0.timestamp }) ?? true else { return }
            gloveHeading = reading
        case .headingUnavailable:
            gloveHeading = nil
            resetFeedback()
        case .battery(let percent): batteryPercent = (0...100).contains(percent) ? percent : nil
        case .gesture(let gesture):
            guard connection == .ready, capabilities?.gestures == true,
                  lastGestureAt.map({ now.timeIntervalSince($0) >= 0.5 }) ?? true else { return }
            lastGestureAt = now
            switch gesture {
            case .checkDirection: resetFeedback()
            case .pauseResume:
                routeRequestID = UUID()
                if navigation.state == .paused { navigation.resume() } else { navigation.pause() }
                resetFeedback()
            }
        }
        tick(now: now)
    }

    /// Foreground shell should call at ~10 Hz as well as on every incoming event.
    /// Background timers are not assumed to run; finite firmware pulses prevent latched output.
    public func tick(now: Date = Date()) {
        if previousTarget != navigation.beaconIndex {
            resetFeedback()
            previousTarget = navigation.beaconIndex
        }
        feedback = engine.evaluate(target: navigation.activeBeacon,
                                   location: navigation.locationQuality == .usable ? navigation.location : nil,
                                   heading: gloveHeading,
                                   connected: connection == .ready && capabilities?.vibration == true,
                                   enabled: outputEnabled && navigation.state == .navigating,
                                   rerouteRequired: navigation.rerouteRequired, now: now)
        if let command = scheduler.command(for: feedback, now: now) { send(command) }
    }

    /// Event cues (a vehicle arriving) bypass the alignment scheduler. Callers send them after
    /// any `stop()` so the reset's `.stop` cannot truncate the pattern.
    public func emit(_ command: HapticCommand) {
        guard outputEnabled || command == .stop else { return }
        send(command)
    }

    private func resetFeedback() {
        engine.reset()
        scheduler.reset()
        if connection == .ready { send(.stop) }
    }

    private func send(_ command: HapticCommand) {
        guard connection == .ready else { return }
        do {
            try glove.send(command)
            lastTransportError = nil
        } catch {
            lastTransportError = error.localizedDescription
            engine.reset()
            scheduler.reset()
        }
    }
}
