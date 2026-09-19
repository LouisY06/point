import PointCore
import MapKit
import SwiftUI

struct PointHomeView: View {
    @StateObject private var model = PointViewModel()
    @StateObject private var deviceConnection = DeviceConnection()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 36
    @State private var routePanelHeight: CGFloat = 300
    @State private var reveal: CGFloat = 0
    @State private var showTyping = false
    @State private var showDeviceSetup = false
    @State private var showBeaconTest = false
    @State private var typedDestination = ""
    @State private var voiceCenter = CGPoint.zero
    @FocusState private var typingFocused: Bool

    private var recording: Bool { model.stage == .recording }
    private var searching: Bool { model.stage == .searching }
    private var transitionAnimation: Animation { .timingCurve(0.16, 1, 0.3, 1, duration: 0.72) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PointTheme.background.ignoresSafeArea()
                HomeMapBackdrop(isActive: model.stage != .route && !showTyping && !showDeviceSetup && model.stage != .choosing)
                    .ignoresSafeArea().opacity(1 - reveal)
                home
                    .scaleEffect(reduceMotion ? 1 : 1 + reveal * 0.42, anchor: .init(x: 0.54, y: 0.6))
                    .opacity(1 - reveal)
                    .allowsHitTesting(model.stage != .route)
                    .accessibilityHidden(model.stage == .route)

                if let route = model.route, model.stage == .route {
                    RouteMapView(route: route, activeBeaconIndex: model.journeyStarted ? model.activeBeaconIndex : nil,
                                 phoneLocation: model.currentLocation, telemetry: model.mapTelemetry)
                        .id(route.id)
                        .padding(.bottom, routePanelHeight)
                        .ignoresSafeArea()
                        .scaleEffect(reduceMotion ? 1 : 1.12 - reveal * 0.12)
                        .mask {
                            if reduceMotion { Rectangle().opacity(reveal) }
                            else { PortalReveal(progress: reveal, origin: voiceCenter == .zero ? CGPoint(x: geometry.size.width * 0.49, y: geometry.size.height * 0.6) : voiceCenter) }
                        }
                    routeControls
                        .opacity(reveal)
                        .offset(y: reduceMotion ? 0 : 18 * (1 - reveal))
                }
            }
            .coordinateSpace(name: "screen")
        }
        .tint(PointTheme.action)
        .onChange(of: model.stage) { _, stage in
            withAnimation(reduceMotion ? .easeOut(duration: 0.18) : transitionAnimation) {
                reveal = stage == .route ? 1 : 0
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.sceneActive() }
            if phase != .active { model.sceneInactive() }
            if phase == .background { deviceConnection.enteredBackground() }
        }
        .onPreferenceChange(RoutePanelHeightKey.self) { routePanelHeight = $0 }
        .onChange(of: showDeviceSetup) { _, shown in if shown { model.pauseJourney() } }
        .sheet(isPresented: $showTyping) { typingSheet }
        .sheet(isPresented: $showDeviceSetup) { DeviceSetupView(connection: deviceConnection) }
        .fullScreenCover(isPresented: $showBeaconTest) { CameraBeaconTestView() }
        .sheet(isPresented: Binding(get: { model.stage == .choosing }, set: { if !$0 && model.stage == .choosing { model.cancel() } })) { destinationSheet }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-point-ai") { model.previewPointAI() }
            #endif
            if ProcessInfo.processInfo.arguments.contains("--preview-route") { model.preview() }
            if ProcessInfo.processInfo.arguments.contains("--device-setup") { showDeviceSetup = true }
            if ProcessInfo.processInfo.arguments.contains("--test-beacons") { showBeaconTest = true }
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-point-ai") { return }
            #endif
            // Microphone, speech, location, then Bluetooth: iOS queues the prompts in order.
            await model.requestPermissions()
            deviceConnection.prepare()
        }
    }

    private var home: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                wordmark
                Spacer()
                if model.stage == .home { beaconTestButton }
                deviceSetupButton
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.top, 14)
            .padding(.horizontal, 28)
            .frame(maxWidth: 520)

            ScrollView {
                VStack(spacing: 0) {
                    VStack(alignment: .center, spacing: 12) {
                        Text("Where to?")
                            .font(.system(size: titleSize, weight: .medium, design: .default))
                            .tracking(-0.7)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                            .accessibilityAddTraits(.isHeader)
                            .opacity(model.stage == .home ? 1 : 0)
                            .accessibilityHidden(model.stage != .home)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 36)

                    HandVoiceInteraction(
                        active: model.stage != .home,
                        listening: recording,
                        searching: searching,
                        transcript: model.transcript,
                        isDemo: model.isDemo,
                        prompt: model.stage == .clarifying || (recording && model.transcript.isEmpty) ? model.followUpPrompt : nil,
                        spokenReply: model.displayedReply,
                        needsConfirmation: model.needsConfirmation,
                        onConfirm: { model.confirmDestination() },
                        onDecline: { model.declineDestination() },
                        onSpeak: { model.microphone() },
                        onFinish: { model.microphone() },
                        onCancel: { model.cancel() },
                        onType: { model.prepareTypedReply(); typedDestination = ""; showTyping = true },
                        onVoiceCenter: { if model.stage != .route { voiceCenter = $0 } }
                    )
                    .padding(.top, 16)
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        }
    }

    private var beaconTestButton: some View {
        Button { model.openBeaconTest(); showBeaconTest = true } label: {
            ViewThatFits(in: .horizontal) {
                Label("Test beacons", systemImage: "viewfinder")
                    .fixedSize()
                Image(systemName: "viewfinder")
                    .frame(minWidth: 24)
            }
            .font(.subheadline.weight(.medium))
            .frame(minHeight: 48)
            .padding(.horizontal, 12)
            .foregroundStyle(.white)
            .background(.black.opacity(0.8), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Test beacons")
    }

    private var wordmark: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("point").font(.title2.weight(.bold)).tracking(-1)
            Circle().fill(PointTheme.accent).frame(width: 5, height: 5).offset(y: -2)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Point")
    }

    private var deviceSetupButton: some View {
        Button { model.openDeviceSetup(); showDeviceSetup = true } label: {
            Image(systemName: deviceConnection.isConnected ? "antenna.radiowaves.left.and.right" : "hand.raised.slash")
                .font(.body).foregroundStyle(.primary)
                .frame(width: 48, height: 48)
        }
        .accessibilityLabel(deviceConnection.isConnected ? "Device connected. Open device setup" : "Connect device. Open device setup")
    }

    private var routeControls: some View {
        VStack {
            HStack {
                Button { model.cancel() } label: {
                    Image(systemName: "arrow.left").font(.body.weight(.medium))
                        .frame(width: 48, height: 48).background(PointTheme.background, in: Circle())
                }
                .accessibilityLabel("Back to voice search")
                Spacer()
                deviceSetupButton
                    .background(PointTheme.background, in: Circle())
                Text(model.isDemo ? "Preview" : "Walking")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(PointTheme.background, in: Capsule())
            }
            .padding(.horizontal, 24).padding(.top, 12)
            Spacer()
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.selectedPlace?.name ?? "Destination")
                            .font(.title.weight(.semibold)).tracking(-0.7)
                            .accessibilityAddTraits(.isHeader)
                        Text(model.selectedPlace?.address ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Image(systemName: "location.north.circle")
                        .font(.largeTitle).foregroundStyle(PointTheme.action)
                        .accessibilityHidden(true)
                }
                Divider()
                if model.journeyStarted {
                    if !model.isDemo, model.usePhoneAsGlove {
                        PhonePointingStatusView(tester: model.phoneTester, beaconIndex: model.activeBeaconIndex,
                                                beaconCount: model.route?.beacons.count ?? 0, arrived: model.journeyState == .arrived)
                        Button("Test vibration") { model.phoneTester.testVibration() }
                            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                        if model.journeyState != .arrived {
                            Button(model.journeyState == .paused ? "Resume pointing" : "Pause pointing") {
                                if model.journeyState == .paused { model.resumeJourney() }
                                else { model.pauseJourney() }
                            }
                            .font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                        }
                    } else {
                        Label(model.pointingAligned ? "You're pointing the right way" : model.isDemo ? "Point toward the next beacon" : "Glove direction feedback is not available yet",
                              systemImage: model.pointingAligned ? "checkmark.circle.fill" : "hand.point.up.left")
                            .font(.subheadline.weight(.medium))
                    }
                    if model.isDemo {
                        Toggle("Simulate correct pointing", isOn: Binding(get: { model.pointingAligned }, set: { model.setDemoAlignment($0) }))
                            .font(.subheadline)
                    }
                    Button("End walk") { model.cancel() }.font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 50)
                } else {
                    if !model.isDemo {
                        Toggle("Phone vibration guidance", isOn: $model.usePhoneAsGlove)
                            .font(.subheadline.weight(.medium))
                        if model.usePhoneAsGlove {
                            Text("Point the camera end toward the highlighted beacon, screen down. Full strength within 10°; a gradual fade out to 35°. Two pulses mean beacon reached, then follow the next.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 16) {
                        Button { model.startJourney() } label: {
                            HStack { Text(model.isDemo ? "Try the walk" : "Start walking"); Spacer(); Image(systemName: "arrow.up.right").accessibilityHidden(true) }
                                .font(.body.weight(.semibold)).padding(.horizontal, 20).frame(minHeight: 54)
                                .foregroundStyle(.white).background(PointTheme.accent, in: Capsule())
                        }
                        .buttonStyle(PressStyle())
                        Button { model.cancel(); showTyping = true } label: {
                            Image(systemName: "magnifyingglass").font(.title3).frame(width: 54, height: 54)
                                .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                        }.accessibilityLabel("Change destination")
                    }
                }
                Text(model.isDemo ? "Sample route · Simulated glove" : model.usePhoneAsGlove ? "Route tracks while locked · Unlock for phone vibration" : deviceConnection.isConnected ? "Bluetooth verified · Sensor firmware pending" : "Glove not connected")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(26)
            .background(PointTheme.background)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: RoutePanelHeightKey.self, value: geometry.size.height)
                }
            }
        }
    }

    private var typingSheet: some View {
        NavigationStack {
            Form {
                TextField("Place or address", text: $typedDestination)
                    .focused($typingFocused).submitLabel(.search).onSubmit(submitTyped)
                Button("Find destination", action: submitTyped).disabled(typedDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .navigationTitle("Where to?")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showTyping = false } } }
        }
        .presentationDetents([.medium, .large])
        .task { typingFocused = true }
    }

    private func submitTyped() {
        guard !typedDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        showTyping = false
        model.searchTyped(typedDestination)
    }

    private var destinationSheet: some View {
        NavigationStack {
            List {
                Section { Text(model.transcript).foregroundStyle(.secondary) }
                Section {
                    Button { model.microphone() } label: { Label("Reply by voice", systemImage: "mic.fill") }
                }
                if model.candidates.isEmpty {
                    ContentUnavailableView.search(text: model.transcript)
                } else {
                    ForEach(model.candidates) { place in
                        Button { model.select(place) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(place.name).font(.headline)
                                Text(place.address).font(.subheadline).foregroundStyle(.secondary)
                            }.padding(.vertical, 8)
                        }
                    }
                }
                Section { Text("Apple Maps").font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("Is this the place?")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel() } } }
        }
    }
}

