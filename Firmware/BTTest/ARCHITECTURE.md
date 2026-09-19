# BT Test Architecture and Protocol

## Repository Status and Hardware Relationship

This document describes the checked-in **ESP32-C6 ESP-IDF BLE prototype**, not
the currently wired device. The active hardware baseline is a Seeed Studio
XIAO ESP32-S3 running `CircuitTest/CircuitTest.ino` with this pinout:

| Peripheral | SDA | SCL | Address |
|---|---:|---:|---:|
| MPU6050 | GPIO2 | GPIO1 | `0x68` or `0x69` |
| DRV2605L | GPIO41 | GPIO42 | `0x5A` |

The two peripherals use separate ESP32-S3 hardware I2C controllers. The
functional S3 test firmware and PlatformIO handoff are documented in
[`../README.md`](../README.md). None of the sensor or haptic behavior is yet
connected to the BLE implementation described below.

The full firmware will use **ESP-IDF on the ESP32-S3**. The Arduino circuit
sketch is only a functional-verification and debugging aid; it is not the
framework for the integrated firmware.

## Purpose

BT Test is a minimal Bluetooth Low Energy bring-up project for the Seeed Studio
XIAO ESP32-C6. Its purpose is to verify that a phone can:

1. Discover the ESP32-C6.
2. Establish a BLE connection.
3. Discover a custom GATT service.
4. Write a command to the device.
5. Receive a notification in response.

This is a connection and protocol prototype. It does not include the current
MPU6050 and DRV2605L drivers, GPS, navigation logic, bonding, or production
security.

## Software Architecture

```text
app_main
  |
  +-- initialize NVS
  |
  +-- bt_test_ble_start
        |
        +-- initialize the NimBLE controller and host
        +-- register the GAP and GATT services
        +-- set the device name
        +-- start the NimBLE host task
              |
              +-- synchronize with the controller
              +-- select the BLE identity address
              +-- advertise the custom service
              +-- process GAP and GATT callbacks
```

The implementation is split into two application modules:

- `main.c` initializes NVS and starts Bluetooth.
- `bt_test_ble.c` owns advertising, connections, the GATT database, and command
  processing.

NimBLE creates and owns its host task. The application does not run a polling
loop. BLE events are delivered through NimBLE callbacks.

## Startup Sequence

1. ESP-IDF starts `app_main()`.
2. NVS is initialized. If its layout is incompatible or full, the prototype
   erases and reinitializes NVS.
3. `nimble_port_init()` initializes the BLE controller and NimBLE host.
4. The standard GAP and GATT services are initialized.
5. The custom BT Test service is registered.
6. The GAP device name is set to `BT Test C6`.
7. The NimBLE FreeRTOS host task starts.
8. After the host synchronizes with the controller, connectable advertising
   begins.

## Advertising

The device advertises as a connectable, generally discoverable BLE peripheral.

| Field | Value |
|---|---|
| Device name | `BT Test C6` |
| Advertising interval | 100–150 ms |
| Primary service | `7f510001-1b15-4f0d-9e82-8a7c4d6e5f01` |
| BR/EDR support | Not supported; BLE only |

The service UUID is placed in the advertising packet. The complete device name
is placed in the scan response so the combined data fits the legacy advertising
payload limits.

Advertising restarts automatically after a failed connection, disconnect, or
advertising-complete event.

## GATT Protocol

### Service

| Name | UUID |
|---|---|
| BT Test service | `7f510001-1b15-4f0d-9e82-8a7c4d6e5f01` |

### Command characteristic

| Property | Value |
|---|---|
| UUID | `7f510002-1b15-4f0d-9e82-8a7c4d6e5f01` |
| Operations | Write, Write Without Response |
| Maximum value length | 16 bytes |
| Encoding | Opaque bytes; UTF-8 text is convenient for testing |

The command characteristic is write-only. A zero-length command is accepted.
Values longer than 16 bytes are rejected with the GATT error
`Invalid Attribute Value Length`.

### Status characteristic

| Property | Value |
|---|---|
| UUID | `7f510003-1b15-4f0d-9e82-8a7c4d6e5f01` |
| Operations | Read, Notify |
| Maximum value length | 20 bytes |
| Initial value | `ready` |

