import CoreLocation
import Foundation
import PointCore

/// Drives the production objects through the scenario in virtual time and records everything the
/// report and console need. Nothing here sleeps: every call receives an explicit `now:`.
@MainActor public struct SimulationEngine {
    public let scenario: Scenario
    public let fixturesDirectory: URL?
    public let scenarioHash: String
    /// Ticks recorded after arrival, so "no output after arrival" is observable.
    public var tailSeconds: Double = 3

    private final class SecondBox { var value = 0.0 }

    public init(scenario: Scenario, fixturesDirectory: URL? = nil, scenarioHash: String = "") {
        self.scenario = scenario
        self.fixturesDirectory = fixturesDirectory
        self.scenarioHash = scenarioHash
    }

    public func run() async throws -> Trace {
        let scenario = try self.scenario.validated()
        let clock = VirtualClock(tickHz: scenario.tickHz)
        var random = SeededRandom(seed: scenario.seed)
        let route = try RouteBuilder.build(scenario.route, fixturesDirectory: fixturesDirectory)
        var events: [Trace.Event] = []
        var frames: [Trace.Frame] = []

        let voice = try await runVoiceStage(scenario, route: route, events: &events)
        let glove = RecordingGlove(capabilities: GloveCapabilities(heading: scenario.link.heading,
                                                                   gestures: scenario.link.gestures,
                                                                   vibration: scenario.link.vibration))
        let controller = PointController(glove: glove)
        let second = SecondBox()
        // The controller's default event hook stamps events with the wall clock; the harness
        // replaces it so connection and heading events share the simulation's timeline.
        glove.onEvent = { [weak controller] event in
            controller?.receive(event, now: clock.date(atSecond: second.value))
        }
        let output = RecordingHapticOutput()
        let playback = PhoneHapticPlayback(output: output)
        var envelope = PhoneHapticEnvelope(angleRange: .walkingRoute)
        var walker = Walker(spec: scenario.walker, path: route.checkpoints.map(\.coordinate))
        var arm = ArmModel(spec: scenario.arm)

        var started = false
        var stopped = false
        var linkAllowed = true
        var headingMuted = false
        var lastFix: CLLocation?
        var previousSecond = -1.0
        var arrivedAt: Double?
        var wasRerouteRequired = false
        var rerouteCount = 0
        var timelineIndex = 0
        let sortedTimeline = scenario.timeline.sorted { $0.at < $1.at }

        let totalTicks = Int((scenario.maxSeconds * scenario.tickHz).rounded(.up))
        for tick in 0...totalTicks {
            let now = Double(tick) * clock.tickInterval
            let date = clock.date(atSecond: now)
            second.value = now
            glove.now = now
            output.now = now

            while timelineIndex < sortedTimeline.count, sortedTimeline[timelineIndex].at <= now {
                let event = sortedTimeline[timelineIndex]
                timelineIndex += 1
                apply(event, to: controller, glove: glove, linkAllowed: &linkAllowed, headingMuted: &headingMuted,
                      stopped: &stopped, now: date, second: now, events: &events)
            }

            if linkAllowed, glove.connection == .disconnected, now >= scenario.link.connectAt,
               previousSecond < scenario.link.connectAt || tick == 0 {
                glove.connect()
                events.append(Trace.Event(t: now, kind: "link.ready"))
                if let battery = scenario.link.batteryPercent {
                    glove.emit(.battery(percent: battery))
                }
            }

            if !started, !stopped, let startSecond = voice.navigationStartSecond, now >= startSecond {
                started = true
                // `PointController.start` stamps the session with the wall clock, which would make
                // every simulated fix look stale. Start the session on simulation time and let the
                // controller's own beacon-change reset run on the following tick.
                try controller.navigation.start(route, at: lastFix, now: date)
                events.append(Trace.Event(t: now, kind: "nav.start",
                                          detail: ["beacons": String(route.beacons.count),
                                                   "beaconIndex": String(controller.navigation.beaconIndex)]))
            }

            walker.advance(to: now, tickInterval: clock.tickInterval)
            if let fix = walker.fix(at: now, clock: clock, random: &random) {
                lastFix = fix.location
                if started, let arrival = controller.updateLocation(fix.location, now: date) {
                    events.append(Trace.Event(t: now, kind: arrival.isDestination ? "nav.arrived" : "beacon.arrival",
                                              detail: ["index": String(arrival.index)]))
                    if arrival.isDestination { arrivedAt = now }
                }
            }

            let bearingToTarget = controller.navigation.activeBeacon.map {
                SimGeometry.bearingDegrees(from: walker.truth, to: $0.coordinate)
            }
            var heading: HeadingReading?
            if let reading = arm.packet(at: now, bearingToTarget: bearingToTarget, link: scenario.link,
                                        connected: glove.connection == .ready && !headingMuted,
                                        clock: clock, random: &random) {
                heading = reading
                controller.receive(.heading(reading), now: date)
            }
            controller.tick(now: date)

            if controller.navigation.rerouteRequired, !wasRerouteRequired {
                rerouteCount += 1
                events.append(Trace.Event(t: now, kind: "nav.rerouteRequired"))
            }
            wasRerouteRequired = controller.navigation.rerouteRequired

            let feedback = controller.feedback
            let gripValid = controller.navigation.state == .navigating
            let intensity = envelope.update(errorDegrees: feedback.conservativeErrorDegrees,
                                            gripValid: gripValid, now: date)
            playback.update(intensity: intensity, isActive: gripValid, now: now)

            for command in glove.drain() {
                let intent = HapticIntent.intent(for: command.command)
                var detail = ["intent": intent.rawValue]
                if case .confirm(let durationMs, let strength) = command.command {
                    detail["durationMs"] = String(durationMs)
                    detail["intensity"] = String(strength)
                    detail["errorDegrees"] = feedback.angularErrorDegrees.map { String(format: "%.2f", $0) } ?? "nil"
                    detail["conservativeDegrees"] = feedback.conservativeErrorDegrees.map { String(format: "%.2f", $0) } ?? "nil"
                }
                let kind: String
                switch intent {
                case .stop: kind = "haptic.stop"
                case .confirmAlignment: kind = "haptic.confirm"
                default: kind = "haptic.cue"
                }
                events.append(Trace.Event(t: command.second, kind: kind, detail: detail))
            }

            frames.append(Trace.Frame(
                t: now,
                lat: controller.navigation.location?.coordinate.latitude,
                lon: controller.navigation.location?.coordinate.longitude,
                truthLat: walker.truth.latitude,
                truthLon: walker.truth.longitude,
                accuracy: controller.navigation.location?.horizontalAccuracy,
                heading: heading?.degrees,
                headingAccuracy: heading?.accuracyDegrees,
                state: controller.navigation.state.rawValue,
                quality: controller.navigation.locationQuality.rawValue,
                connection: controller.connection.rawValue,
                beaconIndex: controller.navigation.beaconIndex,
                status: feedback.status.rawValue,
                locationIssue: feedback.locationIssue.map(Self.tag),
                errorDegrees: feedback.angularErrorDegrees,
                conservativeDegrees: feedback.conservativeErrorDegrees,
                distanceMeters: feedback.distanceToBeaconMeters,
                phoneIntensity: intensity,
                rerouteRequired: controller.navigation.rerouteRequired))

            previousSecond = now
            if let arrivedAt, now >= arrivedAt + tailSeconds { break }
        }

        let metrics = Metrics.compute(frames: frames, events: events,
                                      rejectedCommands: glove.rejectedCommands, rerouteCount: rerouteCount)
        let results = Assertions.evaluate(scenario.expect, frames: frames, events: events, metrics: metrics)
        return Trace(scenario: Trace.ScenarioRef(id: scenario.id, title: scenario.title, seed: scenario.seed,
                                                 tickHz: scenario.tickHz, hash: scenarioHash),
                     code: BuildInfo.current(),
                     route: Trace.RouteRef(
                        destinationName: route.destinationName,
                        checkpoints: route.checkpoints.map { [$0.coordinate.latitude, $0.coordinate.longitude] },
                        beacons: route.beacons.map {
                            Trace.RouteRef.Beacon(coordinate: [$0.coordinate.latitude, $0.coordinate.longitude],
                                                  final: $0.isFinalDestination, instruction: $0.instruction)
                        }),
                     frames: frames, events: events, results: results, metrics: metrics)
    }

