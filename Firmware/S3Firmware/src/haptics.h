#pragma once
#include "esp_err.h"
#include "protocol.h"

esp_err_t point_haptics_init(void);
bool point_haptics_ready(void);
bool point_haptics_play(const point_command_t *command, int64_t now);
void point_haptics_tick(int64_t now);
void point_haptics_stop(void);
