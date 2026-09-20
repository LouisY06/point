# Voice-controlled indoor demo

Tap the hand/microphone in Point and say **“Can you go into demo mode?”** Point opens the camera so you can place virtual beacons around the room. The former Test beacons shortcut is removed. You can also type the same request using the keyboard alternative.

This is separate from the sample outdoor route and from the new MBTA bus/train arrival test. Entering indoor demo ends any active walking/transit session, pending destination confirmation, speech capture, and route haptics. It stops GPS updates. No place search, Apple Maps route, transit request, or geocoding is needed to enter or operate the indoor route.

## Try it on an iPhone

1. Tap the hand and request demo mode. Equivalent requests include “enter indoor demo mode,” “start demo mode,” and “set up virtual beacons.”
2. Allow camera access, then slowly scan a well-lit room with textured surfaces.
3. Aim down at the floor about 0.5–8 metres away horizontally. A gold ring appears on a detected floor surface. Tap **Place beacon**: the tall marker grows upward from that exact ring position. Add up to eight in visit order. Point announces each placement.
4. Tap **Start route**. Hold the phone flat, screen down, with its camera/top edge pointing along your finger. Keep the rear camera unobstructed. Phone vibration strengthens as you point toward the active beacon.
5. Approach within 35 cm horizontally for 0.5 seconds to advance. Point announces the next beacon, then announces completion after the last.
6. **Pause route** stops guidance; **Resume route** resumes the same route. Placement is locked after starting; **Demo help → Clear all beacons** starts a new route. **Done** ends camera tracking and returns home.

Beacons exist only in the current AR session. App switching, locking, or camera interruption clears them because the tracking origin may change. Scan and place them again on return. Uncertain or stale camera tracking immediately silences guidance. No camera frames are recorded or uploaded.

## What the glove can use later

The targets are real local 3D positions from camera raycasts and AR anchors, not simulated GPS coordinates. Point already calculates horizontal distance and pointing angle through `LocalBeaconGeometry` in the shared Swift core. The same calculation can accept a glove pointing vector once that vector is expressed in the camera's coordinate frame.

The current indoor demo uses the phone's camera pose and phone motor. A Bluetooth echo, or an outdoor true-north heading alone, does not make indoor glove guidance work. The AR session currently uses gravity alignment, whose horizontal axes are local to that session.

To complete the glove path:

- Supply fresh sensor orientation and motor capabilities through the firmware transport.
- Calibrate glove orientation and its mounting offset into the current AR world frame. Track the calibration's session identity and invalidate it after AR reset, reconnect, or sensor recalibration.
- Use the phone's tracked position as the wearer-position approximation; require the phone to remain with the wearer and account for phone-to-hand offset when necessary.
- Calculate the angle to the current local anchor, then send supported finite vibration commands through the glove transport. Preserve stale-data, disconnect, and tracking-loss stops.
- Keep the camera session running while using the glove. An IMU does not independently locate the glove or recover the room's beacon positions.

Physical glove taps also require a firmware gesture event wired to start listening. This change uses the app's existing hand/microphone tap; it does not infer tap gestures from the echo service.

## Implementation and checks

- `IndoorDemoCommand` recognizes complete app commands before destination interpretation, map/transit logic, or GPS checks. It does not send the request to an LLM for classification. It rejects negated requests and avoids stealing destinations such as “Demo Cafe” or “Beacon Street.” Speech transcription still uses the app's configured speech providers; typing requires no transcription.
- `PointViewModel.Stage.indoorDemo` owns presentation and isolates the mode from route state. Exiting returns to the home state rather than resuming an old journey.
- `CameraBeaconTestView` owns placement, ordered guidance, permission recovery, and temporary AR anchors. Spoken instructions reuse Point's existing speech/VoiceOver behavior.
- `--demo-mode` in a Debug launch submits the same “Can you go into demo mode?” text to the normal command path. The simulator displays a physical-iPhone requirement; it never fabricates room tracking.

Automated command cases cover common wording, punctuation, whitespace, negation, and map/transit destination false positives. Camera placement, indoor drift, phone motor output, and future glove calibration still require physical testing.

## Floor placement and presentation

The camera panel shows a short task heading, one current instruction, and the relevant actions. Help holds the grip instructions, vibration test, reset, and privacy details. The panel grows with Dynamic Type and scrolls when needed instead of covering the whole camera.

The floor ring and placed anchor share the same raycast transform. Placement uses detected horizontal plane geometry, prioritizes ARKit floor classification, and rejects known tables, seats, and walls. Without floor classification, it chooses the lowest unclassified horizontal plane at least 70 cm below the phone. That fallback is a height estimate, so room testing is still needed; it cannot guarantee semantic floor identification. No estimated-plane or floating-point placement fallback is used. Missing, stale, or uncertain tracking hides the ring and disables placement.

Beacons rise over 380 ms from their floor origin. Reduce Motion replaces the rise with a short fade. The existing tall columns and camera-facing route numbers remain. `--demo-mode --preview-indoor-ui` renders an explicitly labeled Debug-only layout fixture for simulator typography checks; it does not simulate working AR.
