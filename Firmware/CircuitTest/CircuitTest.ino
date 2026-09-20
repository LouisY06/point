/*
  ESP32-S3 circuit bring-up test

  MPU6050:
    SDA = GPIO 2
    SCL = GPIO 1
    I2C address = 0x68 or 0x69 (detected automatically)

  BNO055 (shares the first I2C bus with the MPU6050):
    SDA = GPIO 2
    SCL = GPIO 1
    I2C address = 0x28 or 0x29 (detected automatically)

  DRV2605L:
    SDA = GPIO 41
    SCL = GPIO 42
    I2C address = 0x5A

  Arduino libraries required:
    - Adafruit MPU6050
    - Adafruit BNO055
    - Adafruit Unified Sensor
    - Adafruit DRV2605
    - Adafruit BusIO

  Open the Serial Monitor at 115200 baud. Keep the board still during startup
  gyro calibration. Type 'h' to replay the haptic test.

  The MPU6050 path estimates roll and pitch with a complementary filter; its
  yaw is relative-only and will drift. The BNO055 path reports its onboard
  NDOF-fused heading, roll, pitch, and calibration state for comparison.
*/

#include <Adafruit_BNO055.h>
#include <Adafruit_DRV2605.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <Wire.h>
#include <math.h>
#include <utility/imumaths.h>

namespace Config {
constexpr uint8_t IMU_SDA_PIN = 2;
constexpr uint8_t IMU_SCL_PIN = 1;
// The BNO055 supports fast mode, but 100 kHz is conservative when sharing an
// ESP32 bus with a clock-stretching BNO055.
constexpr uint32_t IMU_I2C_FREQUENCY_HZ = 100000;
constexpr uint8_t MPU_ADDRESS_LOW = 0x68;
constexpr uint8_t MPU_ADDRESS_HIGH = 0x69;
constexpr bool BNO_USE_EXTERNAL_CRYSTAL = false;

constexpr uint8_t DRV_SDA_PIN = 41;
constexpr uint8_t DRV_SCL_PIN = 42;
constexpr uint32_t DRV_I2C_FREQUENCY_HZ = 400000;

constexpr uint32_t SERIAL_BAUD = 115200;
constexpr uint32_t SERIAL_WAIT_MS = 2000;

// Run the motion filter at 100 Hz and print results at 10 Hz.
constexpr uint32_t IMU_SAMPLE_INTERVAL_US = 10000;
constexpr uint32_t BNO_SAMPLE_INTERVAL_US = 20000;  // 50 Hz fused attitude
constexpr uint32_t SERIAL_OUTPUT_INTERVAL_MS = 100;
constexpr float COMPLEMENTARY_FILTER_ALPHA = 0.98f;
constexpr float RADIANS_TO_DEGREES = 57.2957795f;

// Keep the board completely still while these samples are collected.
constexpr uint16_t GYRO_CALIBRATION_SAMPLES = 400;
constexpr uint16_t GYRO_CALIBRATION_DELAY_MS = 5;

// Most coin/pager vibration motors are ERMs. Set true for an LRA actuator.
constexpr bool HAPTIC_MOTOR_IS_LRA = false;
constexpr uint8_t HAPTIC_EFFECT = 47;  // Buzz 1 - 100%
}  // namespace Config

// The MPU6050 and BNO055 share controller 0. The DRV2605L uses controller 1.
TwoWire imuBus(0);
TwoWire drvBus(1);

Adafruit_MPU6050 mpu;
Adafruit_BNO055 bnoAtAddressA(55, BNO055_ADDRESS_A, &imuBus);
Adafruit_BNO055 bnoAtAddressB(55, BNO055_ADDRESS_B, &imuBus);
Adafruit_BNO055 *bno = nullptr;
Adafruit_DRV2605 drv;

bool mpuReady = false;
bool bnoReady = false;
bool drvReady = false;
uint8_t mpuAddress = 0;
uint8_t bnoAddress = 0;

float gyroBiasX = 0.0f;
float gyroBiasY = 0.0f;
float gyroBiasZ = 0.0f;

