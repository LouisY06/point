#include "haptic_led.h"
#include "driver/gpio.h"
#include "esp_log.h"

// XIAO ESP32-S3 user LED: GPIO21, active low (not the charge indicator).
#ifndef POINT_HAPTIC_LED_GPIO
#define POINT_HAPTIC_LED_GPIO 21
#endif
#ifndef POINT_HAPTIC_LED_ACTIVE_LOW
#define POINT_HAPTIC_LED_ACTIVE_LOW 1
#endif
static bool ready;

esp_err_t point_haptic_led_init(void) {
    gpio_config_t config = {.pin_bit_mask = 1ULL << POINT_HAPTIC_LED_GPIO,
        .mode = GPIO_MODE_OUTPUT, .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE, .intr_type = GPIO_INTR_DISABLE};
    // Preload OFF before enabling output to avoid a startup flash.
    gpio_set_level(POINT_HAPTIC_LED_GPIO, POINT_HAPTIC_LED_ACTIVE_LOW ? 1 : 0);
    esp_err_t err = gpio_config(&config);
    ready = err == ESP_OK;
    if (ready) point_haptic_led_set(false);
    ESP_LOGI("point_led", "Built-in user LED GPIO%d active-low=%d ready=%d",
             POINT_HAPTIC_LED_GPIO, POINT_HAPTIC_LED_ACTIVE_LOW, ready);
    return err;
}
void point_haptic_led_set(bool on) {
    if (ready) gpio_set_level(POINT_HAPTIC_LED_GPIO, POINT_HAPTIC_LED_ACTIVE_LOW ? !on : on);
}
