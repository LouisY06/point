#pragma once
#include "protocol.h"
typedef struct {
    bool active;
    uint8_t kind, intensity;
    int64_t started_us, deadline_us;
} point_motor_pattern_t;
bool point_pattern_start(point_motor_pattern_t *pattern, const point_command_t *command, int64_t now);
uint8_t point_pattern_output(point_motor_pattern_t *pattern, int64_t now);
