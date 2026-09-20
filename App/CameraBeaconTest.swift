import ARKit
import AVFoundation
import PointCore
import SceneKit
import SwiftUI

/// Indoor demo: temporary room-space anchors never enter a GPS or transit route.
@MainActor final class CameraBeaconTestModel: NSObject, ObservableObject, @preconcurrency ARSessionDelegate {
    @Published private(set) var message = "Move your phone slowly to scan the floor."
    @Published private(set) var beaconCount = 0
    @Published private(set) var activeIndex = 0
    @Published private(set) var testing = false
    @Published private(set) var hasStarted = false
    @Published private(set) var intensity: Double = 0
    @Published private(set) var distance: Double?
    @Published private(set) var errorDegrees: Double?
    @Published private(set) var cameraAllowed = false
    @Published private(set) var trackingReady = false
    @Published private(set) var finished = false
    @Published private(set) var placementReady = false
    @Published private(set) var orientationSummary = "Waiting for live readings…"
    @Published private(set) var orientationLog: [String] = []
    private var lastLogSample = -Double.infinity
    private var lastLogWrite = -Double.infinity
    private var trackingContinuity = RoomTrackingContinuity()
    private var sessionRunning = false
    @Published var pocketDemo = true
    @Published var pocketScanAllBeacons = false
    @Published var stepLength = 0.65
    @Published private(set) var pocketActive = false
    @Published private(set) var pocketPreparing = false
    @Published private(set) var pocketCountdown = 8
    @Published private(set) var pocketSteps = 0
    private let pocketMotion = PocketMotionTracker()
    private let backgroundActivity = PocketBackgroundActivity()
    private let pocketSpeaker = PocketRouteSpeaker()
    private var estimatedArrival = EstimatedBeaconArrival()
    private var lastSpokenProblem: String?
    @Published private(set) var lockScreenReady = false
    @Published private(set) var needsGloveReference = false
    @Published var touchProtected = false
    var onBackgroundModeChange: ((Bool) -> Void)?
    private var currentGloveReferenceID: UUID? { relaxedDemo ? glove?.relativeCalibrationID : glove?.calibrationID }
    private var pocketTargets: [SIMD3<Float>] = []
    private let logURL = URL.documentsDirectory.appending(path: "demo-orientation.log")
    var orientationLogText: String { orientationLog.joined(separator: "\n") }
    @Published var relaxedDemo = true {
        didSet { approximateFloorHeight = nil; hidePlacementCursor() }
    }
    @Published var phoneHeight: Double = 1.2 {
        didSet { approximateFloorHeight = nil; hidePlacementCursor() }
    }
    private var approximateFloorHeight: Float?
    private(set) var supported = ARWorldTrackingConfiguration.isSupported
    private(set) var isLayoutPreview = false
    private var placementTransform: simd_float4x4?
    private var placementTimestamp: TimeInterval?
    private let floorCursor = IndoorBeaconMarker.cursor()

    private weak var view: ARSCNView?
    private var anchors: [ARAnchor] = []
    private var markers: [UUID: SCNNode] = [:]
    var glove: FirmwareGlove?
    @Published private(set) var roomAligned = false
    @Published private(set) var aligningRoom = false
    @Published private(set) var alignmentMessage: String?
    private var pendingPlacement: simd_float4x4?
    private var roomAlignment: RoomGloveAlignment?
    private var roomCalibrationID: UUID?
    private var alignmentSamples: [(time: Date, offset: Double)] = []
    private var alignmentStarted: Date?
    private var pulses = GlovePulseFeedback()
    private var loop: Task<Void, Never>?
    private var arrivalSince: Date?
    private var previousIdleTimerSetting: Bool?
    private var closed = false

    override init() {
        super.init()
        #if DEBUG
        // Explicit UI-only fixture: never used as evidence of working camera tracking.
        if ProcessInfo.processInfo.arguments.contains("--preview-indoor-ui") || ProcessInfo.processInfo.arguments.contains("--preview-pocket-ui") {
            isLayoutPreview = true
            supported = true
            cameraAllowed = true
            trackingReady = true
            placementReady = true
            roomAligned = true
            beaconCount = 2
            message = "Place the next beacon, or start your route."
            if ProcessInfo.processInfo.arguments.contains("--preview-pocket-ui") {
                pocketActive = true; pocketSteps = 6; testing = true; hasStarted = true
                distance = 1.8
                message = "Layout preview · No motion or glove connected."
                if ProcessInfo.processInfo.arguments.contains("--preview-pocket-guard") { touchProtected = true }
            }
        }
        #endif
    }

    func attach(_ view: ARSCNView) {
        guard !isLayoutPreview else { return }
        self.view = view
        view.scene.rootNode.addChildNode(floorCursor)
        floorCursor.isHidden = true
        view.session.delegate = self
        view.session.delegateQueue = .main
        if cameraAllowed { runSession() }
    }

    func requestCamera() async {
        guard !isLayoutPreview else { return }
        guard supported else { message = "Open Point on your iPhone to place beacons in your room."; return }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        guard !closed else { return }
        cameraAllowed = allowed
        guard allowed else { message = "Allow Camera access in Settings to place a nearby beacon."; return }
        if !sessionRunning, !pocketActive { runSession() }
    }

