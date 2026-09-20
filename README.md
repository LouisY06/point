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

## Public transportation mode

There is no mode switch. A walk of up to about 10 minutes just walks. Anything longer asks by voice — "Copley is about a 25 minute walk. Want to take the T or a bus instead?" — and **yes / no**, or any transit or walking phrase, answers it. Saying "take the T to…" or "by bus" plans transit straight away; "walk me to…" skips the question. A transit trip is planned walk → ride → walk from [MBTA](https://api-v3.mbta.com) route data and Apple walking directions, offered as up to three trips to confirm, and then:

- guides you with normal beacons to the stop; the last one sits **on the stop to board** and is **green**, the stop to get off is **red**, and the ride between them is a solid line (subway lines in their MBTA colours, buses in slate blue) with no beacons;
- stops all pointing feedback while you wait and ride;
- watches live MBTA predictions for **your line, direction and branch**, and plays a distinct **four-pulse buzz** when your vehicle is at the platform, then again when it is time to get off;
- boards and alights automatically from vehicle tracking, with **I'm at the stop / I'm on board / Not on board / I'm off** as overrides;
- handles transfers at rapid-transit stations the same way, and holds walking instructions after you step off until GPS returns outside;
- says when live data or GPS is lost and when it returns, and offers **Replan** if you seem to be on the wrong train or missed your stop.

No key is required (20 MBTA requests/min); add `MBTA_API_KEY` to `.env` for the demo. See [the transit design](docs/TRANSIT_MODE_PLAN.md). Not covered: commuter rail, ferries, fares, and any claim of obstacle safety.

## Device connection

For indoor virtual beacons, tap the hand and say **“Can you go into demo mode?”** (or type it). Place up to four camera beacons around the room, pointing the glove toward the first marker while placing it. Experimental pocket mode then stops the camera and estimates movement from phone steps and gyro turns; the glove supplies pointing and vibration. Face beacon 1 and stand still while pocketing the unlocked phone during the countdown. Position is approximate. The iOS 26 locked-screen test uses a Live Activity and background Bluetooth; touch guard blocks accidental taps. Sustained locked-screen motion delivery still needs device verification. Camera-tracked guidance is also available in demo settings. See [indoor demo](docs/INDOOR_DEMO.md).

Open **Device setup**, connect **Point S3**, and complete the two-pose pointing setup. Live map arrows and guidance use the glove IMU/magnetometer; automatic vibration requires the finger within 30° of level. A lowered hand stays silent. Phone-as-glove controls have been removed. See [glove setup](docs/DEVICE_SETUP.md).

The current glove uses **ESP32-S3 + BNO055 primary compass + MPU6050 backup + DRV2605L**. See [the updated hardware README](Firmware/README.md) and [app/firmware integration contract](docs/FIRMWARE_APP_PROTOCOL.md). The original circuit sketch remains USB-only. The new [S3 ESP-IDF firmware](Firmware/S3Firmware/README.md) has been uploaded and passed BLE/sensor/motor-command bench checks; the matching app implements quaternion mounting calibration. Physical pointing, vibration and iPhone-to-glove end-to-end validation remain pending.

The older ESP32-C6 firmware and app share a Bluetooth connection test. On a physical iPhone, open the device icon at the top right, scan for **BT Test C6**, select it, and wait for **Connection verified**. This checks a real write/notification round trip; the firmware does not yet expose sensors or control vibration. The simulator can preview the setup screen but cannot perform this hardware test.

See [device setup and troubleshooting](docs/DEVICE_SETUP.md) and [firmware build instructions](Firmware/BTTest/README.md). No provider API keys are needed for the connection test.

## Live development configuration

Copy `.env.example` to `.env` and fill in `OPENAI_API_KEY` and `ELEVENLABS_API_KEY`. Leave the voice/model defaults to try Caleb — Trusted Guide with Eleven Flash v2.5. `.env` is ignored by Git and never bundled. See [voice setup](docs/VOICE_SETUP.md) for installation and voice selection.

Apple Speech shows live words. OpenAI optionally supplies the final transcript; ElevenLabs optionally speaks the app's short replies. Supply Debug-only credentials in either of two ways:

- In your **local, unshared** Xcode run scheme, set the variables from `.env.example`. These only apply to launches from Xcode.
- For launches from the home screen, copy your local `.env` into the installed app's Documents folder: `xcrun devicectl device copy to --device <id> --domain-type appDataContainer --domain-identifier com.point.navigator --source .env --destination Documents/dev.env`. Repeat after changing keys; a rebuild alone does not copy them.

Spoken replies cover destination choices, route readiness, navigation start, arrival, off-route detection and errors. Tapping the microphone, cancelling, backgrounding or an audio interruption stops pending/playback speech. No generated speech plays during capture. When ElevenLabs is missing or fails, the iPhone voice reads the reply. VoiceOver users receive native accessibility announcements instead of a second simultaneous voice. OpenAI interprets city-only requests, clarifications and corrections. Map data controls city and duration confirmations. Point speaks these short replies in the same talking card; see [conversation cases](docs/POINT_AI_SCENARIOS.md).

The development app records an M4A clip, transcribes it, searches nearby Apple Maps places, asks you to select a match, and requests a walking route. Location permission and an actual or simulated GPS fix are required. The microphone waits for three seconds of observed quiet after recognized speech (four seconds without live words), with 60 seconds as a hard limit; audio is removed locally after reading. Typing uses the same Apple Maps search and works without any API credentials or live-voice setting. Allow location access and wait for a GPS fix; in the simulator, select a simulated location. If the first search asks you to wait for location, retry once a fix arrives.

Provider keys are never committed. Direct credential injection is **Debug-only** for local development. Before distributing the app, inject authenticated backend implementations of `SpeechTranscribing` and `SpeechSynthesizing`; the Release app deliberately does not load provider secrets and uses native speech. This repository does not yet deploy that backend. Maps run directly through MapKit.

## Verified so far

Voice integration: offline voice/route checks pass; live ElevenLabs speech with character timestamps, OpenAI transcription and structured navigation-intent requests have been exercised using local development credentials. The signed app installs on the connected iPhone. Real outdoor conversations and destination accuracy still need hands-on testing.

The Apple Maps migration passes 19 offline tests plus a separate live search-and-directions test. iPhone (unsigned) and simulator builds pass. The simulator was checked end to end with typed “MIT Museum,” explicit address selection and a real Apple walking route, using simulated Cambridge GPS. Physical-phone voice and glove navigation remain unverified.

## What still needs to be done

1. **Verify live input on an iPhone:** type a destination and check the selected walking route; then configure OpenAI and verify real recording/transcription.
2. **Connect real glove guidance:** bench-test the BLE echo link, agree on heading/haptic packets, implement the navigation transport, calibrate true north, and drive the physical motor. Echo confirmation alone is not navigation.
3. **Finish walking integration:** phone testing now shows the active beacon, pause/resume, arrival and degraded data with a foreground stale-data loop. Validate it on-device, extend lifecycle handling to the real glove, and wire automatic rerouting.
4. **Field-test the algorithm:** validate corners, gradual bends, closely spaced turns, GPS uncertainty and arrival thresholds. Beacons are important route points, not every 15 metres; internal checkpoint resampling is still present.
5. **Prepare distribution:** add the authenticated voice backend, validate interruptions/background behavior, and test accessibility and animation performance on phones.

See the [prioritized acceptance checklist](docs/PROJECT_PLAN.md#remaining-work-prioritized) for concrete completion criteria.

## Current scope

- Implemented: native UI, outline-to-map transition, recording, OpenAI transcription and native Apple Maps clients, destination selection, route parsing, checkpoint/beacon generation, pointing feedback, simulated transport, and core tests.
- Bluetooth bring-up implemented: ESP32-C6 echo firmware, device discovery/setup, notification subscription, round-trip verification, disconnect and retry. Live iPhone-to-board verification is still pending.
- Glove integration implemented: negotiated quaternion/motor protocol, two-pose mounting setup, forward-pointing gate and indoor direction referencing during first beacon placement. Physical pointing, motor sensation and navigation accuracy still need worn-glove trials.
- Active walks now request background GPS so route progress can continue while locked. Pocket demo retains its glove link in the background with an active Live Activity; camera-mode test points clear on backgrounding. Locked-screen behavior, audio interruptions and outdoor accuracy still require device testing.
- Optional ARKit camera placement supports nearby test beacons; normal Apple Maps navigation remains camera-free. No glasses SDK, streaming, old dashboard or rehab workflow was copied.

## Team handoff

Start with the [detailed project plan](docs/PROJECT_PLAN.md): current status, architecture, existing algorithm, hardware contract, workstreams, milestones, and known gaps. See [contributing](CONTRIBUTING.md) for the branch/review workflow, [app outline](docs/APP_OUTLINE.md) for the user journey, [algorithm notes](docs/REUSE_AUDIT.md), and [hardware interface](docs/HARDWARE_INTERFACE.md).
