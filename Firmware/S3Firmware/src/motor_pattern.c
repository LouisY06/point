#include "motor_pattern.h"
bool point_pattern_start(point_motor_pattern_t *p, const point_command_t *c, int64_t now) {
    if (c->kind == 0) { p->active = false; return true; }
    if (p->active || now < 0 || c->kind > 2 || c->intensity > 204 ||
        (c->kind == 1 && (c->duration_ms < 1 || c->duration_ms > 350))) return false;
    int64_t duration = c->kind == 2 ? 780000 : (int64_t)c->duration_ms * 1000;
    if (now > INT64_MAX - duration) return false;
    *p = (point_motor_pattern_t){.active=true, .kind=c->kind,
        .intensity=c->kind == 2 ? 160 : c->intensity, .started_us=now, .deadline_us=now+duration};
    return true;
}
uint8_t point_pattern_output(point_motor_pattern_t *p, int64_t now) {
    if (!p->active) return 0;
    if (now < p->started_us || now >= p->deadline_us) { p->active=false; return 0; }
    return p->kind == 2 && (now-p->started_us)%220000 >= 120000 ? 0 : p->intensity;
}