The 20-byte limit ensures that a complete status notification fits the default
23-byte ATT MTU without requiring MTU negotiation.

## Command and Response Behavior

When a client writes a command, the device updates Status to:

```text
ACK:<command bytes>
```

For example:

```text
Phone -> Command: hello
Device -> Status:  ACK:hello
```

If the phone has enabled notifications on Status, the updated value is sent as
a notification. Otherwise, the phone can read Status after writing Command.

Commands are currently echoed rather than interpreted. This confirms the
bidirectional BLE data path without coupling the prototype to navigation or
haptic semantics.

## Connection Lifecycle

```text
Disconnected
    |
    +-- advertise "BT Test C6"
            |
            +-- phone connects
                    |
                    +-- Status becomes "connected"
                    +-- phone may subscribe to Status
                    +-- phone writes Command
                    +-- device publishes ACK response
                    |
                    +-- phone disconnects
                            |
                            +-- Status becomes "ready"
                            +-- advertising restarts
```

The serial log reports:

- BLE identity address
- Advertising start
- Connection and disconnection events
- Connection interval and latency
- MTU changes
- Notification subscription changes
- Received command length

## Phone Test Procedure

Using a generic BLE application such as nRF Connect or LightBlue:

1. Scan for `BT Test C6`.
2. Connect to the device.
3. Discover the BT Test service.
4. Open the Status characteristic and enable notifications.
5. Write up to 16 bytes to the Command characteristic.
6. Confirm that Status reports `ACK:` followed by the written value.
7. Disconnect and confirm that the device becomes discoverable again.

## Current Reliability Behavior

- All GATT values use fixed-size buffers.
- Oversized commands are rejected before copying.
- No application heap allocation occurs while processing a command.
- Advertising automatically resumes after disconnection.
- NVS initialization failures caused by an incompatible or exhausted NVS
  partition are recovered during boot.
- The firmware is configured for one BLE connection.

## Prototype Limitations

The current protocol intentionally does not provide:

- Pairing, bonding, encryption requirements, or command authentication
- Application-level packet versioning, sequence numbers, or checksums
- Indications or acknowledged application commands
- Fragmentation for values larger than 16 bytes
- Connection parameter negotiation or low-power tuning
- Battery, diagnostic, IMU, GPS, navigation, or haptic characteristics
- A/B OTA updates

These omissions make phone-side bring-up simple. They must be addressed before
the BLE link is used to control a navigation aid.

## ESP32-S3 Integration Target

The GATT UUIDs and phone-facing behavior can remain stable during the first S3
port. ESP-IDF is the selected framework, so the C6 NimBLE module should be
ported into a new S3 ESP-IDF application. The verified Arduino sensor and
haptic behavior should be reimplemented as ESP-IDF components rather than
linked into the production application.

The intended runtime ownership is:

```text
MPU6050 service (100 Hz) ----> latest attitude/health snapshot
          |                                |
          |                                v
          |                         BLE notification path
          |
BLE command callback ----> bounded command queue ----> haptic service
                                                       |
                                                       v
                                                  DRV2605L
```

- The IMU service owns MPU6050 I2C access and must preserve its 100 Hz update
  cadence.
- The haptic service owns DRV2605L I2C access and consumes bounded commands.
- BLE callbacks validate and enqueue data only; they do not access either I2C
  controller or wait for an effect to complete.
- Published sensor state should use a snapshot or queue so BLE cannot stall
  the IMU path.

The echo service should eventually be replaced or expanded with versioned
characteristics for:

- Navigation commands from the phone
- Attitude notifications from the IMU pipeline
- Device and sensor health
- Battery state
- Haptic cue requests and acknowledgements
- Configuration and calibration

BLE callbacks should continue to perform only bounded validation and queue
work for application tasks. They should not poll sensors, write flash, or drive
haptic hardware directly.

Before expanding the protocol, first reproduce the working Arduino circuit-test
behavior in the PlatformIO-managed S3 ESP-IDF application. Then confirm that
the 100 Hz IMU schedule remains stable during BLE advertising, connection,
command writes, and notifications.