    private func runSession() {
        guard !closed, supported, cameraAllowed, let view, UIApplication.shared.applicationState == .active else { return }
        clearBeacons()
        trackingContinuity = RoomTrackingContinuity()
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        sessionRunning = true
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        logEvent("Build \(build); room session reset; alignment cleared")
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
            }
        }
        message = "Move your phone slowly to scan the floor."
    }

    func rescanFloor() {
        guard anchors.isEmpty, !hasStarted else { return }
        runSession()
    }

    func placeBeacon() {
        guard !hasStarted, !finished, anchors.count < 4, trackingReady, let view, let frame = view.session.currentFrame else { return }
        // Place at the exact transform shown by the floor cursor, never a second offset raycast.
        let age = placementTimestamp.map { ProcessInfo.processInfo.systemUptime - $0 } ?? .infinity
        guard placementReady, let transform = placementTransform, (0...0.3).contains(age),
              case .normal = frame.camera.trackingState else {
            hidePlacementCursor()
            message = "Aim at the floor until the ring appears."
            return
        }
        if !roomAligned {
            if let reason = guidanceBlockingReason { alignmentMessage = reason; return }
            pendingPlacement = transform
            roomCalibrationID = currentGloveReferenceID
            aligningRoom = true; alignmentSamples = []; alignmentStarted = Date()
            alignmentMessage = "Keep pointing at the marker for a moment…"
            logEvent("Capturing reference during first placement")
            return
        }
        commitBeacon(transform)
    }

    private func commitBeacon(_ transform: simd_float4x4) {
        guard let view else { return }
        let anchor = ARAnchor(name: "Indoor beacon \(anchors.count + 1)", transform: transform)
        anchors.append(anchor)
        view.session.add(anchor: anchor)
        let marker = IndoorBeaconMarker.make(number: anchors.count)
        // The column grows from the same floor position as the cursor.
        marker.simdPosition = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        view.scene.rootNode.addChildNode(marker)
        IndoorBeaconMarker.reveal(marker, reduceMotion: UIAccessibility.isReduceMotionEnabled)
        markers[anchor.identifier] = marker
        beaconCount = anchors.count
        logEvent("Placed beacon \(beaconCount)")
        message = "\(beaconCount) of 4 beacons placed."
    }

    private func hidePlacementCursor() {
        placementReady = false
        placementTransform = nil
        placementTimestamp = nil
        floorCursor.isHidden = true
    }

    private func updatePlacementCursor(_ frame: ARFrame) {
        guard let view, beaconCount < 4 else {
            hidePlacementCursor()
            message = "Four beacons placed. Start when you’re ready."
            return
        }
        let planes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .horizontal }
        func height(_ plane: ARPlaneAnchor) -> Float {
            (plane.transform * SIMD4<Float>(plane.center.x, plane.center.y, plane.center.z, 1)).y
        }
        func isUnclassified(_ plane: ARPlaneAnchor) -> Bool {
            if case .none = plane.classification { return true }
            return false
        }
        let camera = SIMD3(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y,
                           frame.camera.transform.columns.3.z)
        let floor = IndoorFloorPlacement.floorHeight(
            classified: planes.filter { $0.classification == .floor }.map(height),
            unclassified: planes.filter(isUnclassified).map(height), cameraHeight: camera.y)
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        if relaxedDemo {
            // Lock the approximation until the route is cleared or height is adjusted.
            // AR floor recognition can improve the initial guess but never move placed beacons.
            if approximateFloorHeight == nil { approximateFloorHeight = floor ?? camera.y - Float(phoneHeight) }
            guard let floorHeight = approximateFloorHeight,
                  let ray = view.raycastQuery(from: center, allowing: .estimatedPlane, alignment: .horizontal),
                  let point = IndoorFloorPlacement.approximateHit(origin: ray.origin, direction: ray.direction, floorHeight: floorHeight) else {
                hidePlacementCursor()
                message = "Tilt the camera down toward a spot 0.5–8 metres away."
                return
            }
            showPlacementCursor(at: point, timestamp: frame.timestamp)
            message = "Approximate floor · Place the ring where you want your beacon."
            return
        }
        guard let floor else {
            hidePlacementCursor()
            message = "Move your phone slowly while looking down at the floor."
            return
        }
        guard let query = view.raycastQuery(from: center, allowing: .existingPlaneGeometry, alignment: .horizontal),
              let hit = view.session.raycast(query).first(where: { result in
                  guard let plane = result.anchor as? ARPlaneAnchor,
                        plane.classification == .floor || isUnclassified(plane) else { return false }
                  let point = SIMD3(result.worldTransform.columns.3.x, result.worldTransform.columns.3.y,
                                    result.worldTransform.columns.3.z)
                  return IndoorFloorPlacement.accepts(hit: point, camera: camera, floorHeight: floor)
              }) else {
            hidePlacementCursor()
            message = "Aim at a clear spot on the floor, 0.5–8 metres away."
            return
        }
        showPlacementCursor(at: SIMD3(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y,
                                     hit.worldTransform.columns.3.z), timestamp: frame.timestamp)
        message = beaconCount == 0 ? "The ring marks where your beacon will stand."
            : "Place the next beacon, or start your route."
    }

    private func showPlacementCursor(at point: SIMD3<Float>, timestamp: TimeInterval) {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(point, 1)
        placementTransform = transform
        placementTimestamp = timestamp
        floorCursor.simdPosition = point
        floorCursor.isHidden = false
        placementReady = true
    }


    private var pointingReading: HeadingReading? {
        relaxedDemo ? glove?.relativePointing() : glove?.magneticPointing()
    }

    var guidanceBlockingReason: String? {
        guard trackingReady else { return "Hold the camera steady." }
        guard let glove, glove.connection == .ready else { return "Connect your glove to place the first beacon." }
        guard glove.capabilities?.vibration == true else { return "The glove’s motor is unavailable. Check Glove setup." }
        guard glove.pointingCalibration != nil else { return "Set up your glove’s finger direction first." }
        if let reason = glove.pointingSetupBlockingReason() { return reason }
        if !relaxedDemo, let reason = glove.sensorHealth?.fusionBlockingReason { return reason }
        guard pointingReading != nil else { return "Raise your glove and point forward." }
        return nil
    }

    private func collectRoomAlignment(_ frame: ARFrame) {
        let now = Date()
        guard let started = alignmentStarted, now.timeIntervalSince(started) <= 4,
              glove != nil, let reading = pointingReading,
              let target = pendingPlacement else {
            aligningRoom = false
            pendingPlacement = nil
            alignmentMessage = guidanceBlockingReason ?? "Keep pointing at the marker and try Place again."; return
        }
        let delta = target.columns.3 - frame.camera.transform.columns.3
        guard let alignment = RoomGloveAlignment(targetX: Double(delta.x), targetZ: Double(delta.z), magneticHeading: reading.degrees, minimumDistance: 0.5) else {
            aligningRoom = false; pendingPlacement = nil
            alignmentMessage = "Place the marker at least half a metre away."; return
        }
        if alignmentSamples.last?.time != reading.timestamp {
            alignmentSamples.append((reading.timestamp, alignment.offset))
        }
        guard let firstSample = alignmentSamples.first,
              reading.timestamp.timeIntervalSince(firstSample.time) >= (relaxedDemo ? 0.75 : 1.5) else { return }
        let stable = alignmentSamples.count >= (relaxedDemo ? 6 : 12) && alignmentSamples.allSatisfy {
            abs(DirectionFeedbackEngine.signedAngle($0.offset - firstSample.offset)) <= (relaxedDemo ? 12 : 5)
        }
        aligningRoom = false
        guard stable else {
            pendingPlacement = nil
            alignmentMessage = "Hold your glove steady and try Place again."; return
        }
        roomAlignment = alignment; roomCalibrationID = currentGloveReferenceID; roomAligned = true
        logEvent(String(format: "Room aligned; offset %.1f°", alignment.offset))
        alignmentMessage = nil
        pendingPlacement = nil
        commitBeacon(target)
    }

    func startTest() {
        guard !anchors.isEmpty, !finished else { return }
        if let reason = guidanceBlockingReason { alignmentMessage = reason; return }
        guard roomAligned else {
            alignmentMessage = "Direction reference changed. Place the beacons again."; return
        }
        if pocketActive {
            guard pocketMotion.fresh else { alignmentMessage = pocketMotion.failure ?? "Motion interrupted. Place the route again."; return }
        } else if pocketDemo {
            guard beginPocketTest() else { return }
        }
        alignmentMessage = nil
        testing = true
        logEvent(pocketActive ? "Experimental pocket route started" : "Camera route started")
        hasStarted = true
        hidePlacementCursor()
        _ = pulses.stop()
        arrivalSince = nil
        if previousIdleTimerSetting == nil { previousIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled }
        UIApplication.shared.isIdleTimerDisabled = true
        message = pocketActive ? "Face beacon 1. Stand still and pocket your phone during the countdown."
            : "Point toward beacon \(activeIndex + 1). Keep the camera uncovered."
    }

    private func beginPocketTest() -> Bool {
        guard let frame = view?.session.currentFrame, case .normal = frame.camera.trackingState,
              (0...0.3).contains(ProcessInfo.processInfo.systemUptime - frame.timestamp) else {
            alignmentMessage = "Hold the camera steady before starting."; return false
        }
        let targets = anchors.compactMap { anchor in
            frame.anchors.first(where: { $0.identifier == anchor.identifier }).map {
                SIMD3<Float>($0.transform.columns.3.x, $0.transform.columns.3.y, $0.transform.columns.3.z)
            }
        }
        guard targets.count == anchors.count, let first = targets.first else {
            alignmentMessage = "Wait for the camera to locate each beacon."; return false
        }
        let position = frame.camera.transform.columns.3
        let delta = first - SIMD3(position.x, position.y, position.z)
        guard hypot(delta.x, delta.z) >= 0.5 else {
            alignmentMessage = "Stand at least half a metre from beacon 1 before starting."; return false
        }
        pocketTargets = targets
        pocketMotion.onReady = { [weak self] in
            guard let self, self.pocketActive else { return }
            self.pocketPreparing = false
            self.logEvent("Pocket reference captured; body assumed facing beacon 1; camera stopped")
            self.message = "Pocket test ready. Walk forward and point with your glove."
            self.touchProtected = true
            self.pocketSpeaker.speak(self.lockScreenReady
                ? "Ready. You can lock the screen. Walk toward beacon one and point with your glove."
                : "Ready. Touch guard is on. Keep Point open and walk toward beacon one.")
        }
        pocketMotion.start(x: Double(position.x), z: Double(position.z),
                           heading: atan2(Double(delta.x), Double(-delta.z)) * 180 / .pi,
                           stepLength: stepLength)
        if let failure = pocketMotion.failure { alignmentMessage = failure; return false }
        pocketActive = true; pocketPreparing = true; pocketCountdown = 8; pocketSteps = 0
        touchProtected = true
        estimatedArrival = EstimatedBeaconArrival()
        backgroundActivity.start(total: anchors.count)
        lockScreenReady = backgroundActivity.running
        onBackgroundModeChange?(lockScreenReady)
        if let failure = backgroundActivity.failure { logEvent(failure) }
        // Snapshot the shared room positions, then release the camera completely.
        view?.session.pause()
        sessionRunning = false
        trackingReady = true
        return true
    }

    func finishPocketTest() {
        guard pocketActive else { return }
        finished = true
        pauseTest()
        backgroundActivity.end()
        onBackgroundModeChange?(false)
        lockScreenReady = false
        pocketSpeaker.speak("Pocket test finished.")
        logEvent("Pocket test ended by user; arrival not measured")
    }

    func nextPocketBeacon() {
        guard pocketActive, !pocketPreparing, testing else { return }
        logEvent("Beacon \(activeIndex + 1) manually advanced; arrival not measured")
        advanceBeacon()
    }

    private func advanceBeacon() {
        guard anchors.indices.contains(activeIndex) else { return }
        silence()
        markers[anchors[activeIndex].identifier]?.opacity = 0.3
        activeIndex += 1
        if pocketActive, pocketTargets.indices.contains(activeIndex), let estimate = pocketMotion.estimate {
            let next = pocketTargets[activeIndex]
            let turn = EstimatedBeaconArrival.turnCue(targetX: Double(next.x) - estimate.x,
                targetZ: Double(next.z) - estimate.z, bodyHeading: estimate.heading)
            pocketSpeaker.speak("Near beacon \(activeIndex). \(turn) toward beacon \(activeIndex + 1).")
            logEvent("Estimated arrival at beacon \(activeIndex); \(turn) toward beacon \(activeIndex + 1)")
        }
        if activeIndex == anchors.count {
            finished = true
            pauseTest()
            message = "Indoor route complete"
            if pocketActive {
                pocketSpeaker.speak("Near the final beacon. Pocket route complete.")
                backgroundActivity.end()
                onBackgroundModeChange?(false)
                lockScreenReady = false
            }
        }
    }

    func pauseTest() {
        pendingPlacement = nil
        aligningRoom = false
        testing = false
        estimatedArrival.pause()
        touchProtected = false
        silence()
        if pocketPreparing {
            pocketMotion.stop()
            pocketPreparing = false
            roomAligned = false
            alignmentMessage = "Pocket setup cancelled. Place the route again."
        }

        if let previousIdleTimerSetting { UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting }
        previousIdleTimerSetting = nil
        if !finished { message = "Paused · Resume when ready" }
    }

    func clearBeacons() {
        pauseTest()
        pocketMotion.stop()
        backgroundActivity.end()
        pocketSpeaker.stop()
        onBackgroundModeChange?(false)
        lockScreenReady = false; touchProtected = false; needsGloveReference = false
        lastSpokenProblem = nil
        pocketActive = false; pocketPreparing = false; pocketSteps = 0
        pocketTargets = []
        roomAlignment = nil; roomAligned = false; aligningRoom = false
        alignmentSamples = []; alignmentStarted = nil
        alignmentMessage = nil
        pendingPlacement = nil
        approximateFloorHeight = nil
        hidePlacementCursor()
        anchors.forEach { view?.session.remove(anchor: $0) }
        markers.values.forEach { $0.removeFromParentNode() }
        anchors.removeAll()
        markers.removeAll()
        beaconCount = 0
        activeIndex = 0
        finished = false
        hasStarted = false
        distance = nil
        errorDegrees = nil
        message = "Aim at the floor until the ring appears."
    }

    func sceneChanged(_ phase: ScenePhase) {
        if phase == .active {
            backgroundActivity.endBridge()
            Task { await requestCamera() }
        } else if phase == .background {
            if pocketActive, backgroundActivity.running {
                backgroundActivity.enteredBackground()
                logEvent("Entered background; preserving BLE link, motion and beacons")
            } else { suspend() }
        }
    }

    func receivedGloveUpdate() { if pocketActive { tick() } }

    func restoreGloveReference() {
        guard needsGloveReference, let reading = pointingReading else {
            alignmentMessage = "Point your glove level at beacon 1, then restore direction."; return
        }
        let position: SIMD3<Float>
        let target: SIMD3<Float>
        if pocketActive, let estimate = pocketMotion.estimate, pocketMotion.fresh, let first = pocketTargets.first {
            position = SIMD3(Float(estimate.x), 0, Float(estimate.z)); target = first
        } else if !pocketActive, let frame = view?.session.currentFrame, trackingReady, let first = anchors.first,
                  let located = frame.anchors.first(where: { $0.identifier == first.identifier }) {
            position = SIMD3(frame.camera.transform.columns.3.x, 0, frame.camera.transform.columns.3.z)
            target = SIMD3(located.transform.columns.3.x, 0, located.transform.columns.3.z)
        } else { alignmentMessage = "Position tracking is unavailable. Place the route again."; return }
        guard let reference = RoomGloveAlignment(targetX: Double(target.x - position.x),
                targetZ: Double(target.z - position.z), magneticHeading: reading.degrees, minimumDistance: 0.5) else {
            alignmentMessage = "Stand half a metre from beacon 1 and point at it."; return
        }
        roomAlignment = reference; roomCalibrationID = currentGloveReferenceID
        roomAligned = true; needsGloveReference = false; lastSpokenProblem = nil
        logEvent("Glove reference restored; existing beacons preserved")
        startTest()
    }

    private func gloveReferenceChanged() {
        guard roomAligned || aligningRoom else { return }
        needsGloveReference = true
        invalidateRoom("Glove reconnected or setup changed. Point at beacon 1 to restore direction.")
        speakProblem("Glove direction paused. Point at beacon one and restore direction in Point.")
    }

    private func speakProblem(_ text: String) {
        guard pocketActive, lastSpokenProblem != text else { return }
        lastSpokenProblem = text
        pocketSpeaker.speak(text)
    }

    func suspend() {
        logEvent("Camera suspended; beacons and room alignment cleared")
        clearBeacons() // Never reuse coordinates after the tracking origin changes.
        loop?.cancel()
        loop = nil
        view?.session.pause()
        sessionRunning = false
        trackingReady = false
        message = "Demo paused. Scan the room and place new beacons when you return."
    }

    func resume() { if cameraAllowed, !closed { runSession() } }
    func close() { closed = true; suspend(); persistOrientationLog() }

    func sessionWasInterrupted(_ session: ARSession) { if !pocketActive { suspend() } }
    func sessionInterruptionEnded(_ session: ARSession) { if !pocketActive { resume() } }
    func session(_ session: ARSession, didFailWithError error: Error) {
        guard !pocketActive else { return }
        suspend()
        message = "Camera tracking stopped. Exit the demo and try again."
    }

    private func silence() {
        if let command = pulses.stop() { try? glove?.send(command) }
        intensity = 0
        errorDegrees = nil
        arrivalSince = nil
    }

    private func invalidateRoom(_ reason: String) {
        guard roomAligned || aligningRoom else { return }
        roomAlignment = nil; roomAligned = false
        pauseTest()
        alignmentMessage = reason
        logEvent(reason)
    }

    private func trackingDescription(_ frame: ARFrame?) -> String {
        guard let frame else { return "No camera frame" }
        switch frame.camera.trackingState {
        case .normal: return "Normal"
        case .notAvailable: return "Unavailable"
        case .limited(let reason):
            switch reason {
            case .initializing: return "Starting camera tracking"
            case .excessiveMotion: return "Phone moving too quickly"
            case .insufficientFeatures: return "Too few visual details; aim at a textured area"
            case .relocalizing: return "Relocating room coordinates"
            @unknown default: return "Limited tracking"
            }
        }
    }

    private func logEvent(_ text: String) {
        appendLog("\(Date().formatted(date: .omitted, time: .standard)) · \(text)")
    }

    private func appendLog(_ line: String) {
        orientationLog.append(line)
        if orientationLog.count > 600 { orientationLog.removeFirst(orientationLog.count - 600) }
    }

    private func persistOrientationLog() {
        try? orientationLogText.write(to: logURL, atomically: true, encoding: .utf8)
    }

    private func updateOrientationLog(_ frame: ARFrame?) {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastLogSample >= 0.5 else { return }
        lastLogSample = uptime
        let now = Date()
        var lines = ["Mode: \(relaxedDemo ? "Relative IMU demo" : "Magnetic guidance")",
                     "Camera: \(trackingDescription(frame))",
                     "Placement: \(placementReady ? "Ready" : "Paused") · Room: \(roomAligned ? "Aligned" : aligningRoom ? "Aligning" : "Needs alignment")"]
        if pocketActive {
            lines.append("App state: \(UIApplication.shared.applicationState.rawValue) · Live Activity: \(backgroundActivity.running)")
            lines.append("Glove relative reference: \(glove?.relativeCalibrationID.uuidString ?? "none") · Compass adjustments: \(glove?.relativeReference.adjustments ?? 0)")
            lines.append(String(format: "Relative yaw correction: %.1f°", glove?.relativeReference.offset ?? 0))
            lines.append("Position source: EXPERIMENTAL steps + phone gyro; camera OFF")
            lines.append("Targets: \(pocketScanAllBeacons ? "Any beacon" : "Automatic sequence") · Selected beacon: \(activeIndex + 1)")
            lines.append("Pocket countdown: \(pocketCountdown) · Steps: \(pocketSteps)")
            if let estimate = pocketMotion.estimate {
                lines.append(String(format: "Estimated x/z: %.2f / %.2f m · Heading: %.1f° · Travel: %.2f m · Step length: %.2f m", estimate.x, estimate.z, estimate.heading, estimate.travelled, estimate.stepLength))
                lines.append("Motion valid: \(estimate.valid) · Fresh: \(pocketMotion.fresh)")
            }
            lines.append(String(format: "Up acceleration: %.3f g · Up rotation: %.3f rad/s", pocketMotion.upwardAcceleration, pocketMotion.upwardRotation))
            if let timestamp = pocketMotion.lastTimestamp { lines.append(String(format: "Motion age: %.0f ms", (uptime - timestamp) * 1000)) }
            if let failure = pocketMotion.failure { lines.append("Motion failure: \(failure)") }
        }
        if let frame, !pocketActive {
            lines.append(String(format: "Camera frame age: %.0f ms", (uptime - frame.timestamp) * 1000))
            if let view, let ray = view.raycastQuery(from: CGPoint(x: view.bounds.midX, y: view.bounds.midY), allowing: .estimatedPlane, alignment: .horizontal) {
                lines.append(String(format: "Camera aim: %.1f° elevation (negative is down)", asin(max(-1, min(1, ray.direction.y))) * 180 / .pi))
            }
        }
        if let sample = glove?.orientation {
            let x = sample.quaternion.rotate(SIMD3(1, 0, 0))
            let y = sample.quaternion.rotate(SIMD3(0, 1, 0))
            let z = sample.quaternion.rotate(SIMD3(0, 0, 1))
            lines.append(String(format: "Sensor yaw/pitch/roll: %.1f° / %.1f° / %.1f°", atan2(x.y, x.x) * 180 / .pi, asin(max(-1, min(1, -x.z))) * 180 / .pi, atan2(y.z, z.z) * 180 / .pi))
            lines.append(String(format: "Glove reading age: %.0f ms", now.timeIntervalSince(sample.timestamp) * 1000))
            let h = sample.health
            lines.append("Calibration system/gyro/accel/compass: \(h.system)/\(h.gyro)/\(h.accelerometer)/\(h.magnetometer) · Health: \(h.flags)")
            if let mount = glove?.pointingCalibration {
                let finger = sample.quaternion.rotate(mount.finger)
                lines.append(String(format: "Finger elevation: %.1f° · Forward gate: %@", asin(max(-1, min(1, finger.z))) * 180 / .pi, GloveQuaternion.isForward(finger) ? "OPEN" : "CLOSED"))
                if let direction = GloveQuaternion.heading(finger) {
                    lines.append(String(format: "Finger bearing: %.1f° (sensor reference)", direction))
                }
                lines.append(String(format: "Saved finger axis: %.3f, %.3f, %.3f", mount.finger.x, mount.finger.y, mount.finger.z))
            } else { lines.append("Finger axis: setup needed") }
        } else { lines.append("Glove: no orientation reading") }
        if let offset = roomAlignment?.offset { lines.append(String(format: "Room offset: %.1f°", offset)) }
        if let errorDegrees, testing { lines.append(String(format: "Target error: %.1f°", errorDegrees)) }
        lines.append(String(format: "Requested vibration: %.0f%%", intensity * 100))
        if let ack = glove?.lastMotorAcknowledgement { lines.append(String(format: "Last motor acknowledgement: %.1f s ago", now.timeIntervalSince(ack))) }
        lines.append("Status: \(alignmentMessage ?? message)")
        if let block = guidanceBlockingReason { lines.append("Guidance blocked: \(block)") }
        orientationSummary = lines.joined(separator: "\n")
        appendLog("\(now.formatted(date: .omitted, time: .standard)) · " + lines.joined(separator: " | "))
        if uptime - lastLogWrite >= 2 { lastLogWrite = uptime; persistOrientationLog() }
    }

    func resetDemo() { runSession() }

    private func tick() {
        defer {
            updateOrientationLog(view?.session.currentFrame)
            if pocketActive {
                backgroundActivity.update(beacon: min(activeIndex + 1, beaconCount), total: beaconCount,
                    steps: pocketSteps, status: finished ? "Route complete" : !testing ? "Paused · Open Point" : pocketPreparing ? "Pocket phone · Stay still" : message,
                    distance: distance)
            }
        }
        guard UIApplication.shared.applicationState == .active || (pocketActive && backgroundActivity.running) else { silence(); return }
        if pocketActive { tickPocket(); return }
        guard let frame = view?.session.currentFrame else {
            trackingReady = false; hidePlacementCursor(); silence()
            if trackingContinuity.requiresRealignment(normal: false, mayKeepReference: true, now: ProcessInfo.processInfo.systemUptime) {
                invalidateRoom("Camera frames stopped. Place the beacons again.")
            }
            return
        }
        let age = ProcessInfo.processInfo.systemUptime - frame.timestamp
        guard case .normal = frame.camera.trackingState, (0...0.3).contains(age) else {
            trackingReady = false
            let mayKeepReference: Bool
            switch frame.camera.trackingState {
            case .normal, .limited(.excessiveMotion), .limited(.insufficientFeatures): mayKeepReference = true
            default: mayKeepReference = false
            }
            if trackingContinuity.requiresRealignment(normal: false, mayKeepReference: mayKeepReference, now: ProcessInfo.processInfo.systemUptime) {
                invalidateRoom("Camera tracking lost its room reference. Place the beacons again.")
            }
            if aligningRoom { aligningRoom = false; alignmentMessage = "Camera moved during alignment. Hold steady and try again." }
            pendingPlacement = nil
            hidePlacementCursor()
            silence()
            message = "\(trackingDescription(frame)). Hold the camera steady."
            return
        }
        if trackingContinuity.requiresRealignment(normal: true, mayKeepReference: true, now: ProcessInfo.processInfo.systemUptime) {
            invalidateRoom("Camera tracking was interrupted. Place the beacons again.")
        }
        if !trackingReady, !testing {
            message = beaconCount == 0 ? "Aim at the floor until the ring appears."
                : hasStarted ? "Tracking ready · Resume your indoor route." : "Tracking ready · Add a beacon or start your indoor route."
        }
        trackingReady = true
        if !hasStarted, !aligningRoom { updatePlacementCursor(frame) }
        for anchor in frame.anchors {
            markers[anchor.identifier]?.simdPosition = SIMD3(anchor.transform.columns.3.x,
                                                            anchor.transform.columns.3.y,
                                                            anchor.transform.columns.3.z)
        }
        if roomCalibrationID != currentGloveReferenceID {
            gloveReferenceChanged()
        }
        if aligningRoom { collectRoomAlignment(frame); return }
        guard testing, anchors.indices.contains(activeIndex) else { return }
        guard let target = frame.anchors.first(where: { $0.identifier == anchors[activeIndex].identifier }) else {
            silence(); message = "Locating the beacon again"; return
        }
        // Camera supplies position only. The glove supplies all live pointing.
        let pose = frame.camera.transform
        let position = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        let targetPosition = SIMD3<Float>(target.transform.columns.3.x, target.transform.columns.3.y, target.transform.columns.3.z)
        updateGuidance(position: position, targetPosition: targetPosition, estimated: false)
    }

    private func tickPocket() {
        pocketMotion.checkAvailability()
        pocketCountdown = pocketMotion.countdown
        pocketSteps = pocketMotion.estimate?.steps ?? 0
        if roomCalibrationID != currentGloveReferenceID {
            silence()
            gloveReferenceChanged()
            return
        }
        if let failure = pocketMotion.failure {
            trackingReady = false; silence(); pauseTest()
            alignmentMessage = failure
            speakProblem("Motion tracking paused. Open Point to restart the position estimate.")
            roomAligned = false
            return
        }
        if pocketMotion.preparing {
            silence()
            message = pocketCountdown > 0 ? "Face beacon 1. Stand still and pocket phone · \(pocketCountdown)"
                : "Stand still with the phone in your pocket…"
            return
        }
        guard pocketMotion.fresh, let estimate = pocketMotion.estimate else {
            trackingReady = false; silence()
            message = "Waiting for fresh phone motion readings."
            return
        }
        trackingReady = true
        guard testing, pocketTargets.indices.contains(activeIndex) else { return }
        if pocketScanAllBeacons, let heading = pointingReading, let roomAlignment {
            // Free pointing lets the wearer test all table beacons without taking
            // the phone out and invalidating its fixed-pocket heading assumption.
            let candidates = pocketTargets.enumerated().compactMap { index, target -> (Int, Double)? in
                guard let error = roomAlignment.error(targetX: Double(target.x) - estimate.x,
                                                       targetZ: Double(target.z) - estimate.z,
                                                       magneticHeading: heading.degrees) else { return nil }
                guard hypot(Double(target.x) - estimate.x, Double(target.z) - estimate.z) > 0.35 else { return nil }
                return (index, abs(error))
            }
            if let closest = candidates.min(by: { $0.1 < $1.1 }) { activeIndex = closest.0 }
        }
        updateGuidance(position: SIMD3(Float(estimate.x), 0, Float(estimate.z)),
                       targetPosition: pocketTargets[activeIndex], estimated: true)
    }

    private func updateGuidance(position: SIMD3<Float>, targetPosition: SIMD3<Float>, estimated: Bool) {
        let horizontalDistance = Double(hypot(targetPosition.x - position.x, targetPosition.z - position.z))
        distance = horizontalDistance
        let now = Date()
        if estimated, !pocketScanAllBeacons,
           estimatedArrival.update(distance: horizontalDistance, steps: pocketSteps, timestamp: ProcessInfo.processInfo.systemUptime) {
            advanceBeacon()
            return
        }
        if !estimated, horizontalDistance <= 0.35 {
            intensity = 0
            if let command = pulses.stop() { try? glove?.send(command) }
            if arrivalSince == nil { arrivalSince = now }
            message = "At beacon \(activeIndex + 1)"
            if now.timeIntervalSince(arrivalSince!) >= 0.5 {
                advanceBeacon()
            }
            return
        }
        arrivalSince = nil
        if estimated, horizontalDistance <= 0.35 {
            silence(); message = pocketScanAllBeacons ? "Near estimated beacon positions. Step back to point."
                : "Near estimated beacon position…"; return
        }
        guard roomAligned, let roomAlignment else {
            silence(); message = "Direction reference changed. Place the beacons again."; return
        }
        guard let heading = pointingReading else {
            silence(); message = guidanceBlockingReason ?? "Raise your hand and point forward with the calibrated glove."; return
        }
        let error = roomAlignment.error(targetX: Double(targetPosition.x - position.x),
                                        targetZ: Double(targetPosition.z - position.z), magneticHeading: heading.degrees)
        errorDegrees = error
        guard let error else { silence(); return }
        if let command = pulses.update(error: error, now: now) {
            do {
                if relaxedDemo { try glove?.sendRelativeDemo(command) }
                else { try glove?.send(command) }
            }
            catch { silence(); message = "Glove motor busy or disconnected. Pause and try again."; return }
        }
        intensity = pulses.intensity
        message = estimated && pocketScanAllBeacons ? "Point at any beacon · Position is approximate."
            : "Point with your glove. Stronger pulses mean better alignment."

    }
}