    private static func tag(_ issue: LocationFeedbackIssue) -> String {
        switch issue {
        case .missing: return "missing"
        case .invalid: return "invalid"
        case .inaccurate: return "inaccurate"
        case .stale: return "stale"
        case .nearby: return "nearby"
        }
    }

    private struct VoiceOutcome {
        let navigationStartSecond: Double?
    }

    /// Spoken command → transcript → candidates → selection → route ready. Latencies are virtual:
    /// the scripted services answer immediately and the scenario decides the timeline.
    private func runVoiceStage(_ scenario: Scenario, route: RoutePlan,
                               events: inout [Trace.Event]) async throws -> VoiceOutcome {
        guard let spec = scenario.voice else { return VoiceOutcome(navigationStartSecond: 0) }
        let origin = route.checkpoints[0].coordinate
        let candidates = spec.candidates.enumerated().map { index, candidate in
            PlaceCandidate(id: "candidate-\(index)", name: candidate.name, address: candidate.address,
                           coordinate: candidate.coordinate.coordinate, streetAddress: candidate.streetAddress)
        }
        let destination = VoiceDestination(transcriber: ScriptedTranscriber(transcript: spec.utterance,
                                                                            fails: spec.transcriberFails),
                                           places: ScriptedPlaces(candidates: candidates))
        events.append(Trace.Event(t: 0, kind: "voice.utterance", detail: ["text": spec.utterance]))
        await destination.submit(audio: Data([0x01]), near: origin)

        let transcriptAt = spec.transcriberLatencyMs / 1000
        let searchAt = transcriptAt + spec.searchLatencyMs / 1000
        guard destination.state == .chooseDestination else {
            events.append(Trace.Event(t: transcriptAt, kind: "voice.failed",
                                      detail: ["state": destination.state.rawValue,
                                               "message": destination.errorMessage ?? ""]))
            return VoiceOutcome(navigationStartSecond: nil)
        }
        events.append(Trace.Event(t: transcriptAt, kind: "voice.transcript",
                                  detail: ["text": destination.transcript,
                                           "query": VoiceDestination.destinationQuery(from: destination.transcript)]))
        events.append(Trace.Event(t: searchAt, kind: "voice.candidates",
                                  detail: ["count": String(destination.candidates.count)]))
        guard let choice = spec.userChoice, destination.candidates.indices.contains(choice) else {
            events.append(Trace.Event(t: searchAt, kind: "voice.chooserOpen"))
            return VoiceOutcome(navigationStartSecond: nil)
        }
        let chosen = destination.candidates[choice]
        events.append(Trace.Event(t: searchAt, kind: "voice.selected", detail: ["name": chosen.name]))
        let readyAt = searchAt + spec.routeLatencyMs / 1000
        events.append(Trace.Event(t: readyAt, kind: "route.ready",
                                  detail: ["reply": NavigationSpeech.routeReady(for: chosen)]))
        return VoiceOutcome(navigationStartSecond: readyAt)
    }

