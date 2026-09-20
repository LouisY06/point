#include "protocol.h"
#include <string.h>

static uint16_t u16(const uint8_t *b) { return b[0] | ((uint16_t)b[1] << 8); }
static void put16(uint8_t *b, uint16_t v) { b[0] = v; b[1] = v >> 8; }

bool point_decode(const uint8_t *b, size_t n, point_command_t *out) {
    if (!b || !out || n < 7 || b[0] != 0xA7 || b[1] != 1 || b[2] < 1 || b[2] > POINT_RECALIBRATE) return false;
    if (n != (b[2] == POINT_HAPTIC ? 11 : 7)) return false;
    point_command_t c = { .op = b[2] };
    for (int i = 0; i < 4; i++) c.token |= (uint32_t)b[3 + i] << (8 * i);
    if (c.op == POINT_HAPTIC) {
        c.kind = b[7]; c.duration_ms = u16(b + 8); c.intensity = b[10];
        if (c.kind > 2 || c.intensity > 204) return false;
        if (c.kind == 1) {
            if (c.duration_ms < 1 || c.duration_ms > 350) return false;
        } else if (c.duration_ms || c.intensity) return false;
    }
    *out = c;
    return true;
}

size_t point_reply(uint8_t *b, uint8_t op, uint32_t token) {
    b[0] = 0xA7; b[1] = 1; b[2] = op | 0x80;
    for (int i = 0; i < 4; i++) b[3 + i] = token >> (8 * i);
    return 7;
}

size_t point_attitude_reply(uint8_t *b, const point_command_t *c, const point_attitude_t *a) {
    point_reply(b, c->op, c->token);
    if (c->op == POINT_ORIENTATION) {
        for (int i = 0; i < 4; i++) put16(b + 7 + 2*i, (uint16_t)a->quaternion[i]);
        put16(b + 15, a->age_ms);
        b[17] = a->source; b[18] = a->calibration; b[19] = a->health;
        return 20;
    }
    put16(b + 7, a->heading_cdeg); put16(b + 9, a->accuracy_cdeg);
    b[11] = a->reference; put16(b + 12, a->age_ms);
    if (c->op == POINT_ATTITUDE) {
        b[14] = a->source; b[15] = a->calibration; b[16] = a->health;
        return 17;
    }
    // Legacy messages cannot convey the health gate. Do not expose an unsafe
    // absolute heading to an older client when calibration/mounting is incomplete.
    if (a->source != 1 || a->calibration != 255 || a->health != 3) put16(b + 9, 18000);
    return 14;
}
