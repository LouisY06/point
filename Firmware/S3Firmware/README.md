# Point S3 — first integrated ESP-IDF firmware

Target: ESP32-S3, primary BNO055, diagnostic backup MPU6050, DRV2605L ERM motor.
This ports the verified circuit behavior into ESP-IDF and adds the app's proposed
v1 BLE contract, including the BNO055 ATTITUDE and raw ORIENTATION extensions. It is bench firmware,
not validated navigation hardware.

## Build

PlatformIO Core is required. Platform `espressif32@6.12.0` pins ESP-IDF 5.5.0.
The project uses the `seeed_xiao_esp32s3` definition, 8 MB quad flash, no PSRAM
dependency. All circuit pins are explicit and match the teammate's README.

```sh
./test.sh
./build.sh
./build.sh --target upload --upload-port /dev/cu.YOUR_BOARD
```

`build.sh` stages the source under `/tmp/point-s3-firmware`, because ESP-IDF
rejects spaces in project paths. Override `POINT_FIRMWARE_BUILD_DIR` to use another
space-free directory, and `POINT_PLATFORMIO` if `pio` is not on PATH. Build output
is `.pio/build/seeed_xiao_esp32s3` inside that staging directory. Run scripts from
this directory or use their full paths. Machine-specific ports are not committed.

Use 230400 baud for this bench adapter if faster uploads fail. The normal console
is UART0 at 115200, with secondary USB Serial/JTAG output enabled. The current
CP2102N bridge is UART0, not native USB. The S3 chip and 8 MB flash must be
identified before upload; this project must not be uploaded to the old C6.

## Runtime

- Controller 0: GPIO2 SDA / GPIO1 SCL, 100 kHz. BNO055 at 0x28/29 and MPU6050
  at 0x68/69. Driver reads have bounded timeouts.
- Controller 1: GPIO41 SDA / GPIO42 SCL, 400 kHz. DRV2605L at 0x5A.
- BNO055 reset, normal power, degree units, internal clock, NDOF mode. Read
  fused orientation and calibration/self-test/system status at 50 Hz.
- MPU6050 ±4 g, ±500°/s, 21 Hz filter, 100 Hz sampling. Startup averages 400
  gyro readings; keep still for about 2–3 seconds. Roll/pitch complementary
  filtering and relative yaw are diagnostics, not an absolute-heading fallback.
- A separate sensor task owns I2C controller 0. A low-priority diagnostic task
  logs every five seconds so console output does not block sampling.
- The application task owns the haptic bus and services motor deadlines every
  five milliseconds. It processes at most two queued BLE requests each iteration.
  A bounded queue of eight packets prevents unbounded memory/work accumulation.
- Sensor/application tasks are registered with the ESP-IDF task watchdog.
- BLE advertises **Point S3** with the same service/command/status UUIDs as the
  old echo prototype. ASCII echo, HELLO, HEADING, ATTITUDE, ORIENTATION, STOP, confirmation and
  vehicle-arrival messages match [the app contract](../../docs/FIRMWARE_APP_PROTOCOL.md).
- HELLO reflects discovered sensors and initialized motor. ATTITUDE carries
  BNO055 magnetic heading, calibration, read health, mount-valid flag and age.
  BNO errors invalidate primary data; no automatic redundant-sensor voting or
  runtime failover is claimed. MPU-only startup reports backup/degraded state.
- Reconnect/unsubscribe/reset invalidates queued requests by connection generation.
  STOP has priority over earlier queued motor requests. Non-STOP cues older than
  300 ms are rejected. Repeated motor tokens don't replay a pulse; old tokens
  are rejected within a connection.
- Motor output uses unsigned RTP and the verified sketch's ERM/open-loop assumption.
  Rated-voltage and overdrive-clamp registers are not retuned. A confirmation is
  limited to 350 ms and intensity 204/255. Vehicle arrival is four 120 ms pulses
  at 160/255, separated by 100 ms silence (780 ms total).
- Overlapping non-STOP cues are rejected instead of extending a running pulse.
  Pulse completion, STOP and disconnect write RTP zero then standby. Driver read/
  write failures or overcurrent/overtemperature disable subsequent motor output
  until reboot. There is no unsolicited startup vibration.

Serial commands: `h` requests one 180 ms, 160/255 motor pulse; `s` stops it.
The serial test is local and independent of BLE, calibration and GPS.

## App mounting calibration

Legacy Euler output deliberately retains `POINT_MOUNT_VALID=0`, zero heading offset and `POINT_HEADING_ACCURACY_CDEG=18000`. Do not flip these to bypass setup. New clients negotiate HELLO bit 4 and request opcode 5: raw signed WXYZ quaternion, scale 16384, sample age, source, calibration and health in 20 bytes. Euler and quaternion are read contiguously; norm and sensor status gate health. `UNIT_SEL=0` retains the existing Windows Euler-format setting; quaternion consumers use the ENU rotation convention rather than converting Euler angles.

