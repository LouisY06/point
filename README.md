# Point

A native SwiftUI navigation app: speak a destination, confirm a place, then point a glove toward the next route beacon. A short vibration confirms alignment.

The interface is a white glove outline with an unframed white microphone over a softly moving, lightly blurred map background. Selecting a destination reveals the map through an eased circular zoom centered on that button. Reduce Motion replaces the zoom with a crossfade.

## Run

Requirements: macOS with Xcode 16 or later (including Swift Testing), an installed iPhone simulator, and network access for the Google Maps package and map tiles. The app targets iOS 17+. No API credentials or glove are needed for the default preview. XcodeGen is optional unless changing project configuration.

```sh
git clone https://github.com/LouisY06/point.git
cd point
open Point.xcodeproj
```

The repository is private; teammates need repository access from its owner. For a physical iPhone, select your own development team in local signing settings.

Open `Point.xcodeproj`, select the **Point** scheme, and run on an iPhone simulator. Tap the glove voice button to play a staged sample voice-to-map transition (waveform, transcript, route preparation, map reveal), with no recording or input. **Preview** runs the same explicitly labeled sample route. The preview uses a synthetic route and simulated glove, not real directions or hardware telemetry.

XcodeGen regenerates the project from `project.yml`:

```sh
xcodegen generate
swift test
swift run point-demo
```

`PointCore` is a local Swift package, usable on iOS 17+ and macOS 14+. The app links Google Maps iOS SDK 10.8.0. Until its key is configured, the UI uses an Apple map preview.

## Live development configuration

In your **local, unshared** Xcode run scheme, set:

| Variable | Purpose |
| --- | --- |
| `POINT_LIVE_VOICE=1` | Opt into real recording instead of the temporary animation preview |
| `OPENAI_API_KEY` | OpenAI audio transcription, default `gpt-transcribe` |
| `GOOGLE_MAPS_SERVER_KEY` | Google Places API (New) and Routes API |
| `GOOGLE_MAPS_IOS_KEY` | Google map rendering, restricted to the app bundle |

The development app records an M4A clip, transcribes it, searches nearby Google places, asks you to select a match, and requests a walking route. Location permission and an actual or simulated GPS fix are required. The microphone stops after 20 seconds; audio is removed locally after reading. Typing uses the same place search.

Provider keys are never committed. Direct credential injection is **Debug-only** for local development. Before distributing the app, inject authenticated backend implementations of the speech/search/route protocols; the current Release app deliberately does not load provider secrets. This repository does not yet deploy that backend. OpenAI transcription and Google services have not been exercised against a funded account in this workspace.

## Current scope

- Implemented: native UI, outline-to-map transition, recording, transcription and Google REST clients, destination selection, route parsing, checkpoint/beacon generation, pointing feedback, simulated transport, and core tests.
- Hardware integration pending: BLE service/characteristic IDs, packet format, heading calibration and physical motor tuning. `GloveTransport` is the replacement boundary; the app does not claim a real glove is connected.
- Real locked-screen/background navigation, on-device microphone interruption handling, and outdoor navigation accuracy still require device testing and further integration.
- No cameras, computer vision, glasses SDK, room scans, streaming, old dashboard, or rehab workflow were copied.

## Team handoff

Start with the [detailed project plan](docs/PROJECT_PLAN.md): current status, architecture, existing algorithm, hardware contract, workstreams, milestones, and known gaps. See [contributing](CONTRIBUTING.md) for the branch/review workflow, [app outline](docs/APP_OUTLINE.md) for the user journey, [algorithm notes](docs/REUSE_AUDIT.md), and [hardware interface](docs/HARDWARE_INTERFACE.md).