float rollDegrees = 0.0f;
float pitchDegrees = 0.0f;
float yawDegrees = 0.0f;
float latestGyroXDegreesPerSecond = 0.0f;
float latestGyroYDegreesPerSecond = 0.0f;
float latestGyroZDegreesPerSecond = 0.0f;
float latestTemperatureC = 0.0f;

float bnoHeadingDegrees = 0.0f;
float bnoRollDegrees = 0.0f;
float bnoPitchDegrees = 0.0f;

uint32_t previousImuSampleUs = 0;
uint32_t nextImuSampleUs = 0;
uint32_t nextBnoSampleUs = 0;
uint32_t nextSerialOutputMs = 0;

void printHexByte(uint8_t value) {
  if (value < 0x10) {
    Serial.print('0');
  }
  Serial.print(value, HEX);
}

void scanI2CBus(TwoWire &bus, const char *name) {
  Serial.print("Scanning ");
  Serial.print(name);
  Serial.println("...");

  uint8_t deviceCount = 0;
  for (uint8_t address = 1; address < 127; ++address) {
    bus.beginTransmission(address);
    const uint8_t error = bus.endTransmission();
    if (error == 0) {
      Serial.print("  Found device at 0x");
      printHexByte(address);
      Serial.println();
      ++deviceCount;
    }
  }

  if (deviceCount == 0) {
    Serial.println("  No I2C devices found.");
  }
}

void calculateAccelAngles(const sensors_event_t &accel, float &roll,
                          float &pitch) {
  const float x = accel.acceleration.x;
  const float y = accel.acceleration.y;
  const float z = accel.acceleration.z;

  roll = atan2f(y, z) * Config::RADIANS_TO_DEGREES;
  pitch = atan2f(-x, sqrtf((y * y) + (z * z))) *
          Config::RADIANS_TO_DEGREES;
}

bool calibrateGyroscope() {
  Serial.println("Keep the MPU6050 completely still; calibrating gyro...");

  float sumX = 0.0f;
  float sumY = 0.0f;
  float sumZ = 0.0f;
  sensors_event_t accel;
  sensors_event_t gyro;
  sensors_event_t temperature;

  for (uint16_t sample = 0; sample < Config::GYRO_CALIBRATION_SAMPLES;
       ++sample) {
    if (!mpu.getEvent(&accel, &gyro, &temperature)) {
      Serial.println("MPU6050 read failed during gyro calibration.");
      return false;
    }

    sumX += gyro.gyro.x;
    sumY += gyro.gyro.y;
    sumZ += gyro.gyro.z;
    delay(Config::GYRO_CALIBRATION_DELAY_MS);
  }

  gyroBiasX = sumX / Config::GYRO_CALIBRATION_SAMPLES;
  gyroBiasY = sumY / Config::GYRO_CALIBRATION_SAMPLES;
  gyroBiasZ = sumZ / Config::GYRO_CALIBRATION_SAMPLES;

  // Start roll and pitch from gravity instead of zero to avoid filter settling.
  calculateAccelAngles(accel, rollDegrees, pitchDegrees);
  yawDegrees = 0.0f;

  Serial.println("Gyro calibration complete.");
  Serial.print("  Bias X/Y/Z: ");
  Serial.print(gyroBiasX * Config::RADIANS_TO_DEGREES, 3);
  Serial.print(" / ");
  Serial.print(gyroBiasY * Config::RADIANS_TO_DEGREES, 3);
  Serial.print(" / ");
  Serial.print(gyroBiasZ * Config::RADIANS_TO_DEGREES, 3);
  Serial.println(" deg/s");
  return true;
}

