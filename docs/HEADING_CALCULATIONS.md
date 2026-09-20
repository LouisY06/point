# Heading Calculations Reference

Reference for how the glove determines the direction it is pointing in the world and how that is compared to the phone's navigation target. This document focuses on the mathematical calculations; see [HARDWARE_INTERFACE.md](HARDWARE_INTERFACE.md) for the current hardware contract.

## 1. System overview

|| Component | Role |
||---|---|
|| Glove controller (XIAO ESP32-class BLE board; current firmware prototype targets the ESP32-C6) | Reads IMU, computes glove heading, BLE peripheral |
|| BNO055 (or BNO085) IMU (back of hand) | Onboard sensor fusion → absolute orientation quaternion |
|| iOS app (BLE central) | GPS position, route/waypoints, bearing to next waypoint, magnetic declination, alignment decision, confirm/stop haptic commands |
|| Haptic motor (wrist) | Executes the finite confirmation pulse the phone requests |

**Core principle:** the phone's orientation is irrelevant. The glove reports its heading in an absolute north-referenced frame; the phone computes the bearing to the next waypoint in the same frame and owns the alignment decision. Navigation = the difference between the two.

```
error = wrap180( bearing_to_waypoint − glove_heading )
```

## 2. Reference frames

- **Sensor frame (S):** IMU's own axes. Define `f_s` = unit vector along the index finger. Determine which axis this is physically once the board is mounted and document it in code (e.g. `FINGER_AXIS = {1,0,0}`).
- **World frame (W):** North-East-Down (NED). `x = magnetic north`, `y = east`, `z = down`. Headings are clockwise from north, 0–360°.
- **Quaternion `q`:** rotation from S to W, as output by the BNO055 in NDOF mode (`w, x, y, z`, unit norm).

Check the BNO055 axis-remap registers (`AXIS_MAP_CONFIG`, `AXIS_MAP_SIGN`) so the fusion output matches the physical mounting orientation. If the outputs look mirrored or off by 90°, this is the first thing to check.

## 3. Math

### 3.1 How the IMU knows "world" (background; the BNO055 does this internally)

Two known world vectors measured in the sensor frame determine orientation:

```
a = accelerometer (≈ gravity when not accelerating)
m = magnetometer

down  = −a / |a|
east  = (m × down) / |m × down|
north = down × east
```

`[north; east; down]` (as rows) is the rotation matrix from sensor to world. The gyro is integrated to smooth this and bridge moments when the hand is accelerating. The fused result is the quaternion `q`.

Consequences:
- Without the magnetometer there is no absolute yaw (heading drifts). Game rotation vector / IMU-only modes are **not** sufficient for navigation.
- Heading quality is bounded entirely by magnetometer calibration and local magnetic distortion.

### 3.2 Finger direction in the world

Rotate `f_s` by `q`:

```
f_w = q ⊗ (0, f_s) ⊗ q*
```

For `f_s = (1, 0, 0)` this is the first column of `R(q)`:

```
f_w.north = 1 − 2(y² + z²)
f_w.east  = 2(x·y + w·z)
f_w.down  = 2(x·z − w·y)
```

For a general finger axis use the full rotation matrix:

```
R(q) = | 1−2(y²+z²)   2(xy−wz)     2(xz+wy)   |
       | 2(xy+wz)     1−2(x²+z²)   2(yz−wx)   |
       | 2(xz−wy)     2(yz+wx)     1−2(x²+y²) |

f_w = R(q) · f_s
```

### 3.3 Heading and pitch

```
heading_mag  = atan2( f_w.east, f_w.north )          // radians, CW from magnetic north
heading_mag  = fmod(heading_mag_deg + 360, 360)      // normalize to [0, 360)
heading_true = wrap360( heading_mag + declination )  // declination supplied by phone (deg, east +)

pitch = asin( −f_w.down )                             // + = pointing up
```

Gate: if `|pitch| > PITCH_MAX` (start with 60°), the horizontal projection is too short and heading is unreliable → report low reliability (a large accuracy estimate) so the phone suppresses confirmation.

### 3.4 Bearing to waypoint (phone side)

Initial great-circle bearing from (φ₁, λ₁) to (φ₂, λ₂), all in radians:

```
Δλ = λ₂ − λ₁
θ  = atan2( sin(Δλ)·cos(φ₂),
            cos(φ₁)·sin(φ₂) − sin(φ₁)·cos(φ₂)·cos(Δλ) )
bearing_true = wrap360( degrees(θ) )
```

Distance (haversine, for waypoint-reached logic):

```
a = sin²(Δφ/2) + cos(φ₁)·cos(φ₂)·sin²(Δλ/2)
d = 2·R·atan2( √a, √(1−a) )     // R = 6371000 m
```

### 3.5 Error and wrapping

```
wrap180(x) = fmod(x + 540, 360) − 180        // result in (−180, 180]
error = wrap180( bearing_true − heading_true )
```

- `error < 0` → target is to the left of where the hand points
- `error > 0` → target is to the right
- `|error| ≤ 25°` for 200 ms → on target; remain aligned until `|error| > 35°`

## 4. Where computation lives

Under the current interface the **phone is the brain**: it owns routing *and* the alignment decision, and it drives the glove with semantic commands. The glove is a heading sensor plus a haptic actuator — it does not compute the pointing error or decide when to buzz. See [HARDWARE_INTERFACE.md](HARDWARE_INTERFACE.md) for the authoritative contract.

