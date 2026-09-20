# Hardware boundary — draft

The hardware team owns the board, sensors, wiring, firmware and motor. The active target is the XIAO ESP32-S3 with primary BNO055 (including magnetometer), redundant MPU6050 and DRV2605L. Firmware push `e83f936` is merged; [the hardware README](../Firmware/README.md) and [circuit test](../Firmware/CircuitTest/README.md) contain the current pinout. `Firmware/BTTest` is the older ESP32-C6 BLE echo prototype. Point can discover that service, connect, subscribe to replies, and verify a unique echoed message. See [device setup](DEVICE_SETUP.md) for the physical-iPhone test procedure.

The echo link is separate from the navigation interface below. Its firmware does not yet provide heading, gestures, battery, or motor control; successful connection verification does not imply those capabilities exist. The app now implements a capability-gated [proposed S3 protocol](FIRMWARE_APP_PROTOCOL.md), including the real route transport and motor-test control. The new `Firmware/S3Firmware` now implements the contract and has been uploaded. BLE round trips, sensor reads and finite motor command completion passed bench checks; physical sensation, pointing calibration and iPhone end-to-end testing remain pending.

## Glove → phone

| Event | Needed meaning |
| --- | --- |
| Connection | Connecting, ready, disconnected; ready means required capabilities are negotiated |
| Capabilities | Heading, gesture input, vibration support |
| Heading | Pointing bearing in degrees clockwise from true north, estimated accuracy, sample time |
| Gesture | Optional check-direction or pause/resume event; final gesture mapping TBD |
| Battery | Percentage when actually available |

The adapter must convert board axes, mounting orientation, handedness and sensor reference into the agreed pointing frame. Raw gyro yaw alone is not an absolute heading. Magnetic-north readings need a known conversion before use. Phone GPS supplies position; phone orientation does not describe the glove.

BLE packet timestamps need translation to a phone clock, or bounded latency/age information. Simply assigning an old buffered packet a fresh receipt timestamp is not sufficient. The proposed v1 uses correlated heading requests, full round-trip time plus reported sample age, and a 500 ms freshness limit. It reuses the echo characteristics with versioned binary messages. Firmware adoption of the proposal remains to be agreed.

## Phone → glove

- `confirm(durationMs, intensity)`: one finite pulse confirming pointing alignment.
- `stop`: stop confirmation immediately.
- `vehicleArrived`: in public-transportation mode, our bus/train is at the platform, or it is time to get off. A recognisably different, finite pattern from `confirm` (the S3 firmware plays three 120 ms pulses with 100 ms gaps); the firmware ends it locally after 560 ms. Transit alerts do not require the glove to point forward. It is never sent while pointing feedback is active.

There are no left/right vibration codes in this version. Outdoor and indoor guidance share eased 180 ms pulses, requested at most every 200 ms and capped at intensity 204/255. Outdoor guidance starts after 200 ms of stable alignment. Actual sends wait for the previous pulse duration plus 50 ms. These values are placeholders for physical trials, not motor-specific calibration. A single ERM motor is enough for this semantic interface; the firmware decides how to drive its actual motor/driver.

Firmware must stop a finite pulse locally even if Bluetooth disconnects or iOS suspends the app. Clear queued cues after reconnect and require fresh heading. Navigation remains visible without the glove; it must not claim haptic feedback is working.

## App development without hardware

`SimulatedGlove` implements `GloveTransport`. The command-line demo injects heading changes and prints motor commands. The UI has a labeled sample route and simulated pointing toggle. Real glove mode selects `FirmwareGlove`; a legacy echo-only board stays unavailable for guidance. Connect through Device setup, then turn off Phone vibration guidance before starting a real walk. Custom gesture learning and belt-specific behavior are deferred.

The BNO055 extension adds source, calibration and health to each attitude response. The app accepts calibrated primary compass readings, applies a fresh local magnetic-to-true-north correction when needed, and immediately invalidates guidance on sensor faults or fallback. The MPU6050 is not an absolute-heading substitute. See the proposed protocol for exact fields and remaining firmware work.
