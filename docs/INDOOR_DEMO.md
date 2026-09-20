# Voice-controlled indoor demo

Tap the hand/microphone in Point and say **“Can you go into demo mode?”** Point opens the camera so you can place virtual beacons around the room. The home Test beacons button opens the same mode. You can also type the same request using the keyboard alternative.

This is separate from the sample outdoor route and from the new MBTA bus/train arrival test. Entering indoor demo ends any active walking/transit session, pending destination confirmation, speech capture, and route haptics. Placement uses AR tracking; the default pocket pointing test uses a fixed standing position, while the optional walking mode uses experimental motion estimates; no GPS fix is required for room guidance. No place search, Apple Maps route, transit request, or geocoding is needed to enter or operate the indoor route.

## Try it on an iPhone

1. Open demo mode. Connect the glove and complete its one-time down/up mounting setup if needed. The saved mapping restores for the same glove.
2. **Relaxed demo** is on by default. Options, phone height, and orientation logs are under **⋯**. Aim the camera at a spot 0.5–8 m away horizontally until the marker appears.
3. Point your glove level toward the marker and tap **Place 1**. Keep pointing briefly while the app captures the shared direction reference. The default mode allows exactly one beacon.
4. Stay in the same spot and tap **Start pointing test**. Pocket your phone, turn in place, and point with the glove. The camera stops immediately. Phone movement, steps and gyro turns do not update the standing position; this mode does not track walking, distance changes or arrival. Lowering your hand still stops vibration.
5. Touch guard blocks accidental taps; hold for two seconds to reveal controls. **Pause / Resume** retains the same standing position. **End pointing test** ends guidance, and **Place a new route** starts over. A Live Activity supports the existing locked-screen BLE test.
6. Glove heading may still drift. Under **⋯ → Orientation logs**, use **Mute motor for drift check** and compare finger bearing/target error with the glove physically fixed, then with vibration enabled. Muting does not change the direction reference. An unchanging physical pose is essential; the app cannot infer actual heading error from its own sensor reading.
7. For the previous walking experiment, clear the beacon and turn off **Single beacon pointing test** under **⋯ → Demo settings**. Place up to four beacons, face beacon 1, and start the pocket test. Pocket the phone and stand still during the eight-second countdown. Steps and gyro turns then estimate your position; they accumulate error. This remains experimental. **Point at any beacon**, configurable step length and manual **Next beacon** are available only in that mode.
8. To walk using camera position, turn off **Camera off after placement** before starting. Keep the camera uncovered. Camera mode advances after reaching within 35 cm horizontally for 0.5 seconds.

The camera occupies its own unobstructed viewport between the compact header and action strip; controls do not cover its placement ray. The first placement needs a shared direction reference because gravity-aligned AR coordinates and unsettled IMU yaw have independent horizontal origins. Automatic north alignment would require a reliable common north reference, which relaxed mode explicitly does not assume.

**Optional walking estimate, not measured position:** the four-beacon pocket experiment snapshots all beacon coordinates and the last tracked camera position. It assumes the wearer is facing beacon 1 when the countdown ends; no movement is counted during pocketing. Gravity-projected user acceleration identifies alternating step peaks; the step length is a configurable assumption, not an independently measured distance. Gravity-projected phone gyro rotation updates body bearing, assuming forward walking and a fixed pocket. Phone direction never substitutes for glove pointing. It does not double-integrate acceleration or invent a confidence radius. The default single-beacon test deliberately holds the standing position fixed and makes no walking-position claim.

The iOS 26 locked-screen test starts a Live Activity before backgrounding and retains the established glove link with the `bluetooth-central` background mode. Real BLE sensor replies also drive guidance updates. A bounded UIKit background task covers the transition; it does not provide unlimited runtime. The motion estimator continues while iOS delivers motion samples, and stale/missing samples mute feedback. No silent audio or unrelated location keepalive is used. Spoken navigation cues use the audio background mode. Actual sustained locked-screen sensor delivery and physical haptics remain unverified until an iPhone lock/walk run is collected. If Live Activities are unavailable, the app falls back to foreground touch protection.

Touch guard covers every app control immediately on starting pocket setup; holding it for two seconds reveals the controls. With the Live Activity active, locking/backgrounding preserves the demo instead of clearing it. Camera-only mode still clears on backgrounding. Force-quitting stops guidance. Pocket mode can be paused while motion estimation continues in the foreground; pausing during the initial countdown cancels setup. Duplicate motion samples are ignored; nonfinite samples or gaps over 300 ms invalidate the estimate. Stale readings mute haptics. Returning to camera mode requires placing a new route.

