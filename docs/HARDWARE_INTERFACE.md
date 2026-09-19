# Hardware boundary — draft

The hardware team owns the board, sensors, wiring, firmware and motor. The app only needs a small semantic interface, regardless of whether the final controller is a XIAO ESP32-S3 or another BLE board.

## Glove → phone

| Event | Needed meaning |
| --- | --- |
| Connection | Connecting, ready, disconnected; ready means required capabilities are negotiated |
| Capabilities | Heading, gesture input, vibration support |
| Heading | Pointing bearing in degrees clockwise from true north, estimated accuracy, sample time |
| Gesture | Optional check-direction or pause/resume event; final gesture mapping TBD |
| Battery | Percentage when actually available |

The adapter must convert board axes, mounting orientation, handedness and sensor reference into the agreed pointing frame. Raw gyro yaw alone is not an absolute heading. Magnetic-north readings need a known conversion before use. Phone GPS supplies position; phone orientation does not describe the glove.

BLE packet timestamps need translation to a phone clock, or bounded latency/age information. Simply assigning an old buffered packet a fresh receipt timestamp is not sufficient. Service UUIDs, characteristics, frequency, encoding, acknowledgements and sequence IDs remain to be agreed; no fabricated hardware UUIDs are committed.

## Phone → glove

- `confirm(durationMs, intensity)`: one finite pulse confirming pointing alignment.
- `stop`: stop confirmation immediately.

There are no left/right/arrival vibration codes in this version. Current demo tuning is 180 ms per pulse, at most once per 900 ms, after roughly 350 ms stable alignment. These values are placeholders for physical trials, not motor-specific calibration. A single ERM motor is enough for this semantic interface; the firmware decides how to drive its actual motor/driver.

Firmware must stop a finite pulse locally even if Bluetooth disconnects or iOS suspends the app. Clear queued cues after reconnect and require fresh heading. Navigation remains visible without the glove; it must not claim haptic feedback is working.

## App development without hardware

`SimulatedGlove` implements `GloveTransport`. The command-line demo injects heading changes and prints motor commands. The UI has a labeled sample route and simulated pointing toggle. Swap the transport after the actual BLE contract exists. Custom gesture learning and belt-specific behavior are deferred.
