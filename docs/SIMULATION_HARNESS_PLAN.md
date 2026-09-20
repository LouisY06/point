# Scenario simulation, integration tests and replay console — plan

Draft plan. Nothing here is implemented yet. It describes how to add a deterministic, end‑to‑end
simulation harness (spoken command → route → walking → arm motion → haptics → arrival), a scenario
based integration test suite that grows by adding data files, and a browser console that replays a
run, exposes debugging controls and produces a report.

The overriding constraint: **the shipping app and `PointCore` must not change behavior**. Everything
below is additive.

## 1. What we are simulating

One scenario drives the real production objects through fake edges:

```
scenario.json
   │
   ├─ voice stage      ScriptedTranscriber → VoiceDestination → ScriptedPlaces → DestinationResolver
   ├─ route stage      FixtureRouteProvider (inline coords | Apple Maps fixture JSON | generated)
   ├─ motion stage     Walker (path + speed + pauses + GPS noise/dropouts) → CLLocation fixes
   ├─ arm stage        ArmModel (hold / sweep / jitter / snap / drift / mount offset) → HeadingReading
   ├─ link stage       RecordingGlove (connect, latency, loss, disconnect, battery) → GloveEvent
   │
   └─→ PointController (unchanged) ──→ NavigationSession, DirectionFeedbackEngine, HapticScheduler
                                  └──→ HapticCommand / PhoneHapticPlayback → recorded trace
```

Everything already accepts an injected `now:` (`NavigationSession.updateLocation`,
`DirectionFeedbackEngine.evaluate`, `HapticScheduler.command`, `PointController.tick`), and the
transports are already protocols (`GloveTransport`, `PhoneHapticOutput`, `SpeechTranscribing`,
`PlaceSearching`, `RouteProviding`, `SpeechPlaying`). That is the whole reason this harness can be
built without touching production code: we own the clock and we own every edge.

The simulation runs in **virtual time** at a fixed tick rate (default 20 Hz, configurable) with a
seeded RNG. No sleeps, no real timers: a 4‑minute walk simulates in milliseconds and is bit‑for‑bit
reproducible from `(scenario, seed)`.

## 2. Layout — all new files

```
Sources/PointSim/                 # new library target (macOS 14+/iOS 17+, depends on PointCore)
  Clock.swift                     # virtual clock + SplitMix64 seeded RNG
  Scenario.swift                  # Codable scenario schema + validation
  World/Walker.swift              # path following, speed, pauses, GPS noise, accuracy, dropouts
  World/ArmModel.swift            # heading profiles, IMU drift/bias, mount offset, jitter
  World/RouteSources.swift        # inline coords, fixture directions JSON, synthetic turn generator
  Fakes/ScriptedTranscriber.swift # SpeechTranscribing
  Fakes/ScriptedPlaces.swift      # PlaceSearching
  Fakes/FixtureRouteProvider.swift# RouteProviding (incl. reroute responses and injected failures)
  Fakes/RecordingGlove.swift      # GloveTransport with link faults, records commands + timestamps
  Fakes/RecordingHapticOutput.swift # PhoneHapticOutput
  Fakes/RecordingSpeech.swift     # SpeechPlaying
  Engine/SimulationEngine.swift   # the tick loop
  Engine/Trace.swift              # versioned trace model (Codable)
  Engine/HapticIntent.swift       # semantic haptic vocabulary (see §6)
  Report/Assertions.swift         # declarative expectation evaluation over a trace
  Report/MarkdownReport.swift
  Report/HTMLReport.swift         # self-contained single-file report (trace embedded)

Sources/PointSimCLI/main.swift    # new executable `point-sim`: run | list | serve | report
Tools/SimConsole/                 # static visualizer: index.html, app.js, style.css (no npm, no deps)
Scenarios/*.json                  # the scenario library (checked in, reviewed like tests)
Fixtures/routes/*.json            # recorded Apple Maps / legacy directions payloads
Tests/PointSimTests/              # unit tests for the harness itself
Tests/PointCoreTests/ScenarioSuite.swift  # one parameterized test that runs every Scenarios/*.json
```

Changed existing files, in total:

| File | Change |
| --- | --- |
| `Package.swift` | add `PointSim` target, `point-sim` executable, `PointSimTests` target |
| `.gitignore` | ignore `.sim-out/` |
| `CONTRIBUTING.md`, `docs/PROJECT_PLAN.md` | short pointer to this workflow |

