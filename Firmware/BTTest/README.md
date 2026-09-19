# BT Test

Minimal Bluetooth Low Energy connection prototype for the Seeed Studio XIAO
ESP32-C6 using ESP-IDF's NimBLE host.

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

## Build and upload

```sh
~/.platformio/penv/bin/pio run
~/.platformio/penv/bin/pio run --target upload
~/.platformio/penv/bin/pio device monitor
```

From a phone, use a generic BLE application such as nRF Connect or LightBlue,
connect to `BT Test C6`, enable notifications on Status, and write text to
Command. The same GATT workflow can later be exercised directly by the mobile
navigation application.
