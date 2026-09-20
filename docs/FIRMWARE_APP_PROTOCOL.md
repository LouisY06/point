# S3 app integration — proposed v1 contract

Status: **implemented on the iPhone side; not yet implemented or verified on the board**.
This is a proposed extension for the firmware teammate to adopt or revise, not a claim
that the current circuit sketch understands these packets. No board has been flashed
as part of this work.

## Hardware baseline

Based on Kuan's `firmware` branch at `66afcbf` (documentation) and `0bfb741`
(circuit test): XIAO ESP32-S3, MPU6050 on GPIO2 SDA / GPIO1 SCL, DRV2605L on
GPIO41 SDA / GPIO42 SCL, separate 400 kHz I2C buses. The Arduino circuit test is
the behavior reference; production firmware is ESP-IDF/PlatformIO on S3. Preserve
the 100 Hz IMU service loop. The current sketch has USB serial haptic testing and
relative yaw, but no BLE. The old C6 BLE echo implementation is a separate prototype.

Firmware runs on the board; the iPhone contains the BLE adapter and route logic.
No firmware image is embedded in the iPhone and OTA flashing is not implemented.

## BLE discovery and compatibility

Retain the documented service and characteristics, and the existing ASCII echo probe:

| Role | UUID / properties |
|---|---|
| Service | `7f510001-1b15-4f0d-9e82-8a7c4d6e5f01` |
| Command | `7f510002-1b15-4f0d-9e82-8a7c4d6e5f01`, Write with response, max 16 bytes |
| Status | `7f510003-1b15-4f0d-9e82-8a7c4d6e5f01`, Read + Notify, max 20 bytes |

1. App subscribes to Status, writes a unique ASCII `P:<token>`, and requires both
   the GATT write acknowledgement and exactly `ACK:P:<token>`.
2. App then sends binary HELLO. Only the correctly versioned/token-matched
   capabilities response enables the glove transport.
3. Legacy echo firmware echoes this packet; its echo **does not** enable controls.
   After two seconds the UI reads “Bluetooth works · Glove firmware support pending.”
4. Reconnection starts over and discards pending commands, old headings and capabilities.

Keep ASCII probe handling. Interpret binary commands only when magic, version, exact
length and fields are valid. Never treat raw ASCII `h` as an app motor command.

## Packet layout

All multibyte integers are unsigned little-endian. Every message begins:

| Offset | Bytes | Meaning |
|---|---|---|
| 0 | 1 | Magic `A7` |
| 1 | 1 | Version `01` |
| 2 | 1 | Request opcode; response is opcode OR `80` |
| 3 | 4 | App request token, echoed unchanged |
| 7 | varies | Payload below |

The app uses a random initial token and advances it for each request, including
across reconnects in the process. One exchange is outstanding at a time. Ignore
unmatched tokens, unknown versions/opcodes and malformed lengths. This is correlation,
not authentication; pairing/security remains a separate unfinished requirement.

### HELLO — `01` → `81`

Request: 7 bytes, no payload. Response: 8 bytes, one flags byte:

- Bit 0: heading requests supported. This alone does **not** imply true north.
- Bit 1: finite motor pulse and STOP supported, driver initialized successfully.
- Bit 2: bounded vehicle-arrival pattern supported (requires motor support).
- Bits 3–7: zero. No gesture or battery support is inferred.

Advertise only functioning capabilities. App sends STOP after negotiation before
starting periodic heading requests. If sensor/driver health later fails, reject its
requests; do not keep acknowledging them as if healthy.

### HEADING — `02` → `82`

Request: 7 bytes. Response: 14 bytes:

| Offset | Bytes | Meaning |
|---|---|---|
| 7 | 2 | Pointing angle, centidegrees, 0–35999 |
| 9 | 2 | Estimated angular uncertainty, centidegrees, 0–18000 |
| 11 | 1 | Reference: 0 relative yaw, 1 magnetic north, 2 true north |
| 12 | 2 | Sample age in milliseconds, including firmware queuing time |