Beacons exist only in the current demo; pocket mode keeps a snapshot after pausing AR. In camera mode, app switching, locking or camera interruption clears them. In pocket mode with an active Live Activity, these lifecycle events preserve the snapshot and Bluetooth connection. In camera mode, ordinary phone rotation does not clear the room reference. A brief motion/feature-related tracking loss of up to one second mutes feedback but preserves alignment; longer gaps, relocalization, a session reset, or a glove reference change require placing beacons again. No camera frames are recorded or uploaded.

## Glove and room coordinates

The targets are local 3D positions from floor raycasts or the relaxed floor estimate and AR anchors. The camera supplies placement and starting position; it also supplies ongoing wearer position in camera mode. Pocket mode estimates wearer motion. Neither phone source supplies live glove pointing. Gravity-aligned AR axes do not inherently point north: `RoomGloveAlignment` records the difference between the first beacon's room bearing and the calibrated glove's heading (relative orientation in relaxed mode; magnetic heading in strict mode). The first placement marker must be at least 0.5 m away horizontally. Strict mode needs at least 12 distinct fresh samples spanning 1.5 seconds with no more than 5° variation. Relaxed demo needs at least 6 samples spanning 0.75 seconds with no more than 12° variation. Both require calibrated glove pointing and retain the hand-down cutoff. Relaxed mode uses fresh, healthy BNO055 quaternion orientation with a settled gyro even when system/magnetometer calibration is low. Readings are explicitly marked relative, never north-referenced. The firmware remains in NDOF mode: this does not disable the magnetometer or guarantee drift-free gyro-only yaw. Strict magnetic mode still invalidates its north reference on loss/acquisition of magnetic readiness. Relaxed mode has a separate reference identity, so compass calibration flags do not cancel the route. At a readiness transition, it compensates the short inter-sample yaw change to preserve continuity; this is approximate and can discard real rotation during that single interval. Corrections and their cumulative offset are logged. Brief gyro-quality loss gates pulses without erasing the physical mounting map. A real disconnect or explicit remount still changes the relative reference; the user can point at beacon 1 and tap **Restore glove direction**, preserving placed beacons.

The stored offset converts subsequent target bearings into that magnetic frame. Camera tracking resets still invalidate the room coordinates. A real glove reference change pauses guidance and offers restoration against beacon 1, without deleting the placed beacons. Losing the pointing gate silences vibration while position updates continue. The phone must remain with the wearer; there is no independent glove position estimate or correction for phone-to-hand separation.

Finite glove pulses are requested at most 5 Hz, eased with a 10° full-strength zone and silence beyond 35°, capped at 80% request intensity. Actual sends are spaced past the previous pulse's deadline to avoid motor overlap. The existing outdoor route continues its conservative alignment dwell and 900 ms pulse cadence. An acknowledgement is not proof of physical motor motion.

Physical glove taps also require a firmware gesture event wired to start listening. This change uses the app's existing hand/microphone tap; it does not infer tap gestures from the echo service.

## Implementation and checks

- `IndoorDemoCommand` recognizes complete app commands before destination interpretation, map/transit logic, or GPS checks. It does not send the request to an LLM for classification. It rejects negated requests and avoids stealing destinations such as “Demo Cafe” or “Beacon Street.” Speech transcription still uses the app's configured speech providers; typing requires no transcription.
- `PointViewModel.Stage.indoorDemo` owns presentation and isolates the mode from route state. Exiting returns to the home state rather than resuming an old journey.
- `CameraBeaconTestView` owns placement, ordered guidance, permission recovery, and temporary AR anchors. Spoken instructions reuse Point's existing speech/VoiceOver behavior.
- `--demo-mode` in a Debug launch submits the same “Can you go into demo mode?” text to the normal command path. The simulator displays a physical-iPhone requirement; it never fabricates room tracking.

Automated command cases cover common wording, punctuation, whitespace, negation, and map/transit destination false positives. Camera placement, indoor drift, physical glove output, and worn-glove calibration still require physical testing.

## Floor placement and presentation

The camera panel shows a short task heading, one current instruction, and the relevant actions. Help holds glove instructions, a finite glove motor test, reset, and privacy details. The panel grows with Dynamic Type and scrolls when needed instead of covering the whole camera.

The floor ring and placed anchor share the same transform. With Relaxed demo off, placement uses detected horizontal plane geometry, prioritizes ARKit floor classification, and rejects known tables, seats, and walls. Without floor classification, it chooses the lowest unclassified horizontal plane at least 70 cm below the phone. That fallback is a height estimate, so room testing is still needed; it cannot guarantee semantic floor identification. Relaxed demo instead intersects the camera ray with a fixed horizontal plane: an available floor estimate or the configured phone height below the first tracked camera position. It does not require a recognized surface and may be vertically offset from the real floor. Height is fixed until clearing the route, rescanning, or adjusting the height before placement; later phone movement does not drag the floor. LiDAR mesh classification is enabled on supported devices. Missing, stale, or uncertain camera tracking still hides the ring and disables placement in both modes.

