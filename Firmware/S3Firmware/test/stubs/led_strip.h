#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
typedef void *led_strip_handle_t;
typedef struct { int strip_gpio_num; uint32_t max_leds; } led_strip_config_t;
typedef struct { uint32_t resolution_hz; struct { bool with_dma; } flags; } led_strip_rmt_config_t;
esp_err_t led_strip_new_rmt_device(const led_strip_config_t *, const led_strip_rmt_config_t *, led_strip_handle_t *);
esp_err_t led_strip_set_pixel(led_strip_handle_t, uint32_t, uint32_t, uint32_t, uint32_t);
esp_err_t led_strip_refresh(led_strip_handle_t);
esp_err_t led_strip_clear(led_strip_handle_t);
esp_err_t led_strip_del(led_strip_handle_t);