    private func apply(_ event: TimelineEvent, to controller: PointController, glove: RecordingGlove,
                       linkAllowed: inout Bool, headingMuted: inout Bool, stopped: inout Bool, now: Date,
                       second: Double, events: inout [Trace.Event]) {
        switch event.action {
        case .gesture:
            let gesture = GloveGesture(rawValue: event.value ?? "") ?? .checkDirection
            glove.emit(.gesture(gesture))
            events.append(Trace.Event(t: second, kind: "gesture", detail: ["value": gesture.rawValue]))
        case .linkDisconnect:
            linkAllowed = false
            glove.disconnect()
            events.append(Trace.Event(t: second, kind: "link.disconnected"))
        case .linkConnect:
            linkAllowed = true
            glove.connect()
            events.append(Trace.Event(t: second, kind: "link.ready"))
        case .pause:
            controller.navigation.pause()
            events.append(Trace.Event(t: second, kind: "nav.paused"))
        case .resume:
            controller.navigation.resume()
            events.append(Trace.Event(t: second, kind: "nav.resumed"))
        case .battery:
            glove.emit(.battery(percent: Int(event.value ?? "") ?? 0))
            events.append(Trace.Event(t: second, kind: "battery", detail: ["percent": event.value ?? ""]))
        case .headingUnavailable:
            // `FirmwareGlove` emits this when calibration or pointing setup is lost, and sends no
            // headings again until it recovers.
            headingMuted = true
            glove.emit(.headingUnavailable)
            events.append(Trace.Event(t: second, kind: "link.headingUnavailable"))
        case .headingRestored:
            headingMuted = false
            events.append(Trace.Event(t: second, kind: "link.headingRestored"))
        case .outputOff:
            controller.setOutputEnabled(false)
            events.append(Trace.Event(t: second, kind: "output.disabled"))
        case .outputOn:
            controller.setOutputEnabled(true)
            events.append(Trace.Event(t: second, kind: "output.enabled"))
        case .vehicleArrived:
            controller.emit(.vehicleArrived)
            events.append(Trace.Event(t: second, kind: "transit.vehicleArrived"))
        case .stop:
            stopped = true
            controller.stop()
            events.append(Trace.Event(t: second, kind: "nav.stopped"))
        }
    }
}

enum BuildInfo {
    static func current() -> [String: String] {
        ["engine": "PointSim 1", "swift": "5.9+"]
    }
}