private struct VoiceCenterKey: PreferenceKey {
    static var defaultValue = CGPoint.zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

/// Linear interpolation of radius; the animation supplies a monotonic ease-out time curve.
private struct PortalReveal: Shape {
    var progress: CGFloat
    var origin: CGPoint
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func path(in rect: CGRect) -> Path {
        let radius = 28 + (hypot(rect.width, rect.height) - 28) * progress
        return Path(ellipseIn: CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2))
    }
}

private struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct VoiceWaveform: View {
    let reduceMotion: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { timeline in
            HStack(spacing: 3) {
                ForEach(0..<5) { index in
                    let phase = timeline.date.timeIntervalSinceReferenceDate * 5 + Double(index) * 0.9
                    Capsule().fill(.white)
                        .frame(width: 3, height: reduceMotion ? 15 : 7 + 18 * abs(sin(phase)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}


/// A quiet map surface establishes continuity with the route. No location access is needed.
private struct HomeMapBackdrop: View {
    let isActive: Bool
    private let region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 42.3630, longitude: -71.1030),
        span: MKCoordinateSpan(latitudeDelta: 0.0065, longitudeDelta: 0.0065))
    var body: some View {
        Map(initialPosition: .region(region), interactionModes: []) {}
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
            .mapControls {}
            .saturation(0)
            .brightness(0.04)
            .blur(radius: 2)
            .overlay(Color.black.opacity(0.16))
            .overlay { MapAtmosphere(isActive: isActive).opacity(0.82) }
            .overlay(alignment: .bottom) {
                // Keep the provider identified despite the intentionally blurred backdrop.
                Text("Map data © Apple").font(.caption2).foregroundStyle(Color.white.opacity(0.6)).padding(.bottom, 6)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}


/// Diffuse light moves independently of the map, so geography never drifts under the UI.
private struct MapAtmosphere: View {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30,
                                paused: reduceMotion || !isActive || scenePhase != .active)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let phase = time * .pi / 18
                // Soft radial falloff gives the blurred material depth without filtering
                // or redrawing the underlying native map on every animation frame.
                light(in: &context, size: size,
                      center: CGPoint(x: 0.18 + 0.22 * sin(phase), y: 0.30 + 0.16 * cos(phase * 0.8)),
                      scale: CGSize(width: 0.95, height: 0.60), angle: -0.55,
                      color: Color(red: 0.54, green: 0.64, blue: 0.70), opacity: 0.45)
                light(in: &context, size: size,
                      center: CGPoint(x: 0.82 + 0.18 * cos(phase * 0.7), y: 0.68 + 0.17 * sin(phase * 0.9)),
                      scale: CGSize(width: 0.90, height: 0.58), angle: -0.55,
                      color: Color(red: 0.68, green: 0.53, blue: 0.34), opacity: 0.36)
                // A broad, feathered reflection gives a satin sheen rather than sparkles.
                light(in: &context, size: size,
                      center: CGPoint(x: 0.5 + 0.32 * sin(phase * 0.6 + 1), y: 0.48 + 0.20 * cos(phase * 0.7)),
                      scale: CGSize(width: 0.25, height: 0.95), angle: -0.55 + 0.15 * sin(phase * 0.5),
                      color: Color(red: 0.84, green: 0.87, blue: 0.86), opacity: 0.28)
            }
        }
        .overlay {
            LinearGradient(stops: [.init(color: .black.opacity(0.12), location: 0),
                                   .init(color: .clear, location: 0.45),
                                   .init(color: .black.opacity(0.25), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .opacity(contrast == .increased ? 0.45 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func light(in context: inout GraphicsContext, size: CGSize, center: CGPoint,
                       scale: CGSize, angle: Double, color: Color, opacity: Double) {
        var layer = context
        layer.translateBy(x: size.width * center.x, y: size.height * center.y)
        layer.rotate(by: .radians(angle))
        layer.scaleBy(x: size.width * scale.width, y: size.height * scale.height)
        layer.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                   with: .radialGradient(Gradient(stops: [
                    .init(color: color.opacity(opacity), location: 0),
                    .init(color: color.opacity(opacity * 0.65), location: 0.3),
                    .init(color: color.opacity(opacity * 0.16), location: 0.68),
                    .init(color: color.opacity(0), location: 1)
                   ]), center: .zero, startRadius: 0, endRadius: 1))
    }
}


private struct RouteLoadingGlyph: View {
    let reduceMotion: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 2)
                Circle().trim(from: 0, to: 0.65)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(reduceMotion ? -90 : phase * 360))
                Circle().fill(.white).frame(width: 4, height: 4)
            }
        }
        .accessibilityLabel("Preparing route")
    }
}

private struct RoutePanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 300
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