bool initializeMPU6050() {
  Serial.println("\nInitializing MPU6050...");

  if (mpu.begin(Config::MPU_ADDRESS_LOW, &imuBus)) {
    mpuAddress = Config::MPU_ADDRESS_LOW;
  } else if (mpu.begin(Config::MPU_ADDRESS_HIGH, &imuBus)) {
    mpuAddress = Config::MPU_ADDRESS_HIGH;
  } else {
    Serial.println("MPU6050 initialization FAILED.");
    Serial.println("Check power, grounds, GPIO 2 (SDA), GPIO 1 (SCL), and AD0.");
    return false;
  }

  mpu.setAccelerometerRange(MPU6050_RANGE_4_G);
  mpu.setGyroRange(MPU6050_RANGE_500_DEG);
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);

  Serial.print("MPU6050 ready at 0x");
  printHexByte(mpuAddress);
  Serial.println('.');
  Serial.println("  Accelerometer range: +/-4 g");
  Serial.println("  Gyroscope range: +/-500 deg/s");
  Serial.println("  Low-pass filter bandwidth: 21 Hz");

  return calibrateGyroscope();
}

bool initializeBNO055() {
  Serial.println("\nInitializing BNO055 in NDOF fusion mode...");

  if (bnoAtAddressA.begin(OPERATION_MODE_NDOF)) {
    bno = &bnoAtAddressA;
    bnoAddress = BNO055_ADDRESS_A;
  } else if (bnoAtAddressB.begin(OPERATION_MODE_NDOF)) {
    bno = &bnoAtAddressB;
    bnoAddress = BNO055_ADDRESS_B;
  } else {
    Serial.println("BNO055 initialization FAILED.");
    Serial.println("Check power, grounds, GPIO 2 (SDA), GPIO 1 (SCL), and address.");
    return false;
  }

  bno->setExtCrystalUse(Config::BNO_USE_EXTERNAL_CRYSTAL);

  Adafruit_BNO055::adafruit_bno055_rev_info_t revision = {};
  bno->getRevInfo(&revision);

  uint8_t systemStatus = 0;
  uint8_t selfTest = 0;
  uint8_t systemError = 0;
  bno->getSystemStatus(&systemStatus, &selfTest, &systemError);

  Serial.print("BNO055 ready at 0x");
  printHexByte(bnoAddress);
  Serial.println('.');
  Serial.print("  SW revision: ");
  Serial.println(revision.sw_rev);
  Serial.print("  System status: ");
  Serial.println(systemStatus);
  Serial.print("  Self-test result: 0x");
  printHexByte(selfTest);
  Serial.println(" (0x0F means all self-tests passed)");
  Serial.print("  System error: ");
  Serial.println(systemError);
  Serial.print("  Clock source: ");
  Serial.println(Config::BNO_USE_EXTERNAL_CRYSTAL ? "external crystal"
                                                  : "internal");

  return true;
}

bool initializeDRV2605L() {
  Serial.println("\nInitializing DRV2605L...");

  if (!drv.begin(&drvBus)) {
    Serial.println("DRV2605L initialization FAILED.");
    Serial.println("Check power, grounds, GPIO 41 (SDA), and GPIO 42 (SCL).");
    return false;
  }

  if (Config::HAPTIC_MOTOR_IS_LRA) {
    drv.useLRA();
    drv.selectLibrary(6);  // LRA waveform library
  } else {
    drv.useERM();
    drv.selectLibrary(1);  // ERM waveform library
  }

  drv.setMode(DRV2605_MODE_INTTRIG);
  drv.setWaveform(0, Config::HAPTIC_EFFECT);
  drv.setWaveform(1, 0);  // End of waveform sequence

  Serial.print("DRV2605L ready at 0x");
  printHexByte(DRV2605_ADDR);
  Serial.print(" using ");
  Serial.println(Config::HAPTIC_MOTOR_IS_LRA ? "LRA mode." : "ERM mode.");
  return true;
}

void playHapticTest() {
  if (!drvReady) {
    Serial.println("Cannot play haptic effect: DRV2605L is not ready.");
    return;
  }

  // Internal-trigger playback is handled by the DRV2605L, so this call does
  // not block the IMU update schedule.
  drv.go();
  Serial.println("Haptic test triggered (effect 47: Buzz 1). Type 'h' to repeat.");
}

