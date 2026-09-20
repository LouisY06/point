#pragma once
#include <stdbool.h>
#include "esp_err.h"
esp_err_t point_haptic_led_init(void);
void point_haptic_led_set(bool on);
