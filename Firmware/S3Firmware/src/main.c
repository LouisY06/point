#include <string.h>
#include "point_ble.h"
#include "protocol.h"
#include "sensors.h"
#include "haptics.h"
#include "driver/uart.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_task_wdt.h"
#include "nvs_flash.h"
#include "freertos/task.h"

static QueueHandle_t requests;
static uint32_t last_epoch, last_motor_token, motor_epoch;
static uint8_t last_motor_packet[11], last_motor_result;
static bool have_motor_token, motor_from_ble;
static uint32_t last_calibration_token;
static uint8_t last_calibration_result;
static bool have_calibration_token;

static void handle_request(point_request_t *request, int64_t now) {
    if (!point_ble_active(request->epoch)) return;
    if (last_epoch != request->epoch) {
        last_epoch = request->epoch;
        have_motor_token = false;
        have_calibration_token = false;
    }
    uint8_t reply[20];
    if (!request->length || request->data[0] != 0xA7) {
        memcpy(reply, "ACK:", 4);
        memcpy(reply + 4, request->data, request->length);
        point_ble_reply(request, reply, request->length + 4);
        return;
    }
    point_command_t c;
    if (!point_decode(request->data, request->length, &c)) return;
    size_t length = point_reply(reply, c.op, c.token);
    switch (c.op) {
    case POINT_HELLO:
        reply[length++] = (point_sensors_present() ? 25 : 0) | (point_haptics_ready() ? 6 : 0) | (point_sensors_can_calibrate() ? 32 : 0);
        break;
    case POINT_HEADING:
    case POINT_ATTITUDE:
    case POINT_ORIENTATION: {
        point_attitude_t attitude = point_sensors_snapshot();
        length = point_attitude_reply(reply, &c, &attitude);
        break;
    }
    case POINT_RECALIBRATE: {
        if (have_calibration_token && c.token == last_calibration_token) {
            reply[length++] = last_calibration_result; break; // Retry cannot restart calibration.
        }
        bool newer = !have_calibration_token || (int32_t)(c.token - last_calibration_token) > 0;
        bool fresh = now >= request->received_us && now - request->received_us <= 300000;
        bool accepted = newer && fresh && request->received_us > point_ble_stop_time();
        if (accepted) {
            point_haptics_stop(); motor_from_ble = false;
            accepted = point_sensors_request_calibration();
        }
        reply[length++] = accepted ? 0 : 1;
        if (newer) {
            have_calibration_token = true; last_calibration_token = c.token;
            last_calibration_result = accepted ? 0 : 1;
        }
        break;
    }
    case POINT_HAPTIC: {
        bool accepted = false;
        bool duplicate = have_motor_token && c.token == last_motor_token;
        if (duplicate) {
            // Exact retry may repeat its ACK, never the motor action.
            reply[length++] = memcmp(last_motor_packet, request->data, 11) == 0 ? last_motor_result : 1;
            break;
        }
        bool newer = !have_motor_token || (int32_t)(c.token - last_motor_token) > 0;
        bool fresh = now >= request->received_us && now - request->received_us <= 300000;
        bool after_stop = request->received_us > point_ble_stop_time();
        if (c.kind == 0 || (newer && fresh && after_stop)) {
            accepted = (c.kind == 0 || !point_sensors_calibrating()) && point_haptics_play(&c, now);
            if (accepted) { motor_epoch = request->epoch; motor_from_ble = c.kind != 0; }
        }
        reply[length++] = accepted ? 0 : 1;
        if (newer) {
            have_motor_token = true; last_motor_token = c.token;
            memcpy(last_motor_packet, request->data, 11);
            last_motor_result = accepted ? 0 : 1;
        }
        break;
    }
    }
    point_ble_reply(request, reply, length);
}

static void application_task(void *unused) {
    esp_task_wdt_add(NULL);
    int64_t observed_stop = 0;
    TickType_t wake = xTaskGetTickCount();
    for (;;) {
        int64_t now = esp_timer_get_time();
        int64_t stop = point_ble_stop_time();
        if (stop != observed_stop || (motor_from_ble && !point_ble_active(motor_epoch))) {
            point_haptics_stop(); motor_from_ble = false; observed_stop = stop;
        }
        point_haptics_tick(now);
        point_request_t request;
        // Bounded work per tick: a flooding client cannot starve motor deadlines.
        for (int i = 0; i < 2 && xQueueReceive(requests, &request, 0) == pdTRUE; i++) {
            handle_request(&request, esp_timer_get_time());
        }
        uint8_t key;
        if (uart_read_bytes(UART_NUM_0, &key, 1, 0) == 1) {
            if (key == 's' || key == 'S') { point_haptics_stop(); motor_from_ble = false; }
            else if (key == 'c' || key == 'C') {
                point_haptics_stop(); motor_from_ble = false;
                bool accepted = point_sensors_request_calibration();
                ESP_LOGI("point", "Hardware recalibration requested=%d", accepted);
            }
            else if ((key == 'h' || key == 'H') && !point_sensors_calibrating()) {
                point_command_t c = {.kind = 1, .duration_ms = 180, .intensity = 160};
                if (point_haptics_play(&c, esp_timer_get_time())) motor_from_ble = false;
            }
        }
        esp_task_wdt_reset();
        if (xTaskGetTickCount() - wake >= pdMS_TO_TICKS(5)) wake = xTaskGetTickCount();
        vTaskDelayUntil(&wake, pdMS_TO_TICKS(5));
    }
}

void app_main(void) {
    ESP_LOGI("point", "Point S3 v1: BNO055 + MPU6050 + DRV2605L + BLE");
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase()); err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);
    ESP_ERROR_CHECK(point_sensors_start());
    err = point_haptics_init();
    if (err != ESP_OK) ESP_LOGE("point", "Motor unavailable: %s", esp_err_to_name(err));
    requests = xQueueCreate(8, sizeof(point_request_t));
    ESP_ERROR_CHECK(requests ? ESP_OK : ESP_ERR_NO_MEM);
    ESP_ERROR_CHECK(uart_driver_install(UART_NUM_0, 256, 0, 0, NULL, 0));
    ESP_ERROR_CHECK(point_ble_start(requests));
    ESP_ERROR_CHECK(xTaskCreate(application_task, "point_app", 4096, NULL, 5, NULL) == pdPASS ? ESP_OK : ESP_ERR_NO_MEM);
    ESP_LOGI("point", "Ready: scan for Point S3. Serial h=180ms motor + LED test; s=stop; c=restart sensor calibration.");
}