void updateOrientation(uint32_t sampleTimeUs) {
  sensors_event_t accel;
  sensors_event_t gyro;
  sensors_event_t temperature;

  if (!mpu.getEvent(&accel, &gyro, &temperature)) {
    Serial.println("WARNING: MPU6050 sample read failed.");
    return;
  }

  float deltaTimeSeconds =
      static_cast<float>(sampleTimeUs - previousImuSampleUs) / 1000000.0f;
  previousImuSampleUs = sampleTimeUs;

  // Reject a bad interval after a pause or debugger stop.
  if (deltaTimeSeconds <= 0.0f || deltaTimeSeconds > 0.1f) {
    deltaTimeSeconds =
        static_cast<float>(Config::IMU_SAMPLE_INTERVAL_US) / 1000000.0f;
  }

  latestGyroXDegreesPerSecond =
      (gyro.gyro.x - gyroBiasX) * Config::RADIANS_TO_DEGREES;
  latestGyroYDegreesPerSecond =
      (gyro.gyro.y - gyroBiasY) * Config::RADIANS_TO_DEGREES;
  latestGyroZDegreesPerSecond =
      (gyro.gyro.z - gyroBiasZ) * Config::RADIANS_TO_DEGREES;
  latestTemperatureC = temperature.temperature;

  float accelRollDegrees = 0.0f;
  float accelPitchDegrees = 0.0f;
  calculateAccelAngles(accel, accelRollDegrees, accelPitchDegrees);

  const float gyroRoll =
      rollDegrees + (latestGyroXDegreesPerSecond * deltaTimeSeconds);
  const float gyroPitch =
      pitchDegrees + (latestGyroYDegreesPerSecond * deltaTimeSeconds);

  rollDegrees =
      (Config::COMPLEMENTARY_FILTER_ALPHA * gyroRoll) +
      ((1.0f - Config::COMPLEMENTARY_FILTER_ALPHA) * accelRollDegrees);
  pitchDegrees =
      (Config::COMPLEMENTARY_FILTER_ALPHA * gyroPitch) +
      ((1.0f - Config::COMPLEMENTARY_FILTER_ALPHA) * accelPitchDegrees);
  yawDegrees += latestGyroZDegreesPerSecond * deltaTimeSeconds;
}

void updateBNO055() {
  const imu::Vector<3> euler =
      bno->getVector(Adafruit_BNO055::VECTOR_EULER);

  // BNO055 VECTOR_EULER order is heading (X), roll (Y), and pitch (Z).
  bnoHeadingDegrees = euler.x();
  bnoRollDegrees = euler.y();
  bnoPitchDegrees = euler.z();
}

void printMPU6050Orientation() {
  Serial.print("MPU6050 | Roll: ");
  Serial.print(rollDegrees, 1);
  Serial.print(" deg  Pitch: ");
  Serial.print(pitchDegrees, 1);
  Serial.print(" deg  Yaw(relative): ");
  Serial.print(yawDegrees, 1);
  Serial.print(" deg  Gyro X/Y/Z: ");
  Serial.print(latestGyroXDegreesPerSecond, 1);
  Serial.print('/');
  Serial.print(latestGyroYDegreesPerSecond, 1);
  Serial.print('/');
  Serial.print(latestGyroZDegreesPerSecond, 1);
  Serial.print(" deg/s  Temp: ");
  Serial.print(latestTemperatureC, 1);
  Serial.println(" C");
}

void printBNO055Orientation() {
  uint8_t systemCalibration = 0;
  uint8_t gyroCalibration = 0;
  uint8_t accelCalibration = 0;
  uint8_t magCalibration = 0;
  bno->getCalibration(&systemCalibration, &gyroCalibration, &accelCalibration,
                      &magCalibration);

  Serial.print("BNO055  | Heading: ");
  Serial.print(bnoHeadingDegrees, 1);
  Serial.print(" deg  Roll: ");
  Serial.print(bnoRollDegrees, 1);
  Serial.print(" deg  Pitch: ");
  Serial.print(bnoPitchDegrees, 1);
  Serial.print(" deg  Cal [SYS/GYR/ACC/MAG]: ");
  Serial.print(systemCalibration);
  Serial.print('/');
  Serial.print(gyroCalibration);
  Serial.print('/');
  Serial.print(accelCalibration);
  Serial.print('/');
  Serial.println(magCalibration);
}