/// A metre-tall light column with a grounded footprint and a camera-facing route number.
private enum IndoorBeaconMarker {
    static func cursor() -> SCNNode {
        let node = SCNNode()
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(PointTheme.action).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let ring = SCNTorus(ringRadius: 0.14, pipeRadius: 0.008)
        ring.materials = [material]
        let ringNode = SCNNode(geometry: ring)
        ringNode.position.y = 0.012
        node.addChildNode(ringNode)
        let dot = SCNCylinder(radius: 0.018, height: 0.004)
        dot.materials = [material]
        let dotNode = SCNNode(geometry: dot)
        dotNode.position.y = 0.006
        node.addChildNode(dotNode)
        return node
    }

    static func reveal(_ node: SCNNode, reduceMotion: Bool) {
        if reduceMotion {
            node.opacity = 0
            node.runAction(.fadeIn(duration: 0.18))
            return
        }
        node.scale = SCNVector3(1, 0.015, 1)
        let rise = SCNAction.customAction(duration: 0.38) { node, elapsed in
            let progress = min(1, Float(elapsed) / 0.38)
            let eased = 1 - pow(1 - progress, 3)
            node.scale = SCNVector3(1, 0.015 + 0.985 * eased, 1)
        }
        node.runAction(rise)
    }

    static func make(number: Int) -> SCNNode {
        let root = SCNNode()
        let gold = UIColor(PointTheme.action).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))

        func material(_ color: UIColor, opacity: CGFloat = 1) -> SCNMaterial {
            let result = SCNMaterial()
            result.lightingModel = .constant
            result.diffuse.contents = color
            result.transparency = opacity
            result.isDoubleSided = true
            if opacity < 1 { result.writesToDepthBuffer = false }
            return result
        }

        func add(_ geometry: SCNGeometry, y: Float, surface: SCNMaterial) -> SCNNode {
            geometry.materials = [surface]
            let node = SCNNode(geometry: geometry)
            node.position.y = y
            root.addChildNode(node)
            return node
        }

        // World units are metres. The narrow bright spine stays crisp inside a soft gold sleeve.
        let height: CGFloat = 1.15
        let sleeve = SCNCylinder(radius: 0.055, height: height)
        sleeve.radialSegmentCount = 32
        _ = add(sleeve, y: Float(height / 2), surface: material(gold, opacity: 0.16))
        let spine = SCNCapsule(capRadius: 0.012, height: height)
        spine.radialSegmentCount = 12
        _ = add(spine, y: Float(height / 2), surface: material(gold))
        _ = add(SCNTorus(ringRadius: 0.14, pipeRadius: 0.009), y: 0.012, surface: material(gold))
        _ = add(SCNCylinder(radius: 0.14, height: 0.004), y: 0.004,
                surface: material(gold, opacity: 0.12))

        // Dark backing keeps the number readable against bright walls and busy camera imagery.
        let badge = SCNNode()
        badge.position.y = Float(height + 0.10)
        badge.constraints = [SCNBillboardConstraint()]
        root.addChildNode(badge)
        let rim = SCNPlane(width: 0.26, height: 0.26)
        rim.cornerRadius = 0.13
        rim.materials = [material(gold)]
        badge.addChildNode(SCNNode(geometry: rim))
        let face = SCNPlane(width: 0.23, height: 0.23)
        face.cornerRadius = 0.115
        face.materials = [material(UIColor(white: 0.08, alpha: 1))]
        let faceNode = SCNNode(geometry: face)
        faceNode.position.z = 0.002
        badge.addChildNode(faceNode)

        let label = SCNText(string: "\(number)", extrusionDepth: 0)
        label.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        label.flatness = 0.2
        label.materials = [material(.white)]
        let labelNode = SCNNode(geometry: label)
        let (minimum, maximum) = label.boundingBox
        labelNode.pivot = SCNMatrix4MakeTranslation((minimum.x + maximum.x) / 2,
                                                   (minimum.y + maximum.y) / 2, 0)
        labelNode.scale = SCNVector3(0.007, 0.007, 0.007)
        labelNode.position.z = 0.004
        badge.addChildNode(labelNode)
        return root
    }
}

