#include <assert.h>
#include <stdio.h>
#include "haptics.h"
#include "driver/i2c_master.h"
#include "led_strip.h"
static int led_level = -1, motor_output, pending_led;
static bool fault, fail_output;
#ifndef POINT_HAPTIC_LED_GPIO
#define POINT_HAPTIC_LED_GPIO 38
#endif
esp_err_t led_strip_new_rmt_device(const led_strip_config_t *c, const led_strip_rmt_config_t *r, led_strip_handle_t *s) {
    assert(c->strip_gpio_num == POINT_HAPTIC_LED_GPIO && c->max_leds == 1);
    assert(r->resolution_hz == 10000000 && !r->flags.with_dma);
    *s = (void*)1; return ESP_OK;
}
esp_err_t led_strip_set_pixel(led_strip_handle_t s, uint32_t index, uint32_t red, uint32_t green, uint32_t blue) {
    assert(s && index == 0 && red == 0 && green == 64 && blue == 0);
    pending_led = 0; return ESP_OK;
}
esp_err_t led_strip_refresh(led_strip_handle_t s) { assert(s); led_level = pending_led; return ESP_OK; }
esp_err_t led_strip_clear(led_strip_handle_t s) { assert(s); pending_led = led_level = 1; return ESP_OK; }
esp_err_t led_strip_del(led_strip_handle_t s) { assert(s); return ESP_OK; }
esp_err_t i2c_new_master_bus(const i2c_master_bus_config_t *c, i2c_master_bus_handle_t *b) {
    assert(c->sda_io_num==41 && c->scl_io_num==42); *b=(void*)1; return ESP_OK;
}
esp_err_t i2c_master_probe(i2c_master_bus_handle_t b, int a, int t) { (void)b;(void)t;assert(a==0x5A);return ESP_OK; }
esp_err_t i2c_master_bus_add_device(i2c_master_bus_handle_t b, const i2c_device_config_t *c, i2c_master_dev_handle_t *d) {
    (void)b;(void)c;*d=(void*)1;return ESP_OK;
}
esp_err_t i2c_master_transmit(i2c_master_dev_handle_t d,const uint8_t *v,size_t n,int t) {
    (void)d;(void)t;assert(n==2);
    if(v[0]==2) {
        if (v[1] && fail_output) { fail_output=false;return ESP_FAIL; }
        motor_output=v[1];
    }
    return ESP_OK;
}
esp_err_t i2c_master_transmit_receive(i2c_master_dev_handle_t d,const uint8_t *v,size_t n,uint8_t *out,size_t count,int t) {
    (void)d;(void)t;assert(n==1 && count==1);
    *out=v[0]==0 ? (fault ? 0xE1 : 0xE0) : 0;
    return ESP_OK;
}
int main(void) {
    assert(point_haptics_init()==ESP_OK && led_level==1 && motor_output==0);
    point_command_t c={.kind=1,.duration_ms=180,.intensity=160};
    assert(point_haptics_play(&c,1000000) && led_level==0 && motor_output==160);
    assert(!point_haptics_play(&c,1010000) && led_level==0); // Rejection does not hide the existing cue.
    point_haptics_tick(1180000);
    assert(led_level==1 && motor_output==0);
    c.kind=2;c.duration_ms=c.intensity=0;
    assert(point_haptics_play(&c,2000000));
    int flashes = 0;
    bool was_lit = false;
    for(int ms=0;ms<=800;ms+=5) {
        point_haptics_tick(2000000+ms*1000);
        bool buzzing=ms<560 && ms%220<120;
        assert((led_level==0)==buzzing && (motor_output>0)==buzzing);
        if (led_level==0 && !was_lit) flashes++;
        was_lit = led_level==0;
    }
    assert(flashes==3);
    assert(point_haptics_play(&c,3000000));
    point_haptics_stop(); // Same API used by BLE disconnect, STOP and recalibration.
    assert(led_level==1 && motor_output==0);
    assert(point_haptics_play(&c,4000000));fault=true;
    point_haptics_tick(4100000);
    assert(!point_haptics_ready() && led_level==1 && motor_output==0);
    fault=false;assert(point_haptics_init()==ESP_OK);
    fail_output=true;
    assert(!point_haptics_play(&c,5000000));
    assert(!point_haptics_ready() && led_level==1 && motor_output==0);
    puts("LED/driver tests passed: DevKit RGB pixel/refresh, startup off, pulse gaps, deadline, stop and failures.");
}
