#pragma once
#include "protocol.h"
#include "esp_err.h"

esp_err_t point_sensors_start(void);
point_attitude_t point_sensors_snapshot(void);
bool point_sensors_present(void);

// Nonblocking request: the sensor task alone owns sensor I2C and performs reset.
bool point_sensors_request_calibration(void);
bool point_sensors_calibrating(void);
bool point_sensors_can_calibrate(void);