void setup() {
  Serial.begin(Config::SERIAL_BAUD);

  const uint32_t serialWaitStart = millis();
  while (!Serial && (millis() - serialWaitStart < Config::SERIAL_WAIT_MS)) {
    delay(10);
  }

  Serial.println("\nESP32-S3 MPU6050 + BNO055 + DRV2605L circuit test");
  Serial.println("==================================================");

  imuBus.begin(Config::IMU_SDA_PIN, Config::IMU_SCL_PIN,
               Config::IMU_I2C_FREQUENCY_HZ);
  drvBus.begin(Config::DRV_SDA_PIN, Config::DRV_SCL_PIN,
               Config::DRV_I2C_FREQUENCY_HZ);

  scanI2CBus(imuBus, "shared MPU6050/BNO055 bus (SDA 2, SCL 1)");
  scanI2CBus(drvBus, "DRV2605L bus (SDA 41, SCL 42)");

  mpuReady = initializeMPU6050();
  bnoReady = initializeBNO055();
  drvReady = initializeDRV2605L();

  if (drvReady) {
    delay(100);
    playHapticTest();
  }

  if (mpuReady || bnoReady) {
    Serial.println("\nSetup complete. Sensor output follows at 10 Hz.");
    if (mpuReady) {
      Serial.println("MPU6050 yaw is relative and will drift.");
    }
    if (bnoReady) {
      Serial.println("BNO055 angles use onboard NDOF fusion.");
    }
  } else {
    Serial.println("\nSetup complete, but both IMU angle outputs are disabled.");
  }

  previousImuSampleUs = micros();
  nextImuSampleUs = previousImuSampleUs + Config::IMU_SAMPLE_INTERVAL_US;
  nextBnoSampleUs = previousImuSampleUs + Config::BNO_SAMPLE_INTERVAL_US;
  nextSerialOutputMs = millis() + Config::SERIAL_OUTPUT_INTERVAL_MS;
}

void loop() {
  const uint32_t nowUs = micros();

  // Service the IMU first at 100 Hz. Haptic playback itself is non-blocking.
  if (mpuReady && static_cast<int32_t>(nowUs - nextImuSampleUs) >= 0) {
    updateOrientation(nowUs);
    nextImuSampleUs += Config::IMU_SAMPLE_INTERVAL_US;

    // If another operation delayed us by more than one period, resume from
    // now instead of issuing a burst of stale catch-up reads.
    if (static_cast<int32_t>(nowUs - nextImuSampleUs) >= 0) {
      nextImuSampleUs = nowUs + Config::IMU_SAMPLE_INTERVAL_US;
    }
  }

  // Poll the BNO055 separately so its fused-attitude rate does not alter the
  // MPU6050 complementary-filter timing.
  if (bnoReady && static_cast<int32_t>(nowUs - nextBnoSampleUs) >= 0) {
    updateBNO055();
    nextBnoSampleUs += Config::BNO_SAMPLE_INTERVAL_US;

    if (static_cast<int32_t>(nowUs - nextBnoSampleUs) >= 0) {
      nextBnoSampleUs = nowUs + Config::BNO_SAMPLE_INTERVAL_US;
    }
  }

  const uint32_t nowMs = millis();
  if ((mpuReady || bnoReady) &&
      static_cast<int32_t>(nowMs - nextSerialOutputMs) >= 0) {
    if (mpuReady) {
      printMPU6050Orientation();
    }
    if (bnoReady) {
      printBNO055Orientation();
    }
    nextSerialOutputMs += Config::SERIAL_OUTPUT_INTERVAL_MS;

    if (static_cast<int32_t>(nowMs - nextSerialOutputMs) >= 0) {
      nextSerialOutputMs = nowMs + Config::SERIAL_OUTPUT_INTERVAL_MS;
    }
  }

  while (Serial.available() > 0) {
    const char command = static_cast<char>(Serial.read());
    if (command == 'h' || command == 'H') {
      playHapticTest();
    }
  }

  delay(1);  // Yield without materially disturbing the 100 Hz IMU schedule.
}