Beacons rise over 380 ms from their floor origin. Reduce Motion replaces the rise with a short fade. The existing tall columns and camera-facing route numbers remain. `--demo-mode --preview-indoor-ui` renders an explicitly labeled Debug-only layout fixture for simulator typography checks; it does not simulate working AR.

## Live orientation logs

**⋯ → Orientation logs** shows sensor yaw/pitch/roll, finger elevation and sensor-relative bearing, saved finger axis, sample age, calibration levels and health flags, camera tracking reason/aim/frame age, placement/room state, room offset, target error and requested vibration. Motor acknowledgements report receipt, not measured physical vibration.

Pocket logs also include estimated room x/z, body bearing, step count, assumed step length, travelled distance, gravity-projected acceleration/rotation, motion age, validity and manual target advances. These are estimates, not ground truth.

Samples update at 2 Hz, with at most 600 entries retained. The latest log is saved locally as `Documents/demo-orientation.log` every two seconds and on closing. Copy and Share controls export the current bounded log. It contains no microphone audio, camera images or GPS positions. A log reset does not reset calibration; a new demo replaces the latest file.

## Placement and glove readiness

The first placement needs a fresh glove direction to capture the shared reference. Start remains tappable and gives a specific failure reason. Relaxed mode uses relative orientation with a settled gyro; strict mode additionally requires magnetic readiness. Both enforce the saved mounting vector, reading freshness, hardware health and forward elevation gate. Relative demo pulses use a separate transport entry point and cannot relax outdoor navigation checks.

## September 19 relaxed IMU check

A physical BLE check collected 120 BNO055 quaternion samples, all healthy (flags `0x01`), with firmware ages 5–25 ms and quaternion norm² 0.9999–1.0001. The maximum reported orientation change from the first sample was 17.42°. Calibration remained `0x3E`: system 0, gyro 3, accelerometer 3, magnetometer 2. This demonstrates fresh changing orientation before north acquisition, not ground-truth pointing accuracy. The check requested STOP and disconnected cleanly; no vibration was requested. The app's 134 core tests and signed build passed, including relative-only motor gating and silence when the hand drops.


## Pocket test validation

The initial pocket estimator tests cover stationary noise, constant acceleration bias, turning without translation, forward steps followed by a 90-degree turn, duplicate timestamps, interrupted readings and invalid inputs. The first build passed 139 core tests and an iPhone build. Real walking accuracy, step detection on this wearer, speech at pocket readiness, and glove vibration while walking still need an on-device run. The iPhone was unavailable during the initial implementation; no physical pocket-test result is claimed.


## Build 12 follow-up

Fixed shared magnetic/relative reference invalidation and retained the physical mounting map through temporary health dips. Added estimated sequential arrival and body-relative spoken turn cues, a full-screen touch guard, a WidgetKit Live Activity, and background Bluetooth lifecycle handling for the pocket session. Regression tests cover reference continuity, recovery after gyro-quality dips, estimated arrival dwell/new-step requirements, and turn direction. 143 core tests pass. The iPhone was unavailable while these changes were implemented, so neither the reported walk log nor locked-screen runtime has yet been verified on hardware.

## Integration build 13

Merged upstream `7ba0262` with the saved pocket implementation. The retrieved physical walk log confirms the reported failure coincided with BNO055 system calibration changing from 0 to 1 while gyro stayed at 3 and fresh motion samples continued. The relaxed demo now retains its separate relative reference across that transition. Pocket estimation, sequential turn cues, touch guard and Live Activity remain included alongside the upstream push-to-talk and transit changes. Session logs include the installed build number.

The merged core suite passes 163 tests. Sustained motion updates and glove guidance with the screen locked still require a physical walk; the Live Activity alone is not evidence of background execution or positioning accuracy.

## Build 15 single-beacon fallback

The reported gradual anticlockwise drift has not been isolated to motor interference versus sensor fusion or pocket odometry. No automatic yaw correction was added without a physical reference. The default now removes odometry entirely: one beacon, one fixed standing position, camera off, no step integration or automatic arrivals. The live glove heading, forward-elevation gate and freshness checks still control haptics. Motor mute logs permit a controlled stationary comparison. Four-beacon walking code remains available as an opt-in experiment. No firmware mode or saved mounting calibration was changed.
