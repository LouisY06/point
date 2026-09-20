# Connect a Point device

Point now supports the echo service in `Firmware/BTTest`, introduced in firmware commit `940a071`. This verifies the Bluetooth data path. It does not enable glove heading, gestures, battery telemetry, or vibration.

The active hardware is now ESP32-S3. Its current Arduino circuit sketch is USB-only.
Do not flash the C6 prototype to the S3. The app is ready for the [proposed S3 BLE
contract](FIRMWARE_APP_PROTOCOL.md), but the board still needs that implementation.
After echo verification the app checks capabilities: a compatible board enables
**Test glove vibration**, while an echo-only board shows firmware support pending.
For real glove navigation, connect here and turn off **Phone vibration guidance**
before starting a walk. Relative gyro yaw will display a north-reference requirement.

## Legacy C6 echo test

1. Build and flash `Firmware/BTTest` to the XIAO ESP32-C6 using the [firmware instructions](../Firmware/BTTest/README.md). Keep the board powered on.
2. Disconnect nRF Connect, LightBlue, or any other phone/client from the board. This firmware accepts one connection at a time.
3. Open `Point.xcodeproj`, choose your physical iPhone and local development signing team, and run the Point scheme. No voice/maps credentials are needed for Bluetooth setup.
4. Tap the device icon at the upper right of the home screen. The same control is available beside the route's Preview/Walking label.
5. Tap **Scan for device**, then allow Bluetooth access. Select **BT Test C6** from the nearby list. If multiple boards have the same name, the short device identifier and signal label help distinguish them.
6. Wait for **Connection verified**. Point subscribes to status notifications, writes a unique `P:<token>` command, and requires both write success and the matching `ACK:P:<token>` reply.
7. Use **Test connection again** to send a fresh command, or **Disconnect** to release the board.

The setup sheet displays the most recent reply and verification time. Closing the sheet preserves a verified connection. Closing it during a scan or setup cancels that work. Moving the app into the background closes this foreground-only prototype link; scan again on return.

## Protocol used by the app

| Item | Value |
| --- | --- |
| Advertised name | `BT Test C6` |
| Scan filter / service | `7f510001-1b15-4f0d-9e82-8a7c4d6e5f01` |
| Command characteristic | `7f510002-1b15-4f0d-9e82-8a7c4d6e5f01` |
| Status characteristic | `7f510003-1b15-4f0d-9e82-8a7c4d6e5f01` |
| Command encoding / limit | UTF-8 probe; at most 16 bytes |
| Probe size | 14 bytes; echoed status is 18 bytes |
| Write mode | With response |
| Confirmation | Matching notification plus successful GATT write |
| Scan window | 12 seconds |
| Connection/discovery deadline | 20 seconds |
| Echo deadline | 5 seconds |

Readiness is not inferred from a device name, a successful radio connection, or the firmware's generic `ready`/`connected` status. Replies from an earlier probe cannot verify a later one. A connection-test failure closes the link so retry starts cleanly.

## Troubleshooting

- **No device found:** check power, confirm the BT Test firmware is flashed, move closer, and close other clients. Scan again; the firmware advertises again after disconnect.
- **Bluetooth off:** enable Bluetooth in iPhone Settings, then scan again.
- **Permission denied:** use **Open Settings** from the setup sheet and allow Point Bluetooth access.
- **Connects but fails verification:** check firmware UUIDs/properties and serial logs. The status characteristic must support notifications and the command must accept acknowledged writes.
- **Simulator:** setup can be opened and inspected, but use a physical iPhone for the BLE check. The simulator shows an explicit message instead of pretending to discover a board. Launch argument `--device-setup` opens the sheet for UI review.
- **Disconnect or board reset:** the verified state clears. Scan and choose the device again; there is no silent automatic reconnection.

## Implementation and next integration

`App/DeviceConnection.swift` owns CoreBluetooth discovery, connection, subscription, timeouts, and cleanup. `App/DeviceSetupView.swift` presents setup and recovery. `Sources/PointCore/Device/BTTestProtocol.swift` defines the firmware contract and validates the probe; its tests cover byte limits, reply matching, callback ordering, and stale replies.

This setup connection is deliberately separate from `GloveTransport`. The echo firmware has no real navigation capabilities, so an ACK must not make the app report working haptics or calibrated heading. The sample walk continues to use `SimulatedGlove` even if a board is connected.

Next, agree on a versioned sensor/haptic protocol with the firmware team and implement that transport. Do not encode haptic commands into the echo endpoint and assume the board will execute them. Bonding and authentication are not part of this bring-up firmware.

The implementation follows Apple's [central-role workflow](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/PerformingCommonCentralRoleTasks/PerformingCommonCentralRoleTasks.html). The app declares the Bluetooth usage description required by [Core Bluetooth](https://developer.apple.com/documentation/corebluetooth).

## Verification so far

- The core suite includes five passing echo-protocol tests; see the project plan for the current full-suite and Apple Maps validation results.
- Simulator and unsigned physical-iPhone builds succeed.
- Setup opening, simulator recovery message, and dismissal were checked in the simulator.
- A live iPhone-to-board connection has not yet been exercised. Run the bench steps above, then check board power loss, Bluetooth off, permission denial, missing reply, reconnect, and background/foreground behavior with actual hardware.
