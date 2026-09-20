#include <assert.h>
#include <string.h>
#include <stdio.h>
#include "protocol.h"

int main(void) {
    uint8_t pulse[] = {0xA7,1,3,0x78,0x56,0x34,0x12,1,180,0,160};
    point_command_t c;
    assert(point_decode(pulse, sizeof pulse, &c));
    assert(c.token == 0x12345678 && c.duration_ms == 180 && c.intensity == 160);
    for (size_t n = 0; n < sizeof pulse; n++) assert(!point_decode(pulse, n, &c));
    uint8_t bad[11]; memcpy(bad,pulse,11); bad[1] = 2; assert(!point_decode(bad,11,&c));
    memcpy(bad,pulse,11); bad[10] = 205; assert(!point_decode(bad,11,&c));
    memcpy(bad,pulse,11); bad[8] = 0; assert(!point_decode(bad,11,&c));
    memcpy(bad,pulse,11); bad[8] = 95; bad[9] = 1; assert(!point_decode(bad,11,&c)); // 351ms
    memcpy(bad,pulse,11); bad[7] = 2; assert(!point_decode(bad,11,&c)); // Pattern fields must be zero.
    bad[8]=bad[9]=bad[10]=0; assert(point_decode(bad,11,&c));
    uint8_t attitude_request[] = {0xA7,1,4,0x78,0x56,0x34,0x12};
    assert(point_decode(attitude_request,7,&c));
    point_attitude_t a = {.heading_cdeg=35900,.accuracy_cdeg=200,.reference=1,.source=1,.calibration=255,.health=3,.age_ms=25};
    uint8_t reply[20];
    assert(point_attitude_reply(reply,&c,&a) == 17);
    uint8_t expected[] = {0xA7,1,0x84,0x78,0x56,0x34,0x12,0x3c,0x8c,200,0,1,25,0,1,255,3};
    assert(memcmp(reply,expected,17)==0); // Same wire vector as the Swift decoder tests.
    c.op=2; a.health=1;
    assert(point_attitude_reply(reply,&c,&a)==14);
    assert((reply[9] | reply[10]<<8)==18000); // Unvalidated mount cannot bypass health via legacy request.
    c.op=5; a.quaternion[0]=16384; a.quaternion[1]=-8192;
    assert(point_attitude_reply(reply,&c,&a)==20);
    assert(reply[2]==0x85 && reply[7]==0 && reply[8]==64 && reply[9]==0 && reply[10]==224);
    assert(reply[15]==25 && reply[17]==1 && reply[18]==255 && reply[19]==1);
    uint8_t calibration[] = {0xA7,1,6,0x78,0x56,0x34,0x12};
    assert(point_decode(calibration, sizeof calibration, &c) && c.op == POINT_RECALIBRATE);
    assert(point_reply(reply,c.op,c.token) == 7 && reply[2] == 0x86);
    for (unsigned op=0; op<256; op++) {
        uint8_t packet[16] = {0xA7,1,(uint8_t)op};
        for (size_t n=0; n<=16; n++) {
            bool valid = point_decode(packet,n,&c);
            assert(valid == ((op==1 || op==2 || op==4 || op==5 || op==6) ? n==7 : op==3 && n==11));
        }
    }
    puts("Protocol tests passed: bounds, invalid opcodes, durations, retries' wire tokens and Swift-compatible attitude vector.");
}
