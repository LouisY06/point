import Combine
import CoreLocation
import CoreMotion
import PointCore
import UIKit

@MainActor final class PhoneBeaconTester: ObservableObject {
    @Published private(set) var status = "Screen down · Camera end forward"
    @Published private(set) var intensity: Double = 0
    @Published private(set) var distanceMeters: Double?
    @Published private(set) var angularErrorDegrees: Double?
    @Published private(set) var accuracyNote: String?
    @Published private(set) var activeBeaconIndex: Int?
    @Published private(set) var running = false

    private let motion = CMMotionManager()
    private let haptics = PhoneHapticPlayer()
    private var feedbackEngine = DirectionFeedbackEngine()
    private var envelope = PhoneHapticEnvelope(angleRange: .walkingRoute)
    private var heading: HeadingReading?
    private var session: NavigationSession?
    private var loop: Task<Void, Never>?
    private var previousTarget: Int?
    private var previousRoute: UUID?
    private var previousIdleTimerSetting: Bool?
    private var cueTask: Task<Void, Never>?

    /// Explicit motor check; deliberately independent of GPS, alignment and grip.
    func testVibration() {
        playCue(count: 1, duration: 0.7, gap: 0,
                message: "Testing vibration · This pulse does not indicate direction",
                completion: "Test sent · If silent, check Settings → Accessibility → Touch → Vibration")
    }

    func reachedBeacon(_ arrival: BeaconArrival) {
        guard UIApplication.shared.applicationState == .active else { return }
        let message = arrival.isDestination ? "You’ve arrived" : "Beacon \(arrival.index + 1) reached · Next beacon \(arrival.index + 2)"
        playCue(count: arrival.isDestination ? 3 : 2, duration: arrival.isDestination ? 0.3 : 0.2,
                gap: 0.15, message: message, completion: message)
    }

