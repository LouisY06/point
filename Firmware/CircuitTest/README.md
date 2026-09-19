# ESP32-S3 Circuit Test

## Purpose and status

[`CircuitTest.ino`](CircuitTest.ino) is the current functional bring-up sketch
for the wearable prototype. It verifies the ESP32-S3, MPU6050, and DRV2605L
before those drivers are combined with BLE and navigation firmware.

This sketch is intentionally an **Arduino-only functional verification
prototype**. It is optimized for quick flashing, readable serial diagnostics,
and easy circuit debugging. The full firmware must target the ESP32-S3 using
ESP-IDF; do not grow this sketch into the production application. Use its
observed behavior and constants as the acceptance baseline for ESP-IDF drivers.

## Pinout

| Device | Signal | ESP32-S3 GPIO | Address |
|---|---|---:|---:|
| MPU6050 | SDA | GPIO2 | `0x68` or `0x69` |
| MPU6050 | SCL | GPIO1 | `0x68` or `0x69` |
| DRV2605L | SDA | GPIO41 | `0x5A` |
| DRV2605L | SCL | GPIO42 | `0x5A` |
| Both modules | GND | GND | — |

The MPU6050 uses ESP32-S3 I2C controller 0 and the DRV2605L uses controller 1.
Both are configured for 400 kHz. Use 3.3 V I2C pull-ups and a common ground.

## Arduino dependencies

Install these libraries through Arduino Library Manager:

- Adafruit MPU6050
- Adafruit Unified Sensor
- Adafruit DRV2605
- Adafruit BusIO

Select the Seeed Studio XIAO ESP32-S3 board, upload the sketch, and open the
Serial Monitor at 115200 baud.

## Test procedure

1. Place the assembly flat and keep it completely still during startup.
2. Confirm the I2C scan reports the MPU6050 at `0x68` or `0x69`.
3. Confirm the second scan reports the DRV2605L at `0x5A`.
4. Wait for gyro calibration to complete.
5. Tilt the assembly side-to-side and front-to-back; roll and pitch should
   respond smoothly.
6. Rotate it about the vertical axis; relative yaw should respond but will
   slowly drift.
7. Confirm the startup vibration. Send `h` in the Serial Monitor to replay it.
8. Leave the assembly stationary and check that gyro rates settle near zero.

The sketch samples motion at 100 Hz and prints at 10 Hz. It currently uses
effect `47` ("Buzz 1 - 100%") and assumes an ERM actuator. Change
`HAPTIC_MOTOR_IS_LRA` only if the attached actuator is actually an LRA.

## Limits

- The MPU6050 is a 6-DoF sensor and cannot provide an absolute magnetic
  heading.
- Roll and pitch are test-quality complementary-filter estimates.
- Gyro bias is recalculated on every boot and is not persisted.
- DRV2605L electrical drive parameters have not been tuned to a documented
  motor part number.
- There is no BLE, GPS, battery monitoring, watchdog, or low-power behavior in
  this sketch.

See the repository-level [`README.md`](../README.md) for the ESP32-S3 ESP-IDF
PlatformIO implementation and teammate handoff instructions.