`project.yml` and the Xcode app target are **not** touched: the iOS app keeps depending on the
`PointCore` product only, so no simulation code can reach the app bundle. No third‑party packages are
added; the console is vanilla HTML/JS/canvas and the server is `Network.framework`.

### Rules that keep this non‑invasive

1. No edits to `Sources/PointCore` or `App/` for harness convenience. If a scenario needs something
   unobservable, the fix is to record it at an existing boundary, not to add hooks to production code.
2. `PointSim` depends on `PointCore`'s public API only — no `@testable`. If a scenario needs a
   private detail, that is evidence the detail should be a public read‑only property, and it gets
   proposed as its own small PR with a stated product reason.
3. Determinism is enforced by the harness, not by production code: every call passes explicit `now:`.
4. Output goes to `.sim-out/` (gitignored). Scenarios, fixtures and expectations are checked in.

## 3. Scenario format

A scenario is JSON so a non‑Swift change (new case, tweaked tolerance) never requires new code. It is
decoded into `Codable` structs, validated up front, and rejected with line‑level errors.

```jsonc
{
  "schema": 1,
  "id": "sweep-to-find-direction",
  "title": "User sweeps their arm to find the first beacon",
  "tags": ["guidance", "sweep", "haptics"],
  "seed": 42,
  "tickHz": 20,
  "route": {
    "kind": "generated",             // inline | fixture | generated
    "origin": [42.3601, -71.0942],
    "legs": [ { "bearing": 0, "meters": 120 }, { "bearing": 90, "meters": 80 } ],
    "destinationName": "Shake Shack"
  },
  "voice": {
    "utterance": "take me to the nearest Shake Shack",
    "transcriberLatencyMs": 700,
    "candidates": [ { "name": "Shake Shack", "address": "…", "coordinate": [42.3612, -71.0930] } ],
    "userChoice": 0                   // or "ambiguous": chooser stays open until a timeline event
  },
  "link": { "connectAt": 0.0, "capabilities": ["heading", "gestures", "vibration"],
            "headingHz": 25, "latencyMs": 40, "dropRate": 0.0 },
  "walker": {
    "startAt": 2.0, "speedMps": 1.3,
    "gps": { "accuracyMeters": 4, "noiseMeters": 2, "updateHz": 1 }
  },
  "arm": {
    "mountOffsetDegrees": 0, "biasDriftDegPerMin": 0, "jitterDegrees": 1.5,
    "profile": [
      { "at": 2.0,  "hold": { "degrees": 200 } },
      { "at": 4.0,  "sweep": { "fromDegrees": 200, "toDegrees": 20, "degPerSec": 45 } },
      { "at": 12.0, "track": { "target": "activeBeacon", "errorDegrees": 3 } }
    ]
  },
  "timeline": [
    { "at": 30.0, "gesture": "checkDirection" },
    { "at": 45.0, "link": "disconnect" },
    { "at": 48.0, "link": "connect" }
  ],
  "expect": [
    { "noConfirmBefore": { "alignedWithinDegrees": 15 } },
    { "confirmPulses": { "min": 1, "max": 3, "duringBeacon": 0 } },
    { "eventOrder": ["voice.transcript", "route.ready", "nav.start", "haptic.confirm", "beacon.arrival"] },
    { "arrivalAt": { "beacon": "final", "beforeSeconds": 260 } },
    { "endState": "arrived" },
    { "silentAfter": "nav.arrived" }
  ]
}
```

`expect` entries are declarative predicates evaluated against the recorded trace by
`Report/Assertions.swift`. Adding an expectation type is a small enum case plus a pure function;
adding a *scenario* is a data file only.

## 4. The tick loop

```
for tick in 0..<maxTicks:
    now = t0 + tick / tickHz
    apply timeline events due at now          (gestures, link faults, pause, reroute trigger, replan)
    walker.advance(to: now)                    → CLLocation (noise, accuracy, dropout, staleness)
    if a GPS fix is due:  controller.updateLocation(fix, now: now)
    arm.heading(at: now, world: world)         → HeadingReading (mount offset, drift, jitter, clock skew)
    if a heading packet is due: controller.receive(.heading(reading), now: now)
    controller.tick(now: now)                  // mirrors the app's ~10 Hz foreground loop
    recorder.capture(now, controller, glove, hapticOutput)
    stop when endState reached, or budget exceeded
```

The recorder drains `RecordingGlove.commands` and `RecordingHapticOutput` calls each tick, so every
motor pulse is timestamped in virtual time and attributable to the frame that caused it.

## 5. Trace format and reports

One versioned JSON document per run — the single artifact that tests, the console and the report all
read:

```jsonc
{
  "schema": 1,
  "scenario": { "id": "...", "seed": 42, "hash": "sha256 of scenario file" },
  "code": { "gitSha": "…", "dirty": false, "tickHz": 20 },
  "route": { "checkpoints": [[lat,lon], …], "beacons": [{ "coordinate": [..], "final": false }] },
  "frames": [ { "t": 12.35, "lat": .., "lon": .., "acc": 4.1, "heading": 18.2, "headingAcc": 2,
                "state": "navigating", "quality": "usable", "beaconIndex": 1,
                "status": "checking", "errorDeg": -6.4, "conservativeDeg": 11.9, "distanceM": 41.2,
                "phoneIntensity": 0.62 } ],
  "events": [ { "t": 12.60, "kind": "haptic.confirm", "detail": { "durationMs": 180, "intensity": 160 } } ],
  "results": [ { "expectation": "confirmPulses", "passed": true, "detail": "2 pulses" } ],
  "metrics": { "timeToFirstConfirm": 6.2, "sweepSecondsToAlignment": 3.1, "confirmPulses": 7,
               "falseConfirms": 0, "meanAbsErrorWhileConfirming": 4.8, "arrivalSeconds": 214.0 }
}
```

`point-sim run` writes `.sim-out/<scenario-id>/trace.json`, a Markdown summary (for PR comments), and
a **self‑contained HTML report** with the trace embedded, so a failing run can be attached to an issue
and replayed by anyone with a browser and no toolchain.

`metrics` also enables cheap regression guards: check in `Scenarios/<id>.baseline.json` and fail when a
metric moves beyond a stated tolerance, so tuning the thresholds in `DirectionFeedbackEngine` shows up
as an explicit, reviewed baseline change instead of a silent behavior drift.

## 6. Haptic vocabulary, today and later

Production today has exactly two commands: `confirm(durationMs:intensity:)` and `stop` — alignment
confirmation only, no direction codes. The plan for "different haptics for different triggers" is to
record a **semantic layer** in the harness, not to invent firmware behavior:

```swift
public enum HapticIntent: String, Codable {
    case confirmAlignment, stop            // exist today
    case sweepHint, turnLeft, turnRight    // reserved; not emitted until the product defines them
    case beaconReached, arrived, offRoute, lowBattery
}
```

A `HapticIntentMapper` translates observed `HapticCommand`s plus surrounding trace context into
intents. Scenarios assert on intents, so when the real protocol grows directional or arrival codes,
the mapper changes in one place and the scenario files keep working. Until then, any scenario
asserting a reserved intent is reported as `untested — not yet implemented` rather than failing, which
makes the suite a live checklist of the hardware contract in `docs/HARDWARE_INTERFACE.md`.

## 7. Integration with the existing test suite

`Tests/PointCoreTests/ScenarioSuite.swift` is one parameterized swift‑testing test:

```swift
@Test(arguments: ScenarioCatalog.all)
@MainActor func scenario(_ file: ScenarioFile) throws {
    let trace = try SimulationEngine(scenario: file.scenario).run()
    let results = Assertions.evaluate(file.scenario.expect, against: trace)
    TraceArtifact.write(trace, to: .simOut)   // always, so failures are replayable
    #expect(results.failures.isEmpty, "\(results.summary)")
}
```

So `swift test` keeps being the single command, adding a scenario needs no Swift, and every failure
leaves a replayable trace behind. Existing tests are untouched.

Note the platform reality: `PointCore` imports CoreLocation/MapKit, so `swift test` and the harness run
on **macOS only** (same as today). CI, if we add it, needs a macOS runner; the console itself is static
and runs anywhere once a trace exists.

## 8. The console (visualizer + debugging controls)

`Tools/SimConsole`, plain HTML/JS/canvas, started with:

```sh
swift run point-sim serve            # http://127.0.0.1:8787, localhost only
swift run point-sim run sweep-to-find-direction --html   # offline single-file report
```

The server is a small `NWListener` in `PointSimCLI` serving the static files plus a JSON API:
`GET /api/scenarios`, `POST /api/run` (scenario + parameter overrides → trace), `GET /api/trace/<id>`,
`POST /api/live/step` for the interactive mode, `POST /api/report`. No database, no build step.

Panels:

- **Map view** — route polyline, beacons (active highlighted), walker dot with accuracy circle,
  heading ray with the ±15°/±25° alignment cones drawn, breadcrumb trail.