Serve the newest IMU result, without blocking the 100 Hz loop. Do not report age
zero for cached samples. App requests at most 10 Hz, never requests a history, and
subtracts **full request round-trip time plus reported age** from receipt time.
Samples whose resulting age exceeds 500 ms are discarded. Tokens stop buffered
replies from satisfying later requests. Accurate navigation also requires the
existing GPS, uncertainty, off-route and heading freshness checks.

MPU6050 relative yaw must use reference 0. It has no magnetometer; never relabel it
as true north. A north-reference calibration/fusion design, axis/mount mapping and
drift uncertainty are still required. Phone compass orientation is not automatically
glove orientation. Until then, the app can test the motor but cannot navigate from
raw glove yaw. v1 does not send an invented calibration offset to the board.

### HAPTIC — `03` → `83`

Request: 11 bytes:

| Offset | Bytes | Meaning |
|---|---|---|
| 7 | 1 | Kind: 0 STOP, 1 finite confirmation, 2 vehicle arrived |
| 8 | 2 | Duration in ms (kind 1 only) |
| 10 | 1 | Intensity 0–204 (kind 1 only; 255 would mean full scale) |

STOP and vehicle-arrived require zero duration/intensity fields.
Confirmation accepts 1–350 ms; current navigation sends 180 ms at intensity 160,
at most once per 900 ms after stable alignment. Intensity is a requested scale;
firmware owns motor-specific calibration. Do not translate it to unverified electrical
drive settings. Vehicle-arrived: four 120 ms pulses separated by 100 ms silence,
maximum intensity 160, total 780 ms, finishing locally. No left/right encoding.

Response: 8 bytes, payload 0 accepted or 1 rejected. GATT write success alone is
not application acceptance. Send accepted only after the owning task accepts the
validated command. It confirms neither actuator motion nor the user's perception.
Repeated same-token commands must not replay a cue. STOP cancels any current/queued
cue. Disconnect, watchdog expiry and driver faults stop the motor locally.

Example confirmation with token `12345678`:

```text
App:   A7 01 03 78 56 34 12 01 B4 00 A0
Board: A7 01 83 78 56 34 12 00
```

## Timing, queues and failures

- BLE callbacks validate and enqueue bounded work; they do not operate I2C hardware.
- App keeps one exchange and one latest pending motor command. STOP takes priority;
  pending non-STOP cues older than 300 ms are discarded. No vibration data is stored
  for the whole route, whether it contains 3 or 300 beacons.
- A response must arrive within 500 ms (HELLO: 2 s). Timeout/rejection/write failure
  clears readiness and heading, drops pending output, and attempts one best-effort
  STOP. The user reconnects; old cues never automatically replay.
- Firmware queue capacity must be bounded too. Reject work that cannot be handled
  promptly and discard expired queued cues. End every pulse/pattern using a local
  deadline independent of phone traffic, and STOP on disconnect.
- App foreground watchdog reevaluates guidance at 10 Hz, including when sensor
  events stop. Inactive app mutes navigation; background closes the prototype BLE
  link. Locked-screen glove guidance/background BLE is not yet implemented.

## What is ready and what remains

Ready on app side: legacy fallback, capability negotiation, strict packet codec,
finite motor commands with application acknowledgements, age-aware heading reads,
bounded queue, real transport selection for glove mode, foreground stale-data
watchdog and a capability-gated “Test glove vibration” button in Device setup.
Phone stand-in guidance and the sample-route simulator remain available.

Firmware teammate: finish circuit fixes, port the verified drivers into ESP-IDF/S3,
add BLE/this contract (or agree revisions), implement local motor deadlines and
health/error handling, and choose/validate the north-reference method. Confirm
motor type/rating before configuring the driver.

Joint verification after firmware is ready: connect with a physical iPhone; check
reported capabilities; run the motor test repeatedly; verify relative yaw stays
calibration-required; then test calibrated heading, loss of alignment, stale IMU,
disconnect mid-pulse, foreground/background, and real outdoor beacon progression.
Software tests cannot verify physical vibration or sensor mounting.