    /// Arrival cues briefly take priority over directional intensity, then guidance resumes.
    private func playCue(count: Int, duration: Double, gap: Double, message: String, completion: String) {
        cueTask?.cancel()
        cueTask = nil
        envelope.reset()
        haptics.prepare()
        status = haptics.errorMessage ?? message
        cueTask = Task { [weak self] in
            guard let self else { return }
            let started = ProcessInfo.processInfo.systemUptime
            let total = Double(count) * duration + Double(count - 1) * gap
            while !Task.isCancelled, UIApplication.shared.applicationState == .active {
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                guard elapsed < total else { break }
                let phase = elapsed.truncatingRemainder(dividingBy: duration + gap)
                let strength = phase < duration ? 0.8 : 0
                haptics.update(intensity: strength, now: Date())
                intensity = haptics.errorMessage == nil ? strength : 0
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            haptics.silence()
            intensity = 0
            status = haptics.errorMessage ?? completion
            cueTask = nil
            if !running { haptics.shutdown() }
        }
    }

    func start(session: NavigationSession) {
        stop()
        self.session = session
        guard CLLocationManager.headingAvailable(), motion.isDeviceMotionAvailable, haptics.supported else {
            status = "Use a physical iPhone for compass and vibration."
            return
        }
        haptics.prepare()
        motion.deviceMotionUpdateInterval = 1 / 30
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical) // Gravity only; north comes from CLLocation.
        previousIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        running = true
        status = haptics.errorMessage ?? "Waiting for compass and GPS"
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
            }
        }
    }

    func receive(_ reading: CLHeading) {
        guard running, heading.map({ reading.timestamp > $0.timestamp }) ?? true else { return }
        heading = HeadingReading(degrees: reading.trueHeading >= 0 ? reading.trueHeading : reading.magneticHeading,
                                 accuracyDegrees: reading.headingAccuracy, timestamp: reading.timestamp,
                                 reference: reading.trueHeading >= 0 ? .trueNorth : .magneticNorth)
    }

    func stop(status: String = "Screen down · Camera end forward") {
        cueTask?.cancel()
        cueTask = nil
        loop?.cancel()
        loop = nil
        motion.stopDeviceMotionUpdates()
        haptics.shutdown()
        feedbackEngine.reset()
        envelope.reset()
        heading = nil
        session = nil
        previousTarget = nil
        previousRoute = nil
        if let previousIdleTimerSetting { UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting }
        previousIdleTimerSetting = nil
        running = false
        intensity = 0
        distanceMeters = nil
        angularErrorDegrees = nil
        accuracyNote = nil
        activeBeaconIndex = nil
        self.status = status
    }

    private func publishStatus(_ value: String) { if status != value { status = value } }

    private func tick() {
        guard cueTask == nil else { return }
        guard running, let session else { return }
        guard UIApplication.shared.applicationState == .active else {
            stop(status: "Paused · Resume to test pointing")
            return
        }
        guard session.state == .navigating else {
            stop(status: session.state == .arrived ? "You’ve arrived" : "Paused · Resume to test pointing")
            return
        }
        let now = Date()
        if previousTarget != session.beaconIndex || previousRoute != session.route?.id {
            feedbackEngine.reset()
            envelope.reset()
            haptics.silence()
            previousTarget = session.beaconIndex
            previousRoute = session.route?.id
        }
        if activeBeaconIndex != session.beaconIndex { activeBeaconIndex = session.beaconIndex }
        let feedback = feedbackEngine.evaluate(
            target: session.activeBeacon,
            location: session.locationQuality == .usable ? session.location : nil,
            heading: heading, connected: true, enabled: true, rerouteRequired: session.rerouteRequired, now: now)
        let displayedDistance = feedback.distanceToBeaconMeters?.rounded()
        let displayedAngle = feedback.angularErrorDegrees?.rounded()
        if distanceMeters != displayedDistance { distanceMeters = displayedDistance }
        if angularErrorDegrees != displayedAngle { angularErrorDegrees = displayedAngle }
        if feedback.angularErrorDegrees != nil, let location = session.location, let heading {
            let note = "Estimated direction · GPS ±\(Int(location.horizontalAccuracy.rounded())) m · Compass ±\(Int(heading.accuracyDegrees.rounded()))°"
            if accuracyNote != note { accuracyNote = note }
        } else if accuracyNote != nil { accuracyNote = nil }
        let sample = motion.deviceMotion
        let age = sample.map { ProcessInfo.processInfo.systemUptime - $0.timestamp } ?? .infinity
        let gripValid = envelope.acceptsGrip(gravityZ: sample?.gravity.z, motionAge: age)
        // The test strength follows the same estimated angle shown on screen. The engine
        // still rejects stale/invalid fixes, magnetic-only headings and unreliable near-field bearings.
        // Uncertainty remains part of the glove's strict alignment confirmation, not this amplitude.
        let value = envelope.update(errorDegrees: feedback.angularErrorDegrees, gripValid: gripValid, now: now)
        haptics.update(intensity: value, now: now)
        let displayedIntensity = haptics.errorMessage == nil ? (value * 100).rounded() / 100 : 0
        if intensity != displayedIntensity { intensity = displayedIntensity }

        if let error = haptics.errorMessage { publishStatus(error); return }
        if sample == nil || !(0...0.3).contains(age) { publishStatus("Waiting for phone motion"); return }
        if !gripValid { publishStatus("Hold flat, screen down · Camera end forward"); return }
        switch feedback.status {
        case .locationUnavailable: publishStatus("Waiting for precise GPS · Try outdoors")
        case .headingUnavailable: publishStatus("Waiting for a reliable compass")
        case .calibrationRequired: publishStatus("Calibrate compass · Move away from metal")
        case .rerouteRequired: publishStatus("Off route · Choose the destination again")
        case .aligned: publishStatus("You’re pointing toward the beacon")
        case .checking: publishStatus("Hold that direction")
        case .offDirection:
            if let angle = feedback.angularErrorDegrees, abs(angle) <= 10 {
                publishStatus("Pointing toward the estimated beacon")
            } else {
                publishStatus(value > 0.02 ? "Turn toward the beacon · Stronger means closer" : "Turn slowly to find the beacon")
            }
        case .inactive, .disconnected: publishStatus("Pointing unavailable")
        }
    }
}
