# ESP32-S3 Circuit Test

## Purpose and status

[`CircuitTest.ino`](CircuitTest.ino) is the current bring-up sketch for the
wearable prototype. The combined BNO055, MPU6050, and DRV2605L test is
functioning and has been verified on the assembled circuit.

This sketch is intentionally an **Arduino-only functional verification
prototype**. It is optimized for quick flashing, readable serial diagnostics,
and easy circuit debugging. The full firmware must target the ESP32-S3 using
ESP-IDF; do not grow this sketch into the production application. Use its
observed behavior and constants as the acceptance baseline for ESP-IDF drivers.

## Pinout

| Device | Role | Signal | ESP32-S3 GPIO | Address |
|---|---|---|---:|---:|
| BNO055 | Primary fused IMU | SDA | GPIO2 | `0x28` or `0x29` |
| BNO055 | Primary fused IMU | SCL | GPIO1 | `0x28` or `0x29` |
| MPU6050 | Redundant IMU | SDA | GPIO2 | `0x68` or `0x69` |
| MPU6050 | Redundant IMU | SCL | GPIO1 | `0x68` or `0x69` |
| DRV2605L | Haptic driver | SDA | GPIO41 | `0x5A` |
| DRV2605L | Haptic driver | SCL | GPIO42 | `0x5A` |
| All modules | Logic reference | GND | GND | — |

The MPU6050 and BNO055 share ESP32-S3 I2C controller 0 at 100 kHz. The
DRV2605L uses controller 1 at 400 kHz. Use 3.3 V I2C pull-ups and a common
ground.

## IMU roles and redundancy

- The BNO055 is the primary attitude source. Its onboard NDOF fusion supplies
  heading, roll, pitch, and calibration state.
- The MPU6050 is the independent redundant inertial source. The sketch applies
  a complementary filter for roll and pitch and integrates relative yaw.
- The test sketch reads and displays both sources, which verifies that both can
  coexist on the shared bus and makes comparison easy.
- Redundancy is currently observational only. The sketch does not vote between
  sensors or automatically fail over when one becomes stale or implausible.

## Arduino dependencies

Install these libraries through Arduino Library Manager:

- Adafruit MPU6050
- Adafruit BNO055
- Adafruit Unified Sensor
- Adafruit DRV2605
- Adafruit BusIO

Select the Seeed Studio XIAO ESP32-S3 board, upload the sketch, and open the
Serial Monitor at 115200 baud.

## Test procedure

1. Place the assembly flat and keep it completely still during startup.
2. Confirm the shared I2C scan reports the BNO055 at `0x28` or `0x29` and the
   MPU6050 at `0x68` or `0x69`.
3. Confirm the second scan reports the DRV2605L at `0x5A`.
4. Wait for gyro calibration to complete.
5. Tilt the assembly side-to-side and front-to-back; roll and pitch should
   respond smoothly.
6. Rotate it about the vertical axis; relative yaw should respond but will
   slowly drift.
7. Confirm the BNO055 line reports heading, roll, pitch, and calibration values.
8. Move the assembly through the BNO055 calibration motions and confirm its
   `SYS/GYR/ACC/MAG` values progress toward `3/3/3/3`.
9. Confirm the startup vibration. Send `h` in the Serial Monitor to replay it.
10. Leave the assembly stationary and check that gyro rates settle near zero.

The sketch samples the MPU6050 at 100 Hz, samples BNO055 fused attitude at
50 Hz, and prints both at 10 Hz. It currently uses effect `47`
("Buzz 1 - 100%") and assumes an ERM actuator. Change
`HAPTIC_MOTOR_IS_LRA` only if the attached actuator is actually an LRA.

## Limits

- The MPU6050 is a 6-DoF sensor and cannot provide an absolute magnetic
  heading.
- BNO055 heading depends on magnetometer calibration and installation away
  from the motor, magnets, and ferrous material.
- Automatic primary/redundant IMU fault detection and failover are not yet
  implemented.
- Roll and pitch are test-quality complementary-filter estimates.
- Gyro bias is recalculated on every boot and is not persisted.
- DRV2605L electrical drive parameters have not been tuned to a documented
  motor part number.
- There is no BLE, GPS, battery monitoring, watchdog, or low-power behavior in
  this sketch.

See the repository-level [`README.md`](../README.md) for the ESP32-S3 ESP-IDF
PlatformIO implementation and teammate handoff instructions.
