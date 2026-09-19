import ARKit
import AVFoundation
import PointCore
import SceneKit
import SwiftUI

/// Short-range test only. These temporary local anchors never enter a GPS route.
@MainActor final class CameraBeaconTestModel: NSObject, ObservableObject, @preconcurrency ARSessionDelegate {
    @Published private(set) var message = "Point the camera at a floor, table or wall."
    @Published private(set) var beaconCount = 0
    @Published private(set) var activeIndex = 0
    @Published private(set) var testing = false
    @Published private(set) var intensity: Double = 0
    @Published private(set) var distance: Double?
    @Published private(set) var errorDegrees: Double?
    @Published private(set) var cameraAllowed = false
    @Published private(set) var trackingReady = false
    @Published private(set) var finished = false
    let supported = ARWorldTrackingConfiguration.isSupported

    private weak var view: ARSCNView?
    private var anchors: [ARAnchor] = []
    private var markers: [UUID: SCNNode] = [:]
    private let haptics = PhoneHapticPlayer()
    private var envelope = PhoneHapticEnvelope()
    private var loop: Task<Void, Never>?
    private var arrivalSince: Date?
    private var previousIdleTimerSetting: Bool?
    private var closed = false

    func attach(_ view: ARSCNView) {
        self.view = view
        view.session.delegate = self
        view.session.delegateQueue = .main
        if cameraAllowed { runSession() }
    }

    func requestCamera() async {
        guard supported else { message = "Camera beacons need a physical ARKit-capable iPhone."; return }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        guard !closed else { return }
        cameraAllowed = allowed
        guard allowed else { message = "Allow Camera access in Settings to place a nearby beacon."; return }
        runSession()
    }

