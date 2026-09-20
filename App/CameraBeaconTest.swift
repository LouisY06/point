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
    private(set) var supported = ARWorldTrackingConfiguration.isSupported
    private(set) var isLayoutPreview = false
    private var placementTransform: simd_float4x4?
    private var placementTimestamp: TimeInterval?
    private let floorCursor = IndoorBeaconMarker.cursor()

    private weak var view: ARSCNView?
    private var anchors: [ARAnchor] = []
    private var markers: [UUID: SCNNode] = [:]
    private let haptics = PhoneHapticPlayer()
    private var envelope = PhoneHapticEnvelope()
    private var loop: Task<Void, Never>?
    private var arrivalSince: Date?
    private var previousIdleTimerSetting: Bool?
    private var closed = false

    override init() {
        super.init()
        #if DEBUG
        // Explicit UI-only fixture: never used as evidence of working camera tracking.
        if ProcessInfo.processInfo.arguments.contains("--preview-indoor-ui") {
            isLayoutPreview = true
            supported = true
            cameraAllowed = true
            trackingReady = true
            placementReady = true
            beaconCount = 2
            message = "Place the next beacon, or start your route."
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
        runSession()
    }

    private func runSession() {
        guard !closed, supported, cameraAllowed, let view, UIApplication.shared.applicationState == .active else { return }
        clearBeacons()
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal]
        view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
            }
        }
        message = "Move your phone slowly to scan the floor."
    }

    func placeBeacon() {
        guard !hasStarted, !finished, anchors.count < 8, trackingReady, let view, let frame = view.session.currentFrame else { return }
        // Place at the exact transform shown by the floor cursor, never a second offset raycast.
        let age = placementTimestamp.map { ProcessInfo.processInfo.systemUptime - $0 } ?? .infinity
        guard placementReady, let transform = placementTransform, (0...0.3).contains(age),
              case .normal = frame.camera.trackingState else {
            hidePlacementCursor()
            message = "Aim at the floor until the ring appears."
            return
        }
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
        message = "Beacon \(beaconCount) placed. Add another, or start your indoor route."
    }

    private func hidePlacementCursor() {
        placementReady = false
        placementTransform = nil
        placementTimestamp = nil
        floorCursor.isHidden = true
    }

    private func updatePlacementCursor(_ frame: ARFrame) {
        guard let view, beaconCount < 8 else {
            hidePlacementCursor()
            message = "All eight beacons are placed. Start when you’re ready."
            return
        }
        let planes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .horizontal }
        func height(_ plane: ARPlaneAnchor) -> Float {
            (plane.transform * SIMD4<Float>(plane.center.x, plane.center.y, plane.center.z, 1)).y
        }
        let camera = SIMD3(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y,
                           frame.camera.transform.columns.3.z)
        let floor = IndoorFloorPlacement.floorHeight(
            classified: planes.filter { $0.classification == .floor }.map(height),
            unclassified: planes.filter { $0.classification == .none }.map(height), cameraHeight: camera.y)
        guard let floor else {
            hidePlacementCursor()
            message = "Move your phone slowly while looking down at the floor."
            return
        }
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard let query = view.raycastQuery(from: center, allowing: .existingPlaneGeometry, alignment: .horizontal),
              let hit = view.session.raycast(query).first(where: { result in
                  guard let plane = result.anchor as? ARPlaneAnchor,
                        plane.classification == .floor || plane.classification == .none else { return false }
                  let point = SIMD3(result.worldTransform.columns.3.x, result.worldTransform.columns.3.y,
                                    result.worldTransform.columns.3.z)
                  return IndoorFloorPlacement.accepts(hit: point, camera: camera, floorHeight: floor)
              }) else {
            hidePlacementCursor()
            message = "Aim at a clear spot on the floor, 0.5–8 metres away."
            return
        }
        var transform = matrix_identity_float4x4
        transform.columns.3 = hit.worldTransform.columns.3
        placementTransform = transform
        placementTimestamp = frame.timestamp
        floorCursor.simdPosition = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        floorCursor.isHidden = false
        placementReady = true
        message = beaconCount == 0 ? "The ring marks where your beacon will stand."
            : "Place the next beacon, or start your route."
    }

    func startTest() {
        guard !anchors.isEmpty, trackingReady, !finished else { return }
        haptics.prepare()
        if let error = haptics.errorMessage { message = error; return }
        testing = true
        hasStarted = true
        hidePlacementCursor()
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

    func suspend() {
        clearBeacons() // Never reuse coordinates after the tracking origin changes.
        loop?.cancel()
        loop = nil
        view?.session.pause()
        trackingReady = false
        message = "Demo paused. Scan the room and place new beacons when you return."
    }

    func resume() { if cameraAllowed, !closed { runSession() } }
    func close() { closed = true; suspend() }

    func sessionWasInterrupted(_ session: ARSession) { suspend() }
    func sessionInterruptionEnded(_ session: ARSession) { resume() }
    func session(_ session: ARSession, didFailWithError error: Error) {
        suspend()
        message = "Camera tracking stopped. Exit the demo and try again."
    }

    private func silence() {
        envelope.reset()
        intensity = 0
        arrivalSince = nil
        haptics.silence()
    }

    private func tick() {
        guard UIApplication.shared.applicationState == .active else { silence(); return }
        guard let frame = view?.session.currentFrame else { trackingReady = false; hidePlacementCursor(); silence(); return }
        let age = ProcessInfo.processInfo.systemUptime - frame.timestamp
        guard case .normal = frame.camera.trackingState, (0...0.3).contains(age) else {
            trackingReady = false
            hidePlacementCursor()
            silence()
            message = "Move slowly in a well-lit area to restore tracking."
            return
        }
        if !trackingReady, !testing {
            message = beaconCount == 0 ? "Aim at the floor until the ring appears."
                : hasStarted ? "Tracking ready · Resume your indoor route." : "Tracking ready · Add a beacon or start your indoor route."
        }
        trackingReady = true
        if !hasStarted { updatePlacementCursor(frame) }
        for anchor in frame.anchors {
            markers[anchor.identifier]?.simdPosition = SIMD3(anchor.transform.columns.3.x,
                                                            anchor.transform.columns.3.y,
                                                            anchor.transform.columns.3.z)
        }
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
                    message = "Indoor route complete"
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
        intensity = value > 0.005 ? haptics.submittedIntensity : 0
        if let error = haptics.errorMessage { message = error }
        else if !grip { message = "Hold flat, screen down · Camera end forward" }
        else { message = "Stronger vibration means you’re pointing toward the beacon." }
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
    let onInstruction: (String) -> Void
    @StateObject private var model = CameraBeaconTestModel()
    @StateObject private var vibrationTest = PhoneBeaconTester()
    @State private var showHelp = false
    @State private var didTestVibration = false
    @State private var panelHeight: CGFloat = 280
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        GeometryReader { geometry in
            Color.black
                .overlay {
                    if model.isLayoutPreview {
                        Color(uiColor: .secondarySystemBackground)
                    } else if model.supported {
                        BeaconCameraSurface(model: model).accessibilityHidden(true)
                    }
                }
                .ignoresSafeArea()
                .safeAreaInset(edge: .top, spacing: 0) { header }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ScrollView {
                        panel
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(panelHeight, geometry.size.height * 0.56))
                    .background(PointTheme.background)
                }
        }
        .tint(PointTheme.action)
        .sheet(isPresented: $showHelp) { help }
        .onChange(of: showHelp) { _, shown in
            if shown, model.testing { model.pauseTest(); onInstruction("Demo paused.") }
            if !shown { vibrationTest.stop() }
        }
        .task {
            await model.requestCamera()
            guard !Task.isCancelled else { return }
            onInstruction(model.cameraAllowed
                          ? "Demo mode. Scan the floor, then place beacons in the order you want to visit them. Your phone will guide you for now."
                          : model.message)
        }
        .onDisappear { vibrationTest.stop(); model.close() }
        .onChange(of: model.activeIndex) { old, index in
            if index > old, index < model.beaconCount {
                onInstruction("Beacon \(index) reached. Now point toward beacon \(index + 1).")
            }
        }
        .onChange(of: model.finished) { _, finished in
            if finished { onInstruction("Indoor route complete. All beacons reached.") }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.requestCamera() } }
            else { vibrationTest.stop(); model.suspend() }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text(model.isLayoutPreview ? "Demo layout preview" : "Indoor demo")
                .font(.headline).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button { showHelp = true } label: {
                Image(systemName: "questionmark.circle").font(.title3).frame(width: 44, height: 44)
            }.accessibilityLabel("Demo help")
            Button("Done") { model.close(); dismiss() }
                .font(.body.weight(.semibold)).frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Exit demo")
        }
        // Navigation chrome stays compact; instructions and actions below retain full Dynamic Type.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 24).padding(.vertical, 6)
        .background(PointTheme.background)
    }

    private var title: String {
        if !model.supported { return "Try it on iPhone" }
        if !model.cameraAllowed { return "Let Point see the floor" }
        if model.finished { return "You made it" }
        if model.testing { return "Beacon \(model.activeIndex + 1) of \(model.beaconCount)" }
        if model.hasStarted { return "Route paused" }
        if model.beaconCount > 0 { return "\(model.beaconCount) \(model.beaconCount == 1 ? "beacon" : "beacons") placed" }
        return model.placementReady ? "Place your first beacon" : "Find the floor"
    }

    private var instruction: String {
        if !model.cameraAllowed, model.supported { return "Allow camera access to place beacons around you." }
        if model.finished { return "Every beacon reached. Ready for another route?" }
        return model.message
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(instruction).font(.body).foregroundStyle(.secondary).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.supported, !model.cameraAllowed {
                primaryButton("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } else if model.supported {
                if model.testing {
                    VStack(alignment: .leading, spacing: 10) {
                        if let distance = model.distance {
                            Text("\(distance, specifier: "%.1f") m away").font(.body.monospacedDigit())
                                .accessibilityLabel(Text("\(distance, specifier: "%.1f") meters away"))
                        }
                        ProgressView(value: model.intensity / 0.8).tint(PointTheme.action)
                            .accessibilityLabel("Pointing alignment")
                            .accessibilityValue("\(Int(model.intensity / 0.8 * 100)) percent")
                    }
                    primaryButton("Pause route") { model.pauseTest(); onInstruction("Demo paused.") }
                } else if model.finished {
                    primaryButton("Place a new route") { model.clearBeacons() }
                } else if model.hasStarted {
                    primaryButton("Resume route") { startGuidance() }.disabled(!model.trackingReady)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { placementButtons }
                        VStack(spacing: 12) { placementButtons }
                    }
                }
                Text("Guidance from your phone")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
        .frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(PointFilledButtonStyle())
    }

    @ViewBuilder private var placementButtons: some View {
        primaryButton(model.beaconCount == 0 ? "Place beacon" : "Add beacon") {
            model.placeBeacon()
            onInstruction(model.message)
        }.disabled(!model.placementReady || model.beaconCount >= 8)
        if model.beaconCount > 0 {
            Button { startGuidance() } label: {
                Text("Start route").font(.body.weight(.semibold))
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PointTheme.action, lineWidth: 1))
            }.buttonStyle(.plain).foregroundStyle(PointTheme.action).disabled(!model.trackingReady)
        }
    }

    private var help: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    helpSection("Place your route", "Scan the floor in good light. Aim until the gold ring appears, then place a beacon. Add up to eight in the order you want to visit them.")
                    helpSection("Follow the vibration", "Start your route. Hold the phone flat, screen down, with its camera end along your finger. Keep the camera clear. Stronger vibration means better pointing alignment. Move within 35 cm of a beacon to reach it.")
                    helpSection("Using your phone", "This demo uses your phone’s camera and vibration. Glove guidance still needs room calibration. Leaving the app clears your beacons.")
                    helpSection("Your room stays private", "No GPS route is needed. Camera video isn’t saved or uploaded.")
                    if model.supported, model.cameraAllowed {
                        VStack(alignment: .leading, spacing: 12) {
                            Button("Test vibration") { didTestVibration = true; vibrationTest.testVibration() }
                                .buttonStyle(.bordered).frame(minHeight: 44)
                            if didTestVibration { Text(vibrationTest.status).font(.body).foregroundStyle(.secondary) }
                        }
                    }
                    if model.beaconCount > 0 {
                        Button("Clear all beacons", role: .destructive) {
                            model.clearBeacons()
                            onInstruction("Beacons cleared. Place your new route.")
                            showHelp = false
                        }.frame(minHeight: 44)
                    }
                }.padding(24).frame(maxWidth: 600)
            }
            .navigationTitle("Demo help").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showHelp = false } } }
        }.tint(PointTheme.action)
    }

    private func helpSection(_ heading: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(.headline).accessibilityAddTraits(.isHeader)
            Text(text).font(.body).foregroundStyle(.secondary).lineSpacing(3)
        }
    }

    private func startGuidance() {
        vibrationTest.stop()
        model.startTest()
        onInstruction(model.testing
                      ? "Point toward beacon \(model.activeIndex + 1). Hold the phone flat, screen down, with the camera end along your finger."
                      : model.message)
    }
}
