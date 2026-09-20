# Point Firmware Handoff

## Current status

The active hardware target is a **Seeed Studio XIAO ESP32-S3**. The complete
Arduino bring-up sketch in
[`CircuitTest/CircuitTest.ino`](CircuitTest/CircuitTest.ino) is functioning and
has verified the BNO055, redundant MPU6050, and DRV2605L together.

The required environment for the full firmware is **ESP-IDF targeting the
ESP32-S3**, managed through PlatformIO. The Arduino sketch is only a functional
verification prototype: it exists to make circuit bring-up, sensor inspection,
and haptic debugging quick. It is a behavioral reference for the ESP-IDF
implementation, not the production application foundation.

The repository also contains [`BTTest`](BTTest/README.md), an earlier
ESP32-C6/ESP-IDF BLE prototype. Its GATT protocol is useful reference code, but
its service has now been adapted into the separate `S3Firmware` ESP-IDF project.
Do not treat `BTTest/platformio.ini` as the configuration for the current
hardware.

## Integrated ESP-IDF prototype

[`S3Firmware`](S3Firmware/README.md) now implements the S3 sensor readers, bounded motor commands and app BLE contract, including ATTITUDE health/calibration messages. It builds with pinned PlatformIO/ESP-IDF dependencies and has host protocol/timing tests. This is a new integration prototype; physical verification is tracked in its README. Mount mapping and heading accuracy remain explicitly unvalidated, so directional feedback stays gated. The Arduino sketch remains the original hardware reference.

## Repository layout

| Path | Role | Status |
|---|---|---|
| `S3Firmware/` | Integrated S3 ESP-IDF BLE/sensor/haptic prototype | Uploaded; BLE and command checks recorded in its README |
| `CircuitTest/CircuitTest.ino` | ESP32-S3 primary BNO055, redundant MPU6050, and DRV2605L bring-up | Verified Arduino prototype |
| `CircuitTest/README.md` | Circuit-test operation and troubleshooting | Current |
| `BTTest/` | ESP32-C6 NimBLE command/status prototype | Legacy protocol reference; S3 port in `S3Firmware` |
| `BTTest/ARCHITECTURE.md` | BLE architecture and GATT protocol | Protocol reference |

## Current circuit and pinout

The BNO055 is the primary fused IMU and the MPU6050 is the redundant IMU. Both
share the first ESP32-S3 hardware I2C controller. The haptic driver uses the
second controller.

| Function | Peripheral pin | XIAO ESP32-S3 GPIO | I2C address | Firmware bus |
|---|---:|---:|---:|---:|
| BNO055 data | SDA | GPIO2 | `0x28` or `0x29` | `TwoWire(0)` |
| BNO055 clock | SCL | GPIO1 | — | `TwoWire(0)` |
| MPU6050 data | SDA | GPIO2 | `0x68` with AD0 low; `0x69` with AD0 high | `TwoWire(0)` |
| MPU6050 clock | SCL | GPIO1 | — | `TwoWire(0)` |
| DRV2605L data | SDA | GPIO41 | `0x5A` | `TwoWire(1)` |
| DRV2605L clock | SCL | GPIO42 | — | `TwoWire(1)` |
| Logic reference | GND | GND | — | Shared ground required |

The pin numbers above are ESP32-S3 **GPIO numbers**, not arbitrary Arduino `D`
labels. The shared IMU bus runs at 100 kHz for conservative BNO055 operation;
the DRV2605L bus runs at 400 kHz. Ensure each bus has pull-ups to 3.3 V and that
both IMUs, the DRV2605L, motor supply, and ESP32 share a ground. Connect the
haptic actuator only to the DRV2605L outputs, never directly to an ESP32 GPIO.

The current sketch assumes an ERM motor (`HAPTIC_MOTOR_IS_LRA = false`) and
selects effect `47`, "Buzz 1 - 100%." Confirm the actuator type and rated
voltage before changing DRV2605L rated-voltage or overdrive registers.

## Verified circuit-test behavior

At boot, the sketch:

1. Starts both I2C controllers and scans them.
2. Detects the MPU6050 at `0x68` or `0x69` and the BNO055 at `0x28` or `0x29`.
3. Configures the accelerometer for +/-4 g, gyro for +/-500 degrees/second,
   and the low-pass filter for 21 Hz.
4. Averages 400 gyro samples over roughly two seconds. Keep the device still
   during this calibration.
5. Samples the MPU6050 at 100 Hz and BNO055 fused attitude at 50 Hz, then
   reports both at 10 Hz.
6. Estimates roll and pitch with a complementary filter.
7. Integrates MPU6050 gyro Z as relative yaw. This value will drift because
   the MPU6050 has no magnetometer.
8. Reports BNO055 heading, roll, pitch, and calibration state from its onboard
   NDOF fusion.
9. Detects the DRV2605L at `0x5A` and triggers a startup haptic effect.

The prototype reads both IMUs independently and makes their results visible for
comparison. It does not yet implement automatic sensor voting, fault isolation,
or failover from the BNO055 to the MPU6050; those belong in the ESP-IDF
firmware.

Open the Serial Monitor at 115200 baud. Send `h` or `H` to replay the haptic
effect. A healthy scan reports `0x28`/`0x29` and `0x68`/`0x69` on the shared
IMU bus, plus `0x5A` on the haptic bus.

## PlatformIO development

### Install PlatformIO

