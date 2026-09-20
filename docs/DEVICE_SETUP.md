# Connect and calibrate the Point glove

Use the matching iPhone app and [Point S3 firmware](../Firmware/S3Firmware/README.md). The glove supplies BNO055 IMU/magnetometer orientation and DRV2605L vibration. The phone supplies location and an automatic local north correction for outdoor routes. Pointing setup uses only glove sensor samples. There is no phone-as-glove mode. The sample outdoor route remains explicitly simulated.

## Setup on iPhone

1. Fasten the sensor rigidly to the glove. Power on **Point S3**, keeping it still for the first few seconds. Disconnect other BLE clients.
2. Open **Device setup**, scan, and select **Point S3**. Wait for the connection test and firmware negotiation.
3. Hold the glove still for a few seconds to settle the gyro. If its compass needs settling, move your hand gently away from magnets and metal, then hold still again. Six-face accelerometer calibration is not required. Down/up setup needs healthy fresh orientation and gyro 3. Compass and system levels do not block these gravity poses. Navigation separately needs compass at least 2 and an acquired north reference (system above 0); accelerometer levels are informational.
4. Keep your pointing finger straight and point it directly **down**. Tap **Capture downward pose** and hold the glove still for 2.5 seconds. The app uses the glove’s gravity reference to learn the finger axis; no phone orientation or compass reference is used.
5. Point the same straight finger directly **up**. Tap **Capture upward pose** and hold still. Complete this within two minutes. The opposing pose checks that both measurements identify the same finger axis in the mounted sensor’s frame.
6. A successful check shows the measured two-pose difference. This checks mounting repeatability, not absolute compass accuracy. The directional algorithm uses a provisional 5° compass allowance plus measured pose spread/disagreement; this is an operating assumption, not a measured hardware bound. If the check fails, follow its recovery message or use **Start setup over**.
7. Use **Test glove vibration** for one finite 180 ms pulse. This explicit hardware test works without pointing setup; an acknowledgement confirms the command, not that the motor physically vibrated.

Normal automatic haptics require the calibrated pointing axis to be within **30° above or below level** and a deliberate arming gesture first. The only sensor is on the back of the hand, so a level hand alone is never treated as intent: it cannot tell an extended finger from a hand resting on a handlebar. **Walking** (default): lower the hand below about 45° down, then raise it to level within a second; the window stays open while the hand stays level and closes half a second after it drops. **Cycling** (Device setup → Glove guidance → Travel, or automatically after five seconds above 4 m/s while set to walking): lift the hand off the bar so the axis tilts at least 40° up for a quarter second, then bring it level; vibration is available for four seconds, because the hand returns to the bar level afterwards. A brief dip out of the level band keeps the window; longer gaps, stale samples or a mode change need a new gesture. These thresholds are prototype tuning values pending a worn walk and ride. The arrow uses the same accepted glove heading and hides when it becomes invalid or stale. Navigation also needs fresh GPS and a true-north correction; the phone's orientation is never the live pointing angle.

The completed finger-axis mapping is saved locally on the iPhone, keyed to the glove’s Bluetooth identifier. It restores automatically when that same glove reconnects and fresh, healthy orientation and gyro readiness return. Disconnect, backgrounding, board reset and temporary sensor faults clear live readings but do not erase this saved mounting geometry. Compass settling still pauses navigation; saving the mount does not save or bypass the sensor’s current calibration levels. Previous app versions did not persist mappings, so one successful down/up setup in this version is needed. Use **Sensor moved · Set up again** whenever the sensor slips or is remounted; slipping cannot be detected automatically. Closing the setup sheet preserves completed calibration, but discards an incomplete pose pair.

## Indoor beacons

Calibrate the glove once, then open the indoor demo. Point the glove level toward the first floor marker while tapping **Place 1**; that placement captures the room reference with no separate Align button. Add up to four beacons. Experimental pocket mode stops the camera and estimates movement from phone steps and gyro turns; face beacon 1 and stand still while pocketing the unlocked phone during its countdown. Build 12 adds touch protection and an iOS 26 Live Activity/background Bluetooth test; sustained locked-screen tracking still needs hardware verification. Camera-based position tracking remains available by turning pocket mode off. The glove always controls pointing and vibration. See [indoor instructions](INDOOR_DEMO.md).

## Recovery

- **No device:** check board power and close other BLE clients. The board supports one client at a time.
- **Firmware support pending:** install the matching S3 firmware. The legacy C6 echo service verifies communication only.
- **Pose capture fails:** follow the gyro/compass settling message and hold the glove still with a straight finger in the requested direction.
- **Upward pose disagrees:** point the same straight finger directly upward and check that the mounting did not shift. Start over after moving away from magnetic interference.
- **Waiting for true-north correction:** allow location access and wait for fresh GPS/compass readings. Indoor room guidance instead uses magnetic heading and its explicit room alignment.
- **Background or disconnect:** reopen Device setup and reconnect. The saved mounting direction restores once the sensor is ready; do not repeat the poses unless the sensor moved. Background GPS may continue a journey, but this prototype's BLE link is foreground-only.
- **Simulator:** previews screens only; it cannot validate Bluetooth, glove orientation or vibration.

## Integration and evidence

`DeviceConnection` owns BLE and setup capture; `FirmwareGlove` owns negotiated samples and bounded motor requests; `PointingCalibration` learns the sensor-to-finger vector and validates a second pose. Map telemetry observes the glove without replacing the navigation controller's event callback. Packet details are in [the shared protocol](FIRMWARE_APP_PROTOCOL.md).

On September 19, 2026 the matching S3 build was flashed with verified write hashes. A Mac BLE client passed echo, HELLO `0x1F`, fresh ATTITUDE and quaternion requests, and three finite motor requests, then disconnected. The sensor was healthy but uncalibrated (`0/3/0/0`). Mounted two-pose setup, real hand-down suppression, physical vibration and an outdoor/indoor end-to-end run still require observation with the worn glove. Automated tests establish software behavior only.

The signed matching app was installed on the connected iPhone and launched in Device setup. All 123 Swift regression tests, firmware host tests, iPhone build and simulator build pass; the disconnected setup layout was reviewed in the simulator.

Readiness follows [Bosch AN007 §3](https://www.bosch-sensortec.com/media/boschsensortec/downloads/application_notes_1/bst-bno055-an007.pdf): accelerometer calibration is optional and magnetometer level 2 is usable. The [Adafruit BNO055 guide](https://learn.adafruit.com/adafruit-bno055-absolute-orientation-sensor/device-calibration) explains why NDOF system level 0 is still blocked before north acquisition. Two-pose mounting checks and the forward-pointing gate remain required.

### Saved setup and live gyro readiness

A saved finger-axis mapping is restored when the same Bluetooth glove negotiates orientation support, even before its gyro settles. The setup section then shows **Glove pointing · Saved** and hides the down/up capture steps. Temporary gyro readiness is reported separately; it pauses directional guidance without deleting or withholding the mounting map. Once gyro readings settle, guidance can resume using that same map. Repeat the poses only after moving the sensor on the glove.