The matching app learns the physical finger vector through two stable glove-only gravity poses (finger down, then up), validates that both imply the same sensor-to-finger axis, and resets that mapping on reconnect, sensor faults or loss of gyro readiness. Compass settling pauses navigation while preserving mounting. Glove mounting setup requires healthy orientation and gyro=3; navigation additionally needs system >0 and magnetometer ≥2; accelerometer calibration is optional, so six-face calibration is not required. The app's uncertainty budget combines measured mounting repeatability with a provisional 5° compass allowance; it is not a measured or certified sensor accuracy. Directional output additionally requires the finger within ±30° of level, fresh sensor data and (outdoors) a fresh true-north correction. Explicit motor tests remain available before calibration.

See [setup steps](../../docs/DEVICE_SETUP.md) and the [wire contract](../../docs/FIRMWARE_APP_PROTOCOL.md). Physical mounting, roll/pitch convention, actual vibration, and navigation behavior still require a worn-glove trial. No successful physical calibration is claimed by a build or packet test.

## Bench validation

1. Save the previous flash image before first replacement.
2. Build, upload, read startup logs, and confirm IDs 0xA0 (BNO055), 0x68 (MPU6050)
   and DRV2605L status ID. Check error counts and sample ages while tilting.
3. Run `h` several times and observe the motor. Confirm each pulse ends, and `s`
   interrupts it. Logs confirm driver commands; only observation confirms motion.
4. In Point's updated iPhone build, Device setup → Point S3 → Test glove vibration.
   Complete the two-pose pointing setup before testing automatic guidance.
5. Optional computer check: `python test/ble_smoke.py` with `bleak` installed.
   Add `--motor` to request three finite pulses. Disconnect other BLE clients first.
6. Check disconnect during a pulse, malformed packets, duplicated token, sensor
   calibration loss, and a stale/missing primary sensor. Never claim GPS pointing
   verification based on a successful bench motor test alone.

Host tests exercise packet bounds, the exact Swift-compatible attitude vector,
malformed opcodes/lengths, motor deadline, four-pulse timing, overlap rejection,
STOP and invalid time. Both tests run with address/undefined-behavior sanitizers.

## Remaining limitations

No bonding/authentication, OTA, GPS-on-board, battery telemetry, persistent sensor
calibration, automatic I2C reinitialization, validated sensor-disagreement detection,
automatic IMU failover or low-power mode. The iPhone prototype currently closes
BLE in the background. Motor cutoff depends on a working MCU and I2C path; a
severed driver bus cannot guarantee the stop write reaches the actuator. An
independent hardware enable/watchdog is still needed for a fault-tolerant cutoff.

Register references: [Bosch BNO055 datasheet](https://www.bosch-sensortec.com/media/boschsensortec/downloads/datasheets/bst-bno055-ds000.pdf),
[TI DRV2605L datasheet](https://www.ti.com/lit/ds/symlink/drv2605l.pdf), and the existing
[circuit reference](../CircuitTest/CircuitTest.ino). No Arduino/Adafruit library
is linked into this ESP-IDF application.

## Recorded bench result — 19 September 2026

Built and uploaded to the connected ESP32-S3 (8 MB flash) with write hashes
verified. Saved the original full 8,388,608-byte flash image under the repository's
ignored `output/firmware-backups/s3-before-point-20260919.bin`; its adjacent JSON
records backup/build hashes. This backup is local and is not in Git.

Observed on the board: BNO055 0x28 (ID A0), MPU6050 0x68 (ID 68), DRV2605L
ID E0 ready. Mac BLE client completed echo, HELLO capabilities 0F, fresh ATTITUDE
requests on two connections, and three 180 ms / 160-strength motor requests.
Firmware logged each ending about 185 ms after acceptance. Sensor errors remained
0/0; calibration was 0/3/1/0, mount flag was false, uncertainty was 180 degrees.
Thus **connection, sensor reads and motor command completion are verified**;
physical sensation and navigation alignment are not yet verified. No iPhone end-to-end
claim: the developer connection to the iPhone was unavailable at this check.

Rollback, only when deliberately requested, uses the saved full image on this same
board (never another board's backup):

```sh
python -m esptool --chip esp32s3 --port /dev/cu.YOUR_BOARD --baud 230400 write-flash 0 /absolute/path/to/s3-before-point-20260919.bin
```

## Quaternion extension bench result — 19 September 2026

The matching opcode-5 build was uploaded to the same ESP32-S3 with verified write hashes. Mac BLE passed echo and HELLO `0x1F`; ten paired ATTITUDE/ORIENTATION reads returned healthy BNO055 data with quaternion squared norm about 1.0000 and sample ages 6–26 ms. Calibration remained `0/3/0/0`, so automatic guidance correctly remains blocked pending user calibration. Three 180 ms motor requests were acknowledged; the client sent STOP and disconnected cleanly. This run did not observe actuator motion or a mounted hand. Host protocol/motor tests pass under ASAN/UBSAN. The old `0x0F` bench entry above describes the previous firmware.