The easiest setup is Visual Studio Code with the **PlatformIO IDE** extension.
The same operations are available through the `pio` command-line tool. Confirm
the installation with:

```sh
pio --version
pio device list
```

### Required ESP32-S3 project configuration

Create the full firmware as a new PlatformIO project using board ID
`seeed_xiao_esp32s3` and the ESP-IDF framework. A suitable starting
`platformio.ini` is:

```ini
[env:seeed_xiao_esp32s3]
platform = espressif32
board = seeed_xiao_esp32s3
framework = espidf
monitor_speed = 115200
```

PlatformIO documents `seeed_xiao_esp32s3` as the board identifier and supports
both Arduino and ESP-IDF on this board:
[PlatformIO XIAO ESP32-S3 board documentation](https://docs.platformio.org/en/latest/boards/espressif32/seeed_xiao_esp32s3.html).

The Arduino Adafruit libraries are not production dependencies. Reimplement
the verified behavior with ESP-IDF components:

1. Create the ESP32-S3/ESP-IDF PlatformIO project without changing the circuit.
2. Add BNO055, MPU6050, and DRV2605L components using ESP-IDF's I2C driver.
3. Preserve the verified pins, addresses, bus separation, sensor ranges, and
   100 Hz sample cadence from `CircuitTest.ino`.
4. Reproduce the I2C scan, gyro calibration, orientation output, and haptic
   command before adding BLE.
5. Port the C6 NimBLE prototype into an S3 BLE component.
6. Commit each subsystem migration separately from new GPS or power work.

Use the normal ESP-IDF project layout rather than copying the `.ino` into
`src/main.cpp`. A suggested layout is:

```text
S3Firmware/
  platformio.ini
  CMakeLists.txt
  sdkconfig.defaults
  src/
    CMakeLists.txt
    main.c
    imu/
    haptics/
    ble/
```

If the serial monitor is blank, verify the active port with `pio device list`
and select the intended ESP-IDF console transport with
`pio run -e seeed_xiao_esp32s3 --target menuconfig`. Persist required settings
in `sdkconfig.defaults` instead of relying on one developer's generated local
configuration.

### Common PlatformIO commands

Run these commands from the directory containing `platformio.ini`:

```sh
# Compile the selected environment
pio run -e seeed_xiao_esp32s3

# Compile and upload over USB
pio run -e seeed_xiao_esp32s3 --target upload

# Open the serial monitor
pio device monitor --baud 115200

# Remove generated build output
pio run -e seeed_xiao_esp32s3 --target clean
```

If more than one serial device is attached, use `pio device list`, then set
`upload_port` and `monitor_port` locally. Avoid committing machine-specific
port names such as `/dev/cu.usbmodem...` or `COM5`.

## Firmware development rules for the next teammate

- Preserve the 100 Hz IMU service interval. Serial logging, BLE callbacks,
  haptic playback, GPS parsing, and flash writes must not block that loop.
- Build the full application from ESP-IDF components and FreeRTOS tasks. Keep
  Arduino APIs and Adafruit libraries confined to the verification sketch.
- Keep hardware access out of BLE callbacks. Validate incoming packets, place
  commands into a bounded queue, and let the owning application task act on
  them.
- Keep both IMUs on controller 0 and the DRV2605L on controller 1 unless the
  hardware is deliberately revised.
- Treat the BNO055 as the primary attitude source and the MPU6050 as the
  independent redundant source. A sensor being present on I2C is not enough to
  declare it healthy; track freshness, read errors, plausible ranges, and
  disagreement between sensors.
- Treat the existing complementary filter as bring-up code, not a final
  navigation-grade attitude estimator.
- Record the exact motor type, rated voltage, and DRV2605L supply before tuning
  haptic drive registers.
- Verify the I2C scan, stationary gyro output, roll/pitch response, haptic
  command, and reboot behavior before and after each subsystem integration.
- Keep board configuration, library dependencies, and reproducible build
  commands in `platformio.ini`; do not rely on globally installed libraries.

## Original integration sequence and remaining work

Steps 1–4 now have a first implementation in `S3Firmware`; the hardware README there distinguishes tested behavior from remaining work.

1. Create the ESP32-S3 ESP-IDF PlatformIO project.
2. Reimplement and reproduce the Arduino hardware test behavior under ESP-IDF.
3. Port the BLE command/status service described in
   [`BTTest/ARCHITECTURE.md`](BTTest/ARCHITECTURE.md) to the S3 ESP-IDF
   application.
4. Add bounded queues between BLE, IMU, and haptic modules.
5. Add sensor-health counters, BNO055/MPU6050 disagreement monitoring,
   explicit degraded/failover states, I2C recovery, a watchdog, and brownout
   testing.
6. Add GPS and battery monitoring only after the IMU timing remains stable
   while BLE is connected and sending notifications.

The present Arduino prototype exposes BNO055 fused heading for verification,
but the production firmware does not yet provide a validated attitude pipeline,
BLE security, GPS, battery measurement, low-power states, OTA updates, or
persistent calibration storage. Redundant hardware is present, but automatic
IMU failover is not yet implemented.

## iPhone integration handoff

The app-side [proposed BLE contract](../docs/FIRMWARE_APP_PROTOCOL.md) now includes BNO055 source, calibration and sensor-health fields, plus local magnetic-to-true-north correction. The original Arduino sketch does not implement this BLE contract; `S3Firmware` now does and has been uploaded for bench testing. Keep the S3 firmware implementation and the app contract in sync when porting from the circuit test.
