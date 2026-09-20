# Phone stand-in retired

The temporary phone compass/grip/vibration controls have been removed. Use [glove setup](DEVICE_SETUP.md) for hardware calibration and [indoor demo](INDOOR_DEMO.md) for camera-placed test beacons. The phone supplies position and local declination; setup uses glove-only down/up poses, and live pointing and vibration come from the glove. The explicit sample outdoor route still uses a labeled simulator.

The core's historical phone-envelope/worker tests remain as regression fixtures; no app screen instantiates the retired phone tester or haptic player.