private struct BeaconCameraSurface: UIViewRepresentable {
    let model: CameraBeaconTestModel
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        model.attach(view)
        return view
    }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
    static func dismantleUIView(_ uiView: ARSCNView, coordinator: ()) { uiView.session.pause() }
}

struct CameraBeaconTestView: View {
    @ObservedObject var connection: DeviceConnection
    let onInstruction: (String) -> Void
    @StateObject private var model = CameraBeaconTestModel()
    @State private var showHelp = false
    @State private var showOptions = false
    @State private var showGloveSetup = false
    @State private var showOrientationLogs = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                Color.black
                if model.isLayoutPreview {
                    Color(uiColor: .secondarySystemBackground)
                } else if model.supported {
                    BeaconCameraSurface(model: model).accessibilityHidden(true)
                }
                if model.pocketActive {
                    Color.black
                    VStack(spacing: 20) {
                        Image(systemName: "figure.walk").font(.system(size: 52)).foregroundStyle(PointTheme.action).accessibilityHidden(true)
                        Text(model.pocketPreparing ? "Pocket your phone" : "Pocket test").font(.title2.weight(.semibold))
                        Text(model.pocketPreparing ? (model.pocketCountdown > 0 ? "\(model.pocketCountdown)" : "Hold still…")
                             : "\(model.pocketSteps) steps estimated").font(.title3.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
                        Text(model.pocketPreparing ? "Face beacon 1 and stay in place. Wait for ‘ready’."
                             : model.lockScreenReady ? "Camera off · Lock-screen test enabled."
                             : "Camera off · Touch guard available.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }.padding(28)
                }
            }
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            panel
        }
        .background(PointTheme.background)
        .allowsHitTesting(!model.touchProtected)
        .accessibilityHidden(model.touchProtected)
        .overlay {
            if model.touchProtected {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 18) {
                        Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(PointTheme.action).accessibilityHidden(true)
                        Text("Pocket touch guard").font(.title2.weight(.semibold))
                        Text(model.pocketPreparing ? "Face beacon 1 · Stay still · \(model.pocketCountdown)"
                             : model.lockScreenReady ? "You can lock the screen." : "Keep Point open.").foregroundStyle(.secondary)
                        Text("Hold here for 2 seconds to show controls.").font(.footnote).foregroundStyle(.secondary)
                    }.padding(24).multilineTextAlignment(.center)
                }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 2) { model.touchProtected = false }
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: "Show controls") { model.touchProtected = false }
            }
        }
        .tint(PointTheme.action)
        .sheet(isPresented: $showHelp) { help }
        .sheet(isPresented: $showGloveSetup) { DeviceSetupView(connection: connection) }
        .sheet(isPresented: $showOrientationLogs) { orientationLogs }
        .onChange(of: showHelp) { _, shown in
            if shown, model.testing { model.pauseTest(); onInstruction("Demo paused.") }
        }
        .task {
            model.glove = connection.glove
            model.onBackgroundModeChange = { connection.keepsDemoRunningInBackground = $0 }
            connection.onDemoReading = { [weak model] in model?.receivedGloveUpdate() }
            await model.requestCamera()
            guard !Task.isCancelled else { return }
            onInstruction(model.cameraAllowed
                          ? "Point your glove toward the first marker while placing it. Add up to four beacons. For the pocket test, face beacon 1 before starting, then pocket your phone and stand still until ready."
                          : model.message)
        }
        .onDisappear { connection.onDemoReading = nil; model.close() }
        .onChange(of: model.activeIndex) { old, index in
            if index > old, index < model.beaconCount, !model.pocketActive {
                onInstruction(model.pocketActive ? "Now point toward beacon \(index + 1)."
                              : "Beacon \(index) reached. Now point toward beacon \(index + 1).")
            }
        }
        .onChange(of: model.finished) { _, finished in
            if finished, !model.pocketActive { onInstruction("Indoor route complete. All beacons reached.") }
        }
        .onChange(of: scenePhase) { _, phase in
            model.sceneChanged(phase)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text(model.isLayoutPreview ? "Demo layout preview" : "Indoor demo")
                .font(.headline).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button { showOptions = true } label: {
                Label("Demo options", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly).font(.title3).frame(width: 44, height: 44)
            }.accessibilityLabel("Demo options")
            .confirmationDialog("Demo options", isPresented: $showOptions, titleVisibility: .hidden) {
                Button("Orientation logs") { showOrientationLogs = true }
                Button("Glove setup") { model.pauseTest(); showGloveSetup = true }
                Button("Demo settings") { showHelp = true }
                if model.pocketActive {
                    Button("Protect from pocket touches") { model.touchProtected = true }
                }
                if model.beaconCount > 0 {
                    Button("Clear beacons", role: .destructive) { model.resetDemo() }
                }
            }
            Button { model.close(); dismiss() } label: {
                Text("Done").font(.body.weight(.semibold)).fixedSize().frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel("Exit demo")
        }
        .padding(.horizontal, 24).padding(.vertical, 6)
        .background(PointTheme.background)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.cameraAllowed {
                Text(model.message).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                primaryButton("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } else if model.testing {
                HStack {
                    Text("Beacon \(model.activeIndex + 1) of \(model.beaconCount)").font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { model.pauseTest() } label: { Text("Pause").frame(minHeight: 44) }
                }
                if let distance = model.distance {
                    Text("\(model.pocketActive ? "≈ " : "")\(distance, specifier: "%.1f") m").monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text("\(model.pocketActive ? "Approximately " : "")\(distance, specifier: "%.1f") meters away"))
                }
                Text(model.pocketActive ? model.message : model.trackingReady ? "Keep the camera uncovered while walking." : model.message)
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.pocketActive, !model.pocketPreparing {
                    if model.pocketScanAllBeacons {
                        Button("End pocket test") { model.finishPocketTest() }.frame(minHeight: 44)
                    } else {
                        Button(model.activeIndex + 1 == model.beaconCount ? "Finish test" : "Next beacon") { model.nextPocketBeacon() }
                            .frame(minHeight: 44)
                    }
                }
            } else if model.finished {
                primaryButton("Place a new route") { model.resetDemo() }
            } else if !model.isLayoutPreview && (!connection.isConnected || !connection.pointingReady) {
                Text(connection.isConnected ? "Set up your glove once before placing beacons." : "Connect your glove to begin.")
                    .font(.subheadline).foregroundStyle(.secondary)
                primaryButton(connection.isConnected ? "Glove setup" : "Connect glove") { showGloveSetup = true }
            } else {
                Text(model.alignmentMessage ?? (model.beaconCount == 0
                     ? "Point your glove toward the marker, then place."
                     : "\(model.beaconCount) of 4 placed"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.needsGloveReference {
                    primaryButton("Restore glove direction") { model.restoreGloveReference() }
                } else if model.beaconCount > 0, !model.roomAligned, !model.aligningRoom {
                    primaryButton("Place beacons again") { model.resetDemo() }
                } else if model.hasStarted {
                    primaryButton("Resume") { startGuidance() }
                } else {
                    HStack(spacing: 12) { placementButtons }
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(PointTheme.background)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 10).frame(maxWidth: .infinity)
        }
            .buttonStyle(PointFilledButtonStyle())
    }

    @ViewBuilder private var placementButtons: some View {
        if model.beaconCount < 4 {
            primaryButton(model.aligningRoom ? "Placing…" : model.placementReady ? "Place \(model.beaconCount + 1)" : "Aim camera down") {
                model.placeBeacon()
            }.disabled(!model.placementReady || model.aligningRoom)
        }
        if model.beaconCount > 0 {
            primaryButton(model.pocketDemo ? "Start pocket test" : "Start") { startGuidance() }.disabled(model.aligningRoom)
        }
    }

    private var help: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Toggle("Experimental pocket mode", isOn: $model.pocketDemo).disabled(model.hasStarted)
                    if model.pocketDemo {
                        Toggle("Point at any beacon", isOn: $model.pocketScanAllBeacons).disabled(model.hasStarted)
                        Stepper("Step length: \(model.stepLength, specifier: "%.2f") m", value: $model.stepLength, in: 0.25...1.2, step: 0.05)
                            .disabled(model.hasStarted)
                    }
                    Toggle("Relaxed demo", isOn: $model.relaxedDemo).disabled(model.beaconCount > 0)
                    if model.beaconCount == 0 {
                        Stepper("Phone height: \(model.phoneHeight, specifier: "%.1f") m", value: $model.phoneHeight, in: 0.5...1.8, step: 0.1)
                    }
                    helpSection("Place and walk", "Point your glove level toward the first marker as you tap Place. That placement captures the shared direction reference. Add up to four beacons in visit order, then tap Start.")
                    helpSection("Pocket test", "Face beacon 1 before Start. Stay in place while putting the unlocked phone in a snug pocket. After the countdown, hold still until you hear ‘ready’. Walk forward and turn with your body; avoid sidestepping or walking backward. Keep the phone fixed in the pocket. Its accelerometer counts steps; its gyro estimates turns. The glove controls pointing. Position is approximate and drifts. Sequential guidance is the default: after an estimated arrival, a spoken cue directs you to the next beacon. Arrival uses the approximate position, so it may trigger early or late. Enable ‘Point at any beacon’ for free pointing instead. Touch guard blocks accidental taps; hold for two seconds to show controls. A Live Activity and background Bluetooth support the locked-screen test. If motion readings stop, vibration pauses.")
                    helpSection("Camera mode", "Turn pocket mode off to use camera position tracking instead. Keep the lens uncovered while walking. Locking ends camera mode. Pocket mode preserves its session with an active Live Activity. Force-quitting ends guidance.")
                    helpSection("Relaxed demo", "Uses an approximate floor and relative glove direction without waiting for magnetic north. If direction drifts, clear the beacons and place them again. Lowering your hand stops vibration.")
                    if model.supported, model.cameraAllowed {
                        VStack(alignment: .leading, spacing: 12) {
                            Button("Test glove vibration") { connection.testMotor() }
                                .buttonStyle(.bordered).frame(minHeight: 44)
                            Text(connection.firmwareMessage).font(.body).foregroundStyle(.secondary)
                        }
                    }
                    if model.beaconCount > 0 {
                        Button("Clear all beacons", role: .destructive) {
                            model.resetDemo()
                            onInstruction("Beacons cleared. Place your new route.")
                            showHelp = false
                        }.frame(minHeight: 44)
                    }
                }.padding(24).frame(maxWidth: 600)
            }
            .navigationTitle("Demo settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showHelp = false } } }
        }.tint(PointTheme.action)
    }

    private func helpSection(_ heading: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(.headline).accessibilityAddTraits(.isHeader)
            Text(text).font(.body).foregroundStyle(.secondary).lineSpacing(3)
        }
    }

    private var orientationLogs: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Live orientation").font(.headline)
                    Text(model.orientationSummary)
                        .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Updates twice a second. Finger elevation controls the hand-down cutoff. Camera aim controls placement. Vibration values are requests; an acknowledgement does not measure physical vibration.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ShareLink("Share orientation log", item: model.orientationLogText)
                        .frame(minHeight: 44)
                    Button("Copy orientation log") { UIPasteboard.general.string = model.orientationLogText }
                        .frame(minHeight: 44)
                    DisclosureGroup("Recent samples") {
                        Text(model.orientationLog.suffix(20).reversed().joined(separator: "\n\n"))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    Text("The latest 600 entries are saved on this phone. No camera images, microphone audio or GPS locations are included.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(24)
            }
            .navigationTitle("Orientation logs").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showOrientationLogs = false } } }
        }.tint(PointTheme.action)
    }

    private func startGuidance() {
        model.startTest()
        onInstruction(model.testing
                      ? model.pocketPreparing ? "Face beacon one. Stay still, pocket your phone, and wait for ready."
                          : "Point toward beacon \(model.activeIndex + 1). Use your glove to feel the direction."
                      : model.alignmentMessage ?? model.message)
    }
}