- **Timeline** — lanes for feedback status, glove pulses, phone haptic intensity, GPS quality, link
  state, and event markers; click a marker to jump the playhead.
- **Transport** — play/pause, step frame, ×0.25–×8 speed, scrub, jump to next event or next failure.
- **Inspector** — the frame's raw numbers (bearing, heading, error, conservative error, distance,
  accuracy) so a disputed confirm can be checked by hand.
- **Expectations** — pass/fail/untested list; clicking a failure seeks to the offending frame and
  flags it.
- **Debug controls** — sliders for the knobs that matter (GPS noise/accuracy, heading accuracy, IMU
  drift, mount offset, sweep rate, tick rate, seed) and re‑run in place; a diff view comparing the new
  trace's metrics to the previous run.
- **Live mode** — drag the walker, rotate a heading dial, toggle connection, and watch feedback and
  haptic output respond in real time; "save as scenario" writes the interaction out as a new
  `Scenarios/*.json` for review. This is how an interesting manual finding becomes a regression test.
- **Report** — export Markdown/HTML, and "flag this frame" which attaches a note at a timestamp and
  includes it in the report.

## 9. Scenario library to ship first

| Scenario | What it protects |
| --- | --- |
| `voice-to-route-happy` | spoken command → transcript → candidates → selection → route ready → start |
| `voice-ambiguous-chooser` | multiple candidates, chooser, late selection, no navigation before choice |
| `straight-leg-alignment` | first confirm only after 0.2 s stable alignment; eased 180 ms pulses, requests spaced ≥0.2 s |
| `sweep-to-find-direction` | continuous arm sweep produces exactly one confirm window at the beacon |
| `wrong-direction-persistent` | pointing 180° off never confirms, whatever the GPS quality |
| `corner-sequence` | beacon advance retargets feedback; old bearing stops confirming |
| `closely-spaced-turns` | two beacons <20 m apart do not double‑advance or latch |
| `gps-degraded` / `gps-dropout` | degraded quality suppresses confirmation and recovers cleanly |
| `off-route-reroute` | 3 off‑route fixes → reroute, no haptics during reroute, new route restarts at 0 |
| `link-drop-midroute` | disconnect stops output, reconnect requires fresh heading before confirming |
| `imu-drift-and-mount-offset` | drift beyond tolerance surfaces as no‑confirm, not as a false confirm |
| `gesture-pause-resume` | gesture debounce, paused sessions ignore fixes, resume re‑arms |
| `arrival-final` | destination arrival emits once, state `arrived`, silence afterwards |
| `arrival-then-idle` | no motor command after arrival even with continued heading packets |

Each is one JSON file plus its expectations; the table doubles as the coverage report.

## 10. Phasing

Sizing is in my own working sessions, not team‑days.

1. **Session 1 — harness core.** Clock, RNG, scenario schema, walker, arm model, fakes, engine, trace
   writer, `point-sim run`, Markdown report, three scenarios (`straight-leg-alignment`,
   `wrong-direction-persistent`, `arrival-final`), `ScenarioSuite` wired into `swift test`.
2. **Session 2 — replay console.** Static visualizer over a trace file, map + timeline + transport +
   inspector + expectations, self‑contained HTML export.
3. **Session 3 — live console and full library.** `point-sim serve`, parameter sliders, live mode,
   save‑as‑scenario, the remaining scenarios above, metric baselines.
4. **Session 4 — CI and hardware in the loop.** macOS CI job publishing reports on PRs; import real
   IMU/BLE captures from the glove as scenario inputs so recorded hardware behavior replays through
   the same assertions.

Phases 1–2 are independently useful; nothing later is required for them to pay off.

## 11. Risks and open questions

- **macOS‑only execution.** CoreLocation/MapKit keep the suite off Linux CI. Accepted; a pure‑geometry
  split of `PointCore` is out of scope here.
- **Simulation fidelity is a model, not the world.** GPS multipath, magnetic disturbance indoors, and
  real ERM motor ramp‑up are approximations. The harness is for logic regressions and tuning
  comparison; it does not replace field tests, and the report should say so on every page.
- **Firmware timing is only modelled as latency, loss and clock skew.** Real firmware behavior
  (local pulse termination, queue clearing after reconnect) is asserted at the command boundary only
  until phase 4.
- **Open:** do we want the directional/arrival haptic vocabulary of §6 to become real product
  behavior, and if so which triggers? The harness is ready for it, the product decision is not made.
- **Open:** should metric baselines block CI or only annotate the PR? Starting as annotate‑only avoids
  a noisy gate while thresholds are still being tuned.
