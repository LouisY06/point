# BT Test: ESP32-C6 BLE Prototype

> **Repository status:** This is the earlier Seeed Studio XIAO ESP32-C6 BLE
> prototype. The active circuit now uses an ESP32-S3, MPU6050, and DRV2605L.
> The current hardware baseline and PlatformIO handoff are documented in
> [`../README.md`](../README.md). This project remains useful as protocol and
> NimBLE lifecycle reference code, but it has not been ported to the S3.

BT Test is a minimal Bluetooth Low Energy connection prototype for the Seeed
Studio XIAO ESP32-C6 using ESP-IDF's NimBLE host.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the current software architecture,
GATT protocol, connection lifecycle, and prototype limitations.

## What it exposes

The board advertises as `BT Test C6` with this custom service:

- Service: `7f510001-1b15-4f0d-9e82-8a7c4d6e5f01`
- Command: `7f510002-1b15-4f0d-9e82-8a7c4d6e5f01` (write/write without response)
- Status: `7f510003-1b15-4f0d-9e82-8a7c4d6e5f01` (read/notify)

Writing up to 16 bytes to Command changes Status to `ACK:<payload>` and sends
a notification to subscribed clients. This is intentionally unsecured for
bring-up; pairing and command authentication belong in the production phase.

## Build and upload the C6 prototype

The checked-in `platformio.ini` intentionally targets
`seeed_xiao_esp32c6` with the ESP-IDF framework. Run these commands from the
`Firmware/BTTest` directory:

```sh
pio run -e seeed_xiao_esp32c6
pio run -e seeed_xiao_esp32c6 --target upload
pio device monitor --baud 115200
```

From a phone, use a generic BLE application such as nRF Connect or LightBlue,
connect to `BT Test C6`, enable notifications on Status, and write text to
Command. The same GATT workflow can later be exercised directly by the mobile
navigation application.

## Porting note for the ESP32-S3

Do not only change the board name and assume the combined firmware is done.
The working circuit test currently uses the Arduino framework and Adafruit
sensor libraries, while this prototype uses ESP-IDF C and NimBLE. The full
firmware environment is explicitly **ESP-IDF on the ESP32-S3**, managed through
PlatformIO. Arduino remains limited to circuit verification and easy debugging.

The next teammate should create the S3 ESP-IDF project, port this NimBLE module,
and implement MPU6050 and DRV2605L access as ESP-IDF components. Retain the
UUIDs and command/status behavior unless the phone application is updated at
the same time. Rename the advertised device from `BT Test C6` during the S3
port. BLE callbacks must enqueue work rather than reading the IMU or triggering
the haptic driver directly.
