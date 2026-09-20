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

Directional haptics require the calibrated finger to be within **30° above or below level**. A hand hanging down or a finger pointing vertically produces no directional feedback; raise the hand and point forward to resume. Transit arrival alerts still play with the hand lowered. The arrow uses the same accepted glove heading and hides when it becomes invalid or stale. Navigation also needs fresh GPS and a true-north correction; the phone's orientation is never the live pointing angle.

The completed finger-axis mapping is saved locally on the iPhone, keyed to the glove’s Bluetooth identifier. It restores automatically when that same glove reconnects and negotiates orientation support, even before the gyro settles. Fresh, healthy orientation and gyro readiness are still required for directional guidance. Disconnect, backgrounding, board reset and temporary sensor faults clear live readings but do not erase this saved mounting geometry. Compass settling still pauses navigation; saving the mount does not save or bypass the sensor’s current calibration levels. Previous app versions did not persist mappings, so one successful down/up setup in this version is needed. Use **Sensor moved · Set up again** whenever the sensor slips or is remounted; slipping cannot be detected automatically. Closing the setup sheet preserves completed calibration, but discards an incomplete pose pair.

## Indoor beacons

Calibrate the glove once, then open the indoor demo. The default is a **single beacon pointing test**: point the glove level toward the floor marker while placing it, start the test, and pocket the phone. Placement captures the room reference without a separate Align button. Stay in the same spot and turn/point; the camera stops and phone movement is not integrated. Touch protection and the iOS 26 Live Activity/background Bluetooth test remain available. Turn off **Single beacon pointing test** in demo options to try the four-beacon walking experiment, which estimates movement from phone steps and gyro turns and can drift. Camera-based position tracking remains available by turning pocket mode off. The glove always controls pointing and vibration. See [indoor instructions](INDOOR_DEMO.md).

## Recovery

- **No device:** check board power and close other BLE clients. The board supports one client at a time.
- **Firmware support pending:** install the matching S3 firmware. The legacy C6 echo service verifies communication only.
- **Pose capture fails:** follow the gyro/compass settling message and hold the glove still with a straight finger in the requested direction.
- **Upward pose disagrees:** point the same straight finger directly upward and check that the mounting did not shift. Start over after moving away from magnetic interference.
- **Waiting for true-north correction:** outdoor guidance needs a valid phone location and a short series of consistent local north offsets. It is then retained through brief sensor interruptions for up to 30 minutes within 2 km, with automatic refresh from stable readings. Allow location access if no reference is available. Indoor room guidance uses its own room alignment and does not require this correction.
- **Outdoor direction uncertainty is too high:** a north reference exists, but the combined glove and correction estimate exceeds the direction limit. This is separate from waiting for north or the glove's compass settling. Metal and magnetic interference can still affect the glove inside a building, even when the phone has a north reference.
- **Background or disconnect:** Point reconnects to its remembered glove when it returns to the foreground. The active pocket background test can retain the Bluetooth link. The saved mounting direction restores on reconnection; do not repeat the poses unless the sensor moved. An explicit **Disconnect** pauses automatic reconnection until you select a glove again.
- **Simulator:** previews screens only; it cannot validate Bluetooth, glove orientation or vibration.

## Integration and evidence

`DeviceConnection` owns BLE and setup capture; `FirmwareGlove` owns negotiated samples and bounded motor requests; `PointingCalibration` learns the sensor-to-finger vector and validates a second pose. Map telemetry observes the glove without replacing the navigation controller's event callback. Packet details are in [the shared protocol](FIRMWARE_APP_PROTOCOL.md).

On September 19, 2026 the matching S3 build was flashed with verified write hashes. A Mac BLE client passed echo, HELLO `0x1F`, fresh ATTITUDE and quaternion requests, and three finite motor requests, then disconnected. The sensor was healthy but uncalibrated (`0/3/0/0`). That bench run did not establish worn-glove navigation. Automated tests establish software behavior only.

The September 20, 2026 hackathon trial connected the iPhone to the S3 glove, completed finger-axis setup and produced vibration on target during a live walk. Direction drift was reported during testing. Board power loss, Bluetooth off, permission denial, missing replies, reconnection and sustained background/locked-screen behavior still need deliberate hardware trials.

The latest three-pulse arrival firmware was subsequently uploaded with verified write hashes. Startup logs confirmed the running build hash, both sensors, the built-in LED configuration and the motor driver. This verifies firmware startup, not physical LED brightness or pointing accuracy.

The signed matching app was installed on the connected iPhone and launched in Device setup. All 123 Swift regression tests, firmware host tests, iPhone build and simulator build pass; the disconnected setup layout was reviewed in the simulator.

Readiness follows [Bosch AN007 §3](https://www.bosch-sensortec.com/media/boschsensortec/downloads/application_notes_1/bst-bno055-an007.pdf): accelerometer calibration is optional and magnetometer level 2 is usable. The [Adafruit BNO055 guide](https://learn.adafruit.com/adafruit-bno055-absolute-orientation-sensor/device-calibration) explains why NDOF system level 0 is still blocked before north acquisition. Two-pose mounting checks and the forward-pointing gate remain required.

### Saved setup and live gyro readiness

A saved finger-axis mapping is restored when the same Bluetooth glove negotiates orientation support, even before its gyro settles. The setup section then shows **Glove pointing · Saved** and hides the down/up capture steps. Temporary gyro readiness is reported separately; it pauses directional guidance without deleting or withholding the mounting map. Once gyro readings settle, guidance can resume using that same map. Repeat the poses only after moving the sensor on the glove.

### Restart the hardware sensors

**Hardware sensor calibration → Restart sensor calibration** is separate from **Sensor moved · Set up again**. It stops motor output, restarts BNO055 fusion/calibration and remeasures the backup gyro bias. Keep the glove still until its live gyro level reaches 3/3, then move gently away from magnets to settle the compass. The saved finger direction is preserved. A hardware reset changes the room direction reference, so restore it or place the demo beacon again. The control requires the firmware's opcode-6 capability; older firmware shows an update instruction. Serial `c` is an alternative. The DevKit addressable RGB LED follows motor pulses using the RMT driver. Its pin is GPIO48 on original DevKitC-1 boards or GPIO38 on revision 1.1; use the matching firmware environment. Earlier XIAO GPIO21 LED builds targeted the wrong board.

### Remembered Bluetooth glove

After a verified connection, Point saves that peripheral's UUID and reconnects on launch, foreground return, Bluetooth becoming available, or an unexpected foreground disconnect. It retrieves that exact device, with a service scan restricted to the saved UUID if the OS cache is empty. Retry delays increase from 2 seconds to a 30-second cap. It never chooses another glove just because its name matches.

Existing installs with exactly one valid saved finger mapping migrate that glove into connection memory. Multiple saved gloves require one explicit choice. **Disconnect** pauses automatic reconnection, including across launches, until the user selects a glove again. Outside the active pocket background session, reconnection waits for the foreground. Reconnecting does not fabricate a restored room reference; that still needs the known beacon.