    private func runSession() {
        guard !closed, supported, cameraAllowed, let view, UIApplication.shared.applicationState == .active else { return }
        clearBeacons()
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal, .vertical]
        view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
            }
        }
        message = "Move the camera slowly to find a surface."
    }

    func placeBeacon() {
        guard !testing, !finished, anchors.count < 8, trackingReady, let view, let frame = view.session.currentFrame else { return }
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        var hit: ARRaycastResult?
        for target in [ARRaycastQuery.Target.existingPlaneGeometry, .estimatedPlane] {
            if let query = view.raycastQuery(from: center, allowing: target, alignment: .any),
               let result = view.session.raycast(query).first { hit = result; break }
        }
        guard let hit else { message = "No surface at the crosshair yet. Move slowly, then try again."; return }
        let offset = hit.worldTransform.columns.3 - frame.camera.transform.columns.3
        let horizontalDistance = hypot(offset.x, offset.z)
        guard (0.5...8).contains(horizontalDistance) else {
            message = "Choose a spot 0.5–8 metres away across the room."
            return
        }
        let anchor = ARAnchor(name: "Test beacon \(anchors.count + 1)", transform: hit.worldTransform)
        anchors.append(anchor)
        view.session.add(anchor: anchor)
        let marker = SCNNode(geometry: SCNSphere(radius: 0.06))
        marker.geometry?.firstMaterial?.diffuse.contents = UIColor(PointTheme.accent)
        marker.geometry?.firstMaterial?.lightingModel = .constant
        marker.simdTransform = hit.worldTransform
        let label = SCNText(string: "\(anchors.count)", extrusionDepth: 0)
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.firstMaterial?.diffuse.contents = UIColor.white
        label.firstMaterial?.lightingModel = .constant
        let labelNode = SCNNode(geometry: label)
        labelNode.scale = SCNVector3(0.01, 0.01, 0.01)
        labelNode.position = SCNVector3(-0.035, 0.08, 0)
        labelNode.constraints = [SCNBillboardConstraint()]
        marker.addChildNode(labelNode)
        view.scene.rootNode.addChildNode(marker)
        markers[anchor.identifier] = marker
        beaconCount = anchors.count
        message = "Beacon \(beaconCount) placed. Add another, or start pointing."
    }

    func startTest() {
        guard !anchors.isEmpty, trackingReady, !finished else { return }
        haptics.prepare()
        if let error = haptics.errorMessage { message = error; return }
        testing = true
        envelope.reset()
        arrivalSince = nil
        previousIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        message = "Screen down · Point the camera end toward beacon \(activeIndex + 1)"
    }

    func pauseTest() {
        testing = false
        silence()
        haptics.shutdown()
        if let previousIdleTimerSetting { UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting }
        previousIdleTimerSetting = nil
        if !finished { message = "Paused · Resume when ready" }
    }

    func clearBeacons() {
        pauseTest()
        anchors.forEach { view?.session.remove(anchor: $0) }
        markers.values.forEach { $0.removeFromParentNode() }
        anchors.removeAll()
        markers.removeAll()
        beaconCount = 0
        activeIndex = 0
        finished = false
        distance = nil
        errorDegrees = nil
        message = "Point the crosshair at a surface, then place a beacon."
    }

    func suspend() {
        clearBeacons() // Never reuse coordinates after the tracking origin changes.
        loop?.cancel()
        loop = nil
        view?.session.pause()
        trackingReady = false
        message = "Camera test paused. Place new beacons when you return."
    }

    func resume() { if cameraAllowed, !closed { runSession() } }
    func close() { closed = true; suspend() }

    func sessionWasInterrupted(_ session: ARSession) { suspend() }
    func sessionInterruptionEnded(_ session: ARSession) { resume() }
    func session(_ session: ARSession, didFailWithError error: Error) {
        suspend()
        message = "Camera tracking stopped. Close and reopen this test."
    }

    private func silence() {
        envelope.reset()
        intensity = 0
        arrivalSince = nil
        haptics.silence()
    }

    private func tick() {
        guard UIApplication.shared.applicationState == .active else { silence(); return }
        guard let frame = view?.session.currentFrame else { trackingReady = false; silence(); return }
        let age = ProcessInfo.processInfo.systemUptime - frame.timestamp
        guard case .normal = frame.camera.trackingState, (0...0.3).contains(age) else {
            trackingReady = false
            silence()
            message = "Tracking uncertain · Move slowly toward a well-lit, detailed surface."
            return
        }
        if !trackingReady, !testing {
            message = beaconCount == 0 ? "Point the crosshair at a surface, then place a beacon." : "Tracking ready · Add a beacon or test pointing."
        }
        trackingReady = true
        for anchor in frame.anchors { markers[anchor.identifier]?.simdTransform = anchor.transform }
        guard testing, anchors.indices.contains(activeIndex) else { return }
        guard let target = frame.anchors.first(where: { $0.identifier == anchors[activeIndex].identifier }) else {
            silence(); message = "Locating the beacon again"; return
        }
        // Portrait view space +Y is the physical camera/top edge, even when UI rotates.
        let pose = simd_inverse(frame.camera.viewMatrix(for: .portrait))
        let position = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        let top = SIMD3<Float>(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z)
        let targetPosition = SIMD3<Float>(target.transform.columns.3.x, target.transform.columns.3.y, target.transform.columns.3.z)
        let horizontalDistance = Double(hypot(targetPosition.x - position.x, targetPosition.z - position.z))
        distance = horizontalDistance
        let now = Date()
        if horizontalDistance <= 0.35 {
            intensity = 0
            envelope.reset()
            haptics.silence()
            if arrivalSince == nil { arrivalSince = now }
            message = "At beacon \(activeIndex + 1)"
            if now.timeIntervalSince(arrivalSince!) >= 0.5 {
                markers[anchors[activeIndex].identifier]?.opacity = 0.3
                activeIndex += 1
                arrivalSince = nil
                if activeIndex == anchors.count {
                    finished = true
                    pauseTest()
                    message = "All test beacons reached"
                }
            }
            return
        }
        arrivalSince = nil
        let grip = envelope.acceptsGrip(gravityZ: Double(-pose.columns.2.y), motionAge: age)
        let direction = LocalBeaconGeometry.direction(position: position, topEdge: top, target: targetPosition)
        errorDegrees = direction?.errorDegrees
        let value = envelope.update(errorDegrees: direction?.errorDegrees, gripValid: grip, now: now)
        haptics.update(intensity: value, now: now)
        intensity = haptics.errorMessage == nil ? value : 0
        if let error = haptics.errorMessage { message = error }
        else if !grip { message = "Hold flat, screen down · Camera end forward" }
        else { message = "Point toward beacon \(activeIndex + 1) · Stronger means closer" }
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
    @StateObject private var model = CameraBeaconTestModel()
    @StateObject private var vibrationTest = PhoneBeaconTester()
    @State private var didTestVibration = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.supported { BeaconCameraSurface(model: model).ignoresSafeArea().accessibilityHidden(true) }
            if model.cameraAllowed, !model.testing {
                Image(systemName: "plus").font(.largeTitle).foregroundStyle(.white)
                    .shadow(color: .black, radius: 2).accessibilityHidden(true)
            }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Text("Nearby beacon test").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { model.close(); dismiss() }.frame(minWidth: 44, minHeight: 44)
            }.padding(.horizontal, 24).background(PointTheme.background)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.message).font(.headline).fixedSize(horizontal: false, vertical: true)
                if !model.testing {
                    Button("Test vibration") { didTestVibration = true; vibrationTest.testVibration() }
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    if didTestVibration {
                        Text(vibrationTest.status).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if model.testing {
                    ProgressView(value: model.intensity / 0.8).tint(PointTheme.action)
                        .accessibilityLabel("Pointing vibration strength")
                    if let distance = model.distance {
                        Text("Beacon \(model.activeIndex + 1) of \(model.beaconCount) · \(distance, specifier: "%.1f") m away")
                            .font(.subheadline.monospacedDigit())
                    }
                    Button("Pause pointing") { model.pauseTest() }.buttonStyle(PointFilledButtonStyle())
                } else if model.finished {
                    Button("Place new beacons") { model.clearBeacons() }.buttonStyle(PointFilledButtonStyle())
                } else {
                    Text("Place 1–8 points, about 0.5–8 m away. Then hold the phone screen-down, camera end along your finger.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack { placementButtons }
                        VStack(alignment: .leading) { placementButtons }
                    }
                }
                if model.beaconCount > 0 {
                    Button("Clear beacons", role: .destructive) { model.clearBeacons() }.frame(minHeight: 44)
                }
                Text("Local camera tracking · No video is saved or uploaded")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(PointTheme.background)
        }
        .tint(PointTheme.action)
        .task { await model.requestCamera() }
        .onChange(of: model.message) { _, message in
            UIAccessibility.post(notification: .announcement, argument: message)
        }
        .onDisappear { vibrationTest.stop(); model.close() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.resume() } else { vibrationTest.stop(); model.suspend() }
        }
    }

    @ViewBuilder private var placementButtons: some View {
        Button(model.beaconCount == 0 ? "Place beacon" : "Add beacon") { model.placeBeacon() }
            .buttonStyle(.bordered).disabled(!model.trackingReady || model.beaconCount >= 8)
        Button(model.activeIndex > 0 ? "Resume pointing" : "Test pointing") { vibrationTest.stop(); model.startTest() }
            .buttonStyle(PointFilledButtonStyle()).disabled(model.beaconCount == 0 || !model.trackingReady)
    }
}
