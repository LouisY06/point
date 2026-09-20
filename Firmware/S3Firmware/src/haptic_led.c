#include "haptic_led.h"
#include "led_strip.h"
#include "esp_log.h"

// ESP32-S3 DevKitC-1: addressable RGB LED, not a plain GPIO LED.
// Original boards use GPIO48; revision 1.1 uses GPIO38.
#ifndef POINT_HAPTIC_LED_GPIO
#define POINT_HAPTIC_LED_GPIO 38
#endif
static led_strip_handle_t strip;

esp_err_t point_haptic_led_init(void) {
    if (strip) { led_strip_clear(strip); led_strip_del(strip); strip = NULL; }
    led_strip_config_t config = {.strip_gpio_num = POINT_HAPTIC_LED_GPIO, .max_leds = 1};
    led_strip_rmt_config_t rmt = {.resolution_hz = 10000000, .flags.with_dma = false};
    esp_err_t err = led_strip_new_rmt_device(&config, &rmt, &strip);
    if (err == ESP_OK) err = led_strip_clear(strip);
    if (err != ESP_OK && strip) { led_strip_del(strip); strip = NULL; }
    ESP_LOGI("point_led", "DevKit RGB LED GPIO%d via RMT ready=%d", POINT_HAPTIC_LED_GPIO, err == ESP_OK);
    return err;
}
void point_haptic_led_set(bool on) {
    if (!strip) return;
    // Green while the motor is commanded on; dark in gaps, on STOP and on faults.
    esp_err_t err = on ? led_strip_set_pixel(strip, 0, 0, 64, 0) : led_strip_clear(strip);
    if (on && err == ESP_OK) err = led_strip_refresh(strip);
    if (err != ESP_OK) {
        led_strip_clear(strip);
        ESP_LOGE("point_led", "RGB LED write failed: %s", esp_err_to_name(err));
    }
}
