# Test beacons with the phone

The iPhone can temporarily supply orientation and vibration while the glove hardware is being built. No Bluetooth connection or provider keys are needed. The **Test beacons** button is in the fixed top bar of the home screen, beside device setup.

## Nearby camera test

1. On the home screen, tap **Test beacons** and allow Camera access.
2. In a well-lit room, slowly scan a textured floor, table or wall until tracking is ready. Aim the crosshair at a surface about **0.5–8 metres away horizontally**, then tap **Place beacon**. Add up to eight; they are visited in placement order.
3. Use **Test vibration** first for a short motor check independent of direction and tracking. Then tap **Test pointing**. Hold the phone nearly flat, **screen down**, with your hand on its back. The **top/camera end points along your index finger**; the charging port is toward your wrist, matching the supplied grip photo. Leave the rear camera unobstructed.
4. Turn slowly. Vibration grows as the top edge points toward the active beacon and fades as you turn away. Turning the phone around does not count as aligned. Screen-up, upright or excessively tilted grips silence it.
5. Approach the point to advance: within **35 cm horizontally for 0.5 seconds**. Height is ignored, so a floor marker can be reached with the phone held above it. Pause, clear or finish with the visible controls.

This mode uses ARKit local coordinates, not GPS map pins. It needs an ARKit-capable physical iPhone with haptic support; the simulator only shows the unavailable-state UI. No video is recorded or uploaded. Camera tracking is used only inside this optional test screen; Apple Maps walking navigation does not need it.

Tracking can drift or become uncertain, particularly when the screen-down grip makes the rear camera see a blank ceiling. Use a room with visible detail. Uncertain or stale tracking silences vibration. Leaving the app or interrupting the AR session clears temporary beacons: re-scan and place new points. Nothing is persisted or attached to a walking route.

## Apple Maps route test

Type or speak a real destination, leave **Phone vibration guidance** enabled, then tap **Start walking**. Use the same grip. This mode uses GPS and a true-north compass for outdoor route-scale testing. The map highlights the active beacon. A fresh starting fix confirming the user is at the route origin skips its start marker. The panel shows “Heading to beacon N of M.”

Arrival is confirmed by two distinct GPS fixes within 8 metres, both with accuracy at most 8 metres. Each reached beacon produces **two short pulses**, then eased pointing guidance follows the next beacon automatically. The destination produces **three pulses**, and directional guidance ends. These arrival cues are independent of the grip: they report confirmed position, not pointing alignment. Pause, cancel or backgrounding stops the cue. Duplicate/stale fixes cannot replay an arrival. No manual Test vibration tap is needed during a walk.

Apple Maps phone-test strength follows the estimated angle displayed on screen with a forgiving range: full strength within ±10°, then a smooth fade to silence at ±35°. Small hand movements inside the central range do not weaken feedback. GPS/compass accuracy is displayed separately. The strict glove alignment confirmation still includes uncertainty margins. Poor GPS, stale compass data, missing true north, a target within the GPS uncertainty circle and off-route state suppress feedback. The cyan arrow at your GPS position shows the physical top-edge heading and rotates correctly when the map rotates. An unreliable or stale compass hides the arrow. **Test vibration** sends a short pulse independent of GPS, compass and grip, helping distinguish a motor problem from suppressed guidance.

