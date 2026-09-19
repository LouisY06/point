# Point

A native SwiftUI navigation app: speak a destination, confirm a place, then point a glove toward the next route beacon. A short vibration confirms alignment.

The interface uses the selected sketch hand and its embedded microphone over a softly moving, lightly blurred Apple map. The hand pulls in a native transcript banner. Selecting a destination reveals the map through an eased circular zoom centered on that button. Reduce Motion replaces the zoom with a crossfade.

## Run

Requirements: macOS with Xcode 16 or later (including Swift Testing), an installed iPhone simulator, and network access for Apple map tiles, search, and directions. The app targets iOS 17+. No API credentials or glove are needed for the default preview. XcodeGen is optional unless changing project configuration.

```sh
git clone https://github.com/LouisY06/point.git
cd point
open Point.xcodeproj
```

The repository is private; teammates need repository access from its owner. For a physical iPhone, select your own development team in local signing settings.

Open `Point.xcodeproj`, select the **Point** scheme, and run on an iPhone simulator. Tap the glove voice button to record a destination; your words appear as you speak (Apple Speech, on the phone). With an OpenAI key (see below) the final transcript comes from OpenAI; without one the on-device text is used. An unambiguous request (“McDonald's”, “the nearest CVS”, “the McDonald's on Mass Ave”) routes immediately; ambiguous results show a chooser. Launching with the `--preview-route` argument runs a staged sample voice-to-map transition (hand pull, transcript, route preparation, map reveal) with no recording or input. That preview uses a synthetic route and simulated glove, not real directions or hardware telemetry.

XcodeGen regenerates the project from `project.yml`:

```sh
xcodegen generate
swift test
swift run point-demo
```

`PointCore` is a local Swift package, usable on iOS 17+ and macOS 14+. Apple MapKit handles map display, place search, and walking directions. No Google SDK, Google account, maps API key, or maps backend is required.

## Device connection

The ESP32-C6 firmware and app now share a Bluetooth connection test. On a physical iPhone, open the device icon at the top right, scan for **BT Test C6**, select it, and wait for **Connection verified**. This checks a real write/notification round trip; the firmware does not yet expose sensors or control vibration. The simulator can preview the setup screen but cannot perform this hardware test.

See [device setup and troubleshooting](docs/DEVICE_SETUP.md) and [firmware build instructions](Firmware/BTTest/README.md). No provider API keys are needed for the connection test.

## Live development configuration

The microphone always records and transcribes on the phone. For OpenAI's final transcript, supply a Debug-only key in either of two ways:

- In your **local, unshared** Xcode run scheme, set `OPENAI_API_KEY` (OpenAI audio transcription, default `gpt-transcribe`). This only applies to launches from Xcode.
- For launches from the home screen, copy a `.env` file containing `OPENAI_API_KEY=…` into the app's Documents folder. `xcrun devicectl device copy to --device <id> --domain-type appDataContainer --domain-identifier com.point.navigator --source .env --destination Documents/dev.env`

The development app records an M4A clip, transcribes it, searches nearby Apple Maps places, asks you to select a match, and requests a walking route. Location permission and an actual or simulated GPS fix are required. The microphone stops after 20 seconds; audio is removed locally after reading. Typing uses the same Apple Maps search and works without any API credentials or live-voice setting. Allow location access and wait for a GPS fix; in the simulator, select a simulated location. If the first search asks you to wait for location, retry once a fix arrives.

Provider keys are never committed. Direct credential injection is **Debug-only** for local development. Before distributing the app, inject an authenticated backend implementation of the speech protocol; the current Release app deliberately does not load provider secrets. This repository does not yet deploy that backend. OpenAI transcription still needs validation with the actual account and an iPhone. Maps run directly through MapKit.

## Verified so far

The Apple Maps migration passes 19 offline tests plus a separate live search-and-directions test. iPhone (unsigned) and simulator builds pass. The simulator was checked end to end with typed “MIT Museum,” explicit address selection and a real Apple walking route, using simulated Cambridge GPS. Physical-phone voice and glove navigation remain unverified.

## What still needs to be done

1. **Verify live input on an iPhone:** type a destination and check the selected walking route; then configure OpenAI and verify real recording/transcription.
2. **Connect real glove guidance:** bench-test the BLE echo link, agree on heading/haptic packets, implement the navigation transport, calibrate true north, and drive the physical motor. Echo confirmation alone is not navigation.
3. **Finish walking-session UI:** show the active beacon, pause/resume, arrival and degraded data; wire automatic rerouting and the foreground stale-data watchdog.
4. **Field-test the algorithm:** validate corners, gradual bends, closely spaced turns, GPS uncertainty and arrival thresholds. Beacons are important route points, not every 15 metres; internal checkpoint resampling is still present.
5. **Prepare distribution:** add the authenticated voice backend, validate interruptions/background behavior, and test accessibility and animation performance on phones.

See the [prioritized acceptance checklist](docs/PROJECT_PLAN.md#remaining-work-prioritized) for concrete completion criteria.

## Current scope

- Implemented: native UI, outline-to-map transition, recording, OpenAI transcription and native Apple Maps clients, destination selection, route parsing, checkpoint/beacon generation, pointing feedback, simulated transport, and core tests.
- Bluetooth bring-up implemented: ESP32-C6 echo firmware, device discovery/setup, notification subscription, round-trip verification, disconnect and retry. Live iPhone-to-board verification is still pending.
- Navigation hardware integration pending: sensor/haptic protocol, heading calibration and physical motor tuning. `GloveTransport` is the replacement boundary; echo-link verification does not imply working glove guidance.
- Real locked-screen/background navigation, on-device microphone interruption handling, and outdoor navigation accuracy still require device testing and further integration.
- No cameras, computer vision, glasses SDK, room scans, streaming, old dashboard, or rehab workflow were copied.

## Team handoff

Start with the [detailed project plan](docs/PROJECT_PLAN.md): current status, architecture, existing algorithm, hardware contract, workstreams, milestones, and known gaps. See [contributing](CONTRIBUTING.md) for the branch/review workflow, [app outline](docs/APP_OUTLINE.md) for the user journey, [algorithm notes](docs/REUSE_AUDIT.md), and [hardware interface](docs/HARDWARE_INTERFACE.md).
