#pragma once
#include "protocol.h"
#include "esp_err.h"

esp_err_t point_sensors_start(void);
point_attitude_t point_sensors_snapshot(void);
bool point_sensors_present(void);
