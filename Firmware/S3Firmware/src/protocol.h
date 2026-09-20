#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { POINT_HELLO = 1, POINT_HEADING = 2, POINT_HAPTIC = 3, POINT_ATTITUDE = 4, POINT_ORIENTATION = 5, POINT_RECALIBRATE = 6 };
typedef struct {
    uint8_t op, kind, intensity;
    uint16_t duration_ms;
    uint32_t token;
} point_command_t;

typedef struct {
    int16_t quaternion[4]; // BNO055 W, X, Y, Z, scale 16384.
    uint16_t heading_cdeg, accuracy_cdeg, age_ms;
    uint8_t reference, source, calibration, health;
} point_attitude_t;

bool point_decode(const uint8_t *bytes, size_t count, point_command_t *out);
size_t point_reply(uint8_t *out, uint8_t op, uint32_t token);
size_t point_attitude_reply(uint8_t *out, const point_command_t *command, const point_attitude_t *attitude);