- **Glove → phone (streaming):** true-north pointing heading (§3.3), an estimated heading accuracy, and a sample time. Optionally calibration status and gesture/battery events. This is the output of §2–§3.3 running on the glove.
- **Phone:** computes `bearing_true` to the active waypoint (§3.4), compares it against the glove heading to get `error` (§3.5), then applies the validity checks, dwell, and hysteresis from §9 before deciding alignment. Combined heading and GPS bearing uncertainty is retained for diagnostics only.
- **Phone → glove:** `confirm(durationMs, intensity)` once alignment is stable, `stop` when pointing is lost or the data becomes unreliable. There are no left/right/on-target motor codes in this version.

The glove must end a finite `confirm` pulse locally even if BLE disconnects or iOS suspends the app, and must not keep buzzing on stale data.

> **Superseded model.** An earlier revision had the ESP32 receive the bearing, compute `error`, and drive left/right haptics autonomously (a ~1 Hz nav-target packet phone→glove, haptics on the board). That is no longer the design: the error math (§3.5) and the haptic decision live on the phone. Keeping the alignment loop on the phone is why the byte-level nav-target packet was dropped.

Open question: whether the magnetic→true-north conversion (§3.3 declination) happens on the glove or in the phone-side transport adapter is still TBD — see [HARDWARE_INTERFACE.md](HARDWARE_INTERFACE.md) and [PROJECT_PLAN.md](PROJECT_PLAN.md).

## 5. Current hardware interface

The current project uses a simplified hardware interface. See [HARDWARE_INTERFACE.md](HARDWARE_INTERFACE.md) for the complete contract.

Key differences from earlier designs:
- **Single confirmation pulse**: The glove provides a finite confirmation pulse when pointing is aligned, not left/right directional guidance
- **Semantic commands**: Phone sends `confirm(durationMs, intensity)` and `stop` commands rather than raw motor codes
- **Simpler BLE contract**: The exact protocol is still to be agreed; the earlier detailed byte-layout suggestions are not binding
- **Firmware status**: A BLE bring-up prototype (`Firmware/BTTest`, ESP32-C6, NimBLE) currently exposes a generic echo service to validate the phone↔board data path. Its navigation characteristics (heading notifications, `confirm`/`stop`) are not implemented yet — see `Firmware/BTTest/ARCHITECTURE.md` §"Evolution into the Navigation Protocol"

## 6. Calibration (this is where things fail)

BNO055 calibration status register `CALIB_STAT`: 2 bits each for sys, gyro, accel, mag (0 = uncalibrated, 3 = fully calibrated).

Rules:
1. **Do not report a usable heading unless `mag ≥ 2` and `sys ≥ 1`.** Below that, report a large accuracy estimate (or an explicit calibration-needed status) so the phone suppresses confirmation and can surface a "calibrate me" prompt. The glove no longer decides haptics itself (see §4).
2. Magnetometer calibration = figure-8 motion. Gyro = hold still. Accel = several static orientations.
3. Calibration is lost on power cycle. **Persist the 22-byte offset block** to NVS/flash once `sys == 3`, and restore it on boot (write offsets in CONFIG mode, then switch back to NDOF).
4. Re-check status continuously; magnetic disturbance will drop `mag` at runtime.

### Magnetic interference
- Keep the IMU as far as possible from the haptic motor, battery, and any screws/steel. IMU on back of hand, battery/motor on wrist is the intended layout.
- Bikes are steel + moving magnets. Validate bike mode on an actual bike, not a bench.
- Hard-iron (constant offset) is handled by calibration; soft-iron (distortion) is partially handled. Large nearby ferrous objects are not handled at all — gate on calibration status.

### Sanity check via phone
`CLLocation.course` (GPS course over ground) is valid when moving > ~1 m/s and is independent of phone orientation. If the user is walking toward the waypoint but the glove heading disagrees by > 90° while the hand is roughly forward, flag likely mag corruption.

## 7. Unit test vectors

Identity quaternion `(1,0,0,0)` with `f_s = (1,0,0)` → `f_w = (1,0,0)` → heading 0°, pitch 0°.

90° yaw right about `z` (down): `q = (cos45°, 0, 0, sin45°) = (0.7071, 0, 0, 0.7071)` → `f_w = (0, 1, 0)` → heading 90°.

45° pitch up about `y` (east): `q = (cos22.5°, 0, −sin22.5°, 0)` → `f_w ≈ (0.707, 0, −0.707)` → heading 0°, pitch +45°.

`wrap180(350 − 10) = −20`, `wrap180(10 − 350) = +20`, `wrap180(180) = 180`, `wrap180(−180) = 180`.

## 8. Notes on BNO085

If swapping to the BNO085: use the **Rotation Vector** report (includes mag) for navigation, not the Game Rotation Vector. It provides a heading accuracy estimate in radians — gate on that instead of `CALIB_STAT`. Everything from §3 onward is unchanged.

## 9. Current implementation parameters

From the current project tuning (see [PROJECT_PLAN.md](PROJECT_PLAN.md)):

|| Parameter | Current value |
|| --- | --- |
|| Required heading frame | True north |
|| Maximum heading age | 0.5 seconds |
|| Maximum heading uncertainty | 25 degrees |
|| Combined heading and position angular uncertainty | Diagnostic only |
|| Enter alignment | Measured angular error at most 25 degrees |
|| Leave alignment | Measured angular error above 35 degrees |
|| Stable alignment dwell | 200 ms |
|| Confirmation pulse | 180 ms; intensity value 160 on the app's UInt8 scale |
|| Minimum interval between pulses | 900 ms |

These are prototype defaults, not calibrated hardware specifications.