During a started walk, GPS route progress continues with the screen locked using iOS background location. Custom phone vibration stops in the background and restarts when Point is foregrounded. Manual Pause stops route progress and background tracking. End walk and arrival disable background tracking. Camera tests still require the foreground and clear their temporary points on inactivity. A powered-off phone cannot navigate. Locked-screen phone haptics and live background behavior have not been verified on-device; iOS suspends Core Haptics when the app is suspended. See [Apple haptic lifecycle guidance](https://developer.apple.com/documentation/corehaptics/preparing-your-app-to-play-haptics).

## Current tuning

- Forward axis: physical phone +Y (top/camera edge), independent of interface rotation.
- Grip: enter within 30° of flat screen-down; remain accepted until 35°. Motion/tracking samples must be no older than 0.3 seconds.
- Apple Maps target strength: `0.8 * smoothstep(clamp(1 - (abs(errorDegrees) - 10) / 25, 0, 1))`: full strength across ±10°, fading smoothly out to ±35°. The nearby camera test keeps its existing 0–45° curve. Both use the estimated angle after validity checks; strict glove alignment confirmation remains separate.
- At 20 Hz, lerp strength toward target with `t = 1 - exp(-dt / 0.18)`. Turning away fades; invalid grip/data stops immediately.
- Core Haptics reuses one pattern player across finite 350 ms continuous events, with short attack/release ramps and changing intensity. Direction guidance and arrival/test cues share the engine instead of recreating it for each cue. Each burst explicitly starts the engine/player and reapplies intensity; timing uses monotonic uptime. A stop/reset recreates the invalidated player, and playback failures rebuild the engine with a one-second retry limit. Initial preparation failures no longer prevent the guidance loop from starting and retrying. Output is capped at 80%; events expire if the foreground loop stalls. This is separate from the glove confirmation-pulse protocol.
- Automatic Apple Maps rerouting is still pending. Local beacons do not test GPS, true-north calibration, obstacle detection or glove Bluetooth.

## Verification and remaining checks

A regression test reproduces the reported 15 m / 3° case with GPS and compass uncertainty: estimated pointing now produces strength while strict alignment remains unconfirmed, and stale input stops it. Automated tests also cover forward/reverse/local direction, floor height, invalid geometry, grip/tilt/staleness, strength mapping, time-independent lerp, invalid-data shutdown route-origin skipping, and a complete multi-beacon route through the Apple Maps adapter, GPS advancement, heading feedback, pause/resume and final arrival. The unsigned iPhone build passes. Physical haptic strength, grip axes, local tracking accuracy, locked-screen GPS continuation and outdoor compass behavior still need a phone test. Haptic engine interruptions now retry while active; ending microphone capture no longer leaves a recording-only audio category blocking the test.

Start with one beacon 1–2 metres away: top edge forward vibrates, charging edge forward does not, screen-up stops, turning away eases down, and approaching advances. Then test multiple beacons, poor light, a covered camera, pause/resume, app switching, locking and an audio interruption. Record actual observations before tuning thresholds.

## Long routes and performance

Only the active beacon is used by the 20 Hz direction/haptic loop. The app keeps one current intensity and one finite haptic player; there are no precomputed vibration arrays for future beacons. Full route coordinates and beacon metadata remain available for navigation.

The map caches one `MKPolyline` per route identity. Heading display updates are isolated from the parent screen and limited to 10 Hz; freshness checks redraw only the pointer. During a walk, markers are bounded to the current neighborhood (two behind, eight ahead, plus endpoints; at most 13). Overview shows at most 64 sampled markers. All beacons remain in the navigation session and the complete route line remains visible. Status fields only publish changed display values; vibration calculation keeps full precision.

Route segmentation runs off the UI thread. Instructions are normalized once per provider step, rather than once per checkpoint. Off-route checks stop at the first segment within the existing corridor and no longer allocate an array of distances.

A local Debug regression traversed 361 beacons and 2,758 checkpoints in order, including direction output and arrival validation. On the development Mac, the same benchmark changed from 0.765 s to 0.346 s for the complete GPS-update sequence, and route construction from 0.0150 s to 0.0034 s. These are desktop core timings, not iPhone frame-rate measurements or network latency. Marker-window tests cover routes up to 10,000 beacons. Physical-device frame pacing still needs verification.

Playback recovery regression tests cover 100 repeated pointing/cue cycles, restarting completed finite bursts, engine interruption, initial startup failure, player failure, invalid input/background silencing, and ignoring late callbacks from an old session. These use an injected output adapter; they do not verify the physical motor. The reported case where alignment remains visible but vibration stops still needs a repeated outdoor walk on the updated phone build.
