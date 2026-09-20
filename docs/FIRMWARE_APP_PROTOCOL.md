# S3 app integration — v1 contract with quaternion extension

Status: **implemented in the iPhone and new [S3 ESP-IDF firmware](../Firmware/S3Firmware/README.md); physical integration verification is tracked in that README**.
The new S3 firmware implements this contract. The original Arduino circuit sketch does not understand these packets. Two-pose app mounting setup is implemented; physical calibration and navigation validation remain pending.

## Hardware baseline

Updated to Kuan's `firmware` push **`e83f936`**, now merged locally. The processor
remains XIAO ESP32-S3. **BNO055 is the primary fused orientation sensor**, with
an onboard magnetometer; MPU6050 is the redundant inertial sensor. Both share
GPIO2 SDA / GPIO1 SCL on controller 0 at **100 kHz**. DRV2605L stays on GPIO41
SDA / GPIO42 SCL, controller 1 at 400 kHz. Addresses: BNO055 `28/29`, MPU6050
`68/69`, DRV2605L `5A` (hex).

The [Arduino circuit test](../Firmware/CircuitTest/README.md) is the behavior
reference: BNO055 NDOF attitude at **50 Hz**, MPU6050 at **100 Hz**, logging at
10 Hz, USB haptic test. The teammate reports the combined circuit verified.
Production remains ESP-IDF/PlatformIO on S3. No BLE or automatic failover is
implemented in this sketch; the C6 echo firmware remains a separate prototype.

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

All multibyte integers are little-endian. Quaternion components are signed int16; other fields are unsigned. Every message begins:

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
- Bit 3: ATTITUDE with source/calibration/health supported (requires bit 0).
  **Required for the new BNO055/MPU6050 build.**
- Bit 4: raw ORIENTATION quaternion supported (requires bits 0 and 3).
- Bits 5–7: zero. No gesture or battery support is inferred.

The full S3 configuration advertises `0x1F`. Install the matching app before using this extension; older strict decoders reject that flag.

Advertise only functioning capabilities. App sends STOP after negotiation before
starting periodic heading requests. If sensor/driver health later fails, reject its
requests; do not keep acknowledging them as if healthy.

### Legacy HEADING — `02` → `82`

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

This original proposed packet stays supported for compatibility. It has no sensor
health fields. When bit 4 is set the app requests ORIENTATION; otherwise bit 3 selects ATTITUDE.
Old HEADING packets cannot satisfy these requests or bypass their health checks.

### BNO055 ATTITUDE — `04` → `84`

This is an additive, capability-negotiated extension to v1 implemented by S3Firmware; the Arduino sketch does not send it. Request: 7 bytes. Response: **17 bytes**, fitting the
existing 20-byte characteristic and default ATT MTU. Bytes 7–13 match HEADING.

| Offset | Bytes | Meaning |
|---|---|---|
| 14 | 1 | Source: 1 BNO055 primary, 2 MPU6050 backup |
| 15 | 1 | BNO055 CALIB_STAT: system bits 7–6, gyro 5–4, accel 3–2, mag 1–0 |
| 16 | 1 | Health flags described below |

Health bit 0: sensor read/fusion healthy; bit 1: mounting/axis transform to the
finger's pointing frame has been validated; bit 2: sensor disagreement detected;
bit 3: degraded/fallback source active. Bits 4–7 must be zero. Report the health
and calibration from the same sample as the heading; cached healthy flags must
not mask a new fault. Automatic disagreement/failover logic is still firmware work;
the app consumes these states, it does not invent sensor voting.

For legacy ATTITUDE directional output the app requires BNO055 primary, flags 0 and 1
set, flags 2 and 3 clear, system >0, gyro=3 and magnetometer ≥2. Accelerometer
calibration is optional; mounted-device trials remain necessary. Calibration levels do not measure heading error:
the accuracy field still needs a justified estimate, including mounting/fusion
uncertainty. Unknown/unbounded accuracy can be reported as 18000; it pauses direction.

MPU6050 remains relative-only. Any backup/degraded/disagreement/unhealthy state
immediately clears the last accepted heading and sends STOP through the existing
scheduler. A fresh passing BNO055 sample must satisfy normal alignment dwell again.
Motor testing remains available when only orientation is blocked.

### Raw ORIENTATION — `05` → `85`

Request: 7 bytes. Response: **20 bytes** (default ATT MTU):

| Offset | Bytes | Meaning |
|---|---|---|
| 7 | 8 | Signed int16 W, X, Y, Z, each divided by 16384 |
| 15 | 2 | Sample age, milliseconds |
| 17 | 1 | Source: 1 BNO055, 2 MPU6050 |
| 18 | 1 | CALIB_STAT |
| 19 | 1 | Same health flags as ATTITUDE |

Firmware reads Euler and quaternion in one contiguous transaction starting at `0x1A`; WXYZ begins at `0x20`. It checks squared norm in 0.90–1.10 and includes fusion/self-test/error health. Swift validates exact length, signed components, norm, source and reserved flags before normalizing. It counts full BLE round-trip time against the 500 ms freshness limit. The raw sensor quaternion rotates sensor vectors into the East-North-Up fusion frame; magnetic heading is `atan2(east, north)`.

App mounting setup is separate from firmware health bit 1. The firmware intentionally keeps that bit clear and legacy accuracy at 180°. New clients learn a finger vector from two **glove-only gravity poses**: point the straight finger down, then up. For each sample, inverse-rotate ENU down `(0,0,-1)` or up `(0,0,1)` into the sensor frame, average the resulting unit finger vectors, and compare the two captures. No phone heading, phone motion, or independent compass bearing enters this setup.

