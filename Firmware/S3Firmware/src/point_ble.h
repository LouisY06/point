#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

typedef struct {
    uint8_t data[16];
    uint16_t length;
    uint32_t epoch;
    int64_t received_us;
} point_request_t;
esp_err_t point_ble_start(QueueHandle_t requests);
bool point_ble_active(uint32_t epoch);
int64_t point_ble_stop_time(void);
void point_ble_reply(const point_request_t *request, const uint8_t *data, size_t length);
