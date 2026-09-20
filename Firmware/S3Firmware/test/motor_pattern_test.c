#include <assert.h>
#include <stdio.h>
#include "motor_pattern.h"
int main(void) {
    point_motor_pattern_t p = {0};
    point_command_t c = {.kind=1,.duration_ms=180,.intensity=160};
    assert(point_pattern_start(&p,&c,1000));
    assert(point_pattern_output(&p,180999)==160);
    assert(!point_pattern_start(&p,&c,180999)); // No unbounded extension while active.
    assert(point_pattern_output(&p,181000)==0 && !p.active);
    c.kind=2; c.duration_ms=0; c.intensity=0;
    assert(point_pattern_start(&p,&c,1000000));
    for (int ms=0; ms<=800; ms++) {
        int expected = ms < 780 && ms%220<120 ? 160 : 0;
        assert(point_pattern_output(&p,1000000+1000*ms)==expected);
    }
    assert(!p.active);
    assert(point_pattern_start(&p,&c,3000000));
    point_command_t stop = {.kind=0};
    assert(point_pattern_start(&p,&stop,3010000));
    assert(point_pattern_output(&p,3020000)==0);
    assert(point_pattern_start(&p,&c,4000000));
    assert(point_pattern_output(&p,3999999)==0 && !p.active); // Bad clock never extends output.
    assert(!point_pattern_start(&p,&c,INT64_MAX));
    puts("Motor timeline tests passed: exact deadline, four pulses, overlap rejection, stop and clock bounds.");
}