Capture needs ≥12 distinct samples spanning 1.2–3 seconds, ≤350 ms intersample gaps and ≤5° spread. The upward check must follow the downward capture within two minutes, with ≤10° finger-vector disagreement. The operating uncertainty budget is **5° provisional compass allowance + maximum pose spread + pose disagreement**, capped at 20° to accept setup. The 5° allowance is a prototype tuning assumption, not a calibrated accuracy claim. Opposing gravity poses validate mounting repeatability and finger polarity; they cannot establish absolute magnetic accuracy or detect every user pose error.

Gravity-pose setup requires healthy BNO055 orientation and gyro=3, independently of magnetometer/system calibration. Magnetic navigation additionally requires system >0 and magnetometer ≥2. Accelerometer calibration is optional (Bosch AN007 §3), so setup does not require six-face motion or overall system=3. The app persists validated mounting geometry in a versioned local record per Bluetooth device. Live transport mounting clears on disconnect, a health fault or loss of gyro readiness, then DeviceConnection restores the saved geometry after fresh mounting-ready readings return. Manual setup reset deletes the saved record before clearing live mounting. New firmware axis conventions require a new record version or explicit recalibration. Changes to accelerometer, compass or system calibration levels do not reset mounting. Loss of magnetic readiness still clears navigation heading and invalidates the room-alignment identity, because magnetic yaw may change when north is reacquired. Pose spread, disagreement and the provisional compass allowance form an operational estimate, not a measured accuracy guarantee. Repeated field measurements across wrist rotations and magnetic environments remain necessary.

Normal pointing requires finger elevation within ±30° of horizontal. Lowering the hand, pointing vertically, sensor failure, or stale data clears the arrow and automatic haptics. The transport rechecks pending cues before sending and sends STOP if a running automatic cue loses the gate. Finite firmware duration bounds output between sensor polls. The explicit setup motor test bypasses the pointing gate by design.

Indoor guidance uses the same calibrated magnetic finger vector with an explicit stable reference toward room beacon 1 (≥1 m away). It does not combine AR-local bearings directly with global compass bearings. AR reset or a changed glove calibration identity invalidates this room alignment.

### Magnetic north → true north

Raw BNO055 NDOF output is magnetic orientation. For legacy HEADING/ATTITUDE, firmware must apply the correct
sensor-to-finger transform before claiming pointing-frame validity; the sketch's
raw Euler X value alone does not establish the mounted pointing axis. Set reference
1 for magnetic heading, not 2. Reference 2 is allowed only if firmware already
applied a validated local magnetic-declination correction; the app won't apply it twice.

For calibrated, healthy BNO055 magnetic samples, the app derives local declination
from **one paired CLLocation heading sample**:

```text
declination = wrapSigned(phone.trueHeading - phone.magneticHeading)
glove.trueHeading = wrap360(glove.magneticHeading + declination)
```

The phone can face another direction: its orientation cancels in the difference.
The phone supplies the local north correction, not glove pointing. The app runs
phone heading updates in real-glove mode, requires a fresh usable GPS fix when
refreshing correction, rejects invalid paired headings, and expires correction
after five seconds. It conservatively adds phone heading uncertainty to the glove
estimate; combined uncertainty above 25° pauses output. Relative yaw is never corrected
this way. Missing correction, calibration loss and stale samples clear guidance.

References: [Bosch BNO055 datasheet](https://www.bosch-sensortec.com/media/boschsensortec/downloads/datasheets/bst-bno055-ds000.pdf)
(NDOF, axis remap, CALIB_STAT) and [Apple CLHeading](https://developer.apple.com/documentation/corelocation/clheading)
(paired magnetic/true headings).

### HAPTIC — `03` → `83`

Request: 11 bytes:

| Offset | Bytes | Meaning |
|---|---|---|
| 7 | 1 | Kind: 0 STOP, 1 finite confirmation, 2 vehicle arrived |
| 8 | 2 | Duration in ms (kind 1 only) |
| 10 | 1 | Intensity 0–204 (kind 1 only; 255 would mean full scale) |

STOP and vehicle-arrived require zero duration/intensity fields.
Confirmation accepts 1–350 ms; outdoor navigation sends 180 ms at intensity 160,
at most once per 900 ms after stable alignment. Intensity is a requested scale;
firmware owns motor-specific calibration. Do not translate it to unverified electrical
drive settings. Vehicle-arrived: four 120 ms pulses separated by 100 ms silence,
maximum intensity 160, total 780 ms, finishing locally. No left/right encoding.
Indoor guidance requests eased 180 ms pulses (full angular target within 10°, zero outside 35°, capped at 204), no faster than 5 Hz. The app also spaces actual sends by pulse duration plus 50 ms so deferred requests cannot overlap the firmware motor timeline.

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

Implemented in S3Firmware: ESP-IDF sensor readers, BLE contract, local motor deadlines, error handling and ATTITUDE source/calibration/health fields. Remaining firmware/bench work: Validate BNO055 pointing-axis mapping, magnetic interference with
the motor on/off, and true-north correction. Confirm motor type/rating before
configuring the driver. Implement and test explicit redundant-sensor fault states;
do not silently promote MPU6050 yaw to an absolute heading.

Joint verification after firmware is ready: connect with a physical iPhone; check
reported capabilities; run the motor test repeatedly; verify BNO055 calibration
gating and magnetic-north correction, and that backup/fault states pause guidance;
then test calibrated heading, loss of alignment, stale IMU,
disconnect mid-pulse, foreground/background, and real outdoor beacon progression.
Software tests cannot verify physical vibration or sensor mounting.
