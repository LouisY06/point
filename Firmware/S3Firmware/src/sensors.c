#include "sensors.h"
#include <math.h>
#include "driver/i2c_master.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_task_wdt.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#ifndef POINT_MOUNT_VALID
#define POINT_MOUNT_VALID 0
#endif
#ifndef POINT_HEADING_OFFSET_DEG
#define POINT_HEADING_OFFSET_DEG 0
#endif
#ifndef POINT_HEADING_ACCURACY_CDEG
#define POINT_HEADING_ACCURACY_CDEG 18000
#endif

static const char *TAG = "point_sensors";
static i2c_master_dev_handle_t bno, mpu;
static portMUX_TYPE lock = portMUX_INITIALIZER_UNLOCKED;
static point_attitude_t current = { .accuracy_cdeg = 18000, .source = 1, .age_ms = 65535 };
static int64_t sampled_us;
static float bias[3], roll, pitch, yaw;
static int64_t previous_mpu;
static uint32_t bno_errors, mpu_errors, missed_ticks;
static float diagnostic_angles[3];
static uint32_t diagnostic_counts[3];

static bool rd(i2c_master_dev_handle_t d, uint8_t reg, uint8_t *out, size_t n) {
    return d && i2c_master_transmit_receive(d, &reg, 1, out, n, 5) == ESP_OK;
}
static bool wr(i2c_master_dev_handle_t d, uint8_t reg, uint8_t value) {
    uint8_t b[] = {reg, value};
    return d && i2c_master_transmit(d, b, 2, 5) == ESP_OK;
}
static int16_t be16(const uint8_t *b) { return (int16_t)((uint16_t)b[0] << 8 | b[1]); }
static int16_t le16(const uint8_t *b) { return (int16_t)((uint16_t)b[1] << 8 | b[0]); }

static i2c_master_dev_handle_t find(i2c_master_bus_handle_t bus, uint8_t a, uint8_t b,
                                  uint8_t id_reg, uint8_t id_value) {
    for (uint8_t address = a; address <= b; address++) {
        if (i2c_master_probe(bus, address, 10) != ESP_OK) continue;
        i2c_device_config_t cfg = {.dev_addr_length = I2C_ADDR_BIT_LEN_7, .device_address = address,
                                 .scl_speed_hz = 100000, .scl_wait_us = 10000};
        i2c_master_dev_handle_t d;
        if (i2c_master_bus_add_device(bus, &cfg, &d) != ESP_OK) continue;
        uint8_t id;
        if (rd(d, id_reg, &id, 1) && id == id_value) {
            ESP_LOGI(TAG, "Detected sensor id=0x%02x at 0x%02x", id, address);
            return d;
        }
        i2c_master_bus_rm_device(d);
    }
    return NULL;
}

static bool init_bno(void) {
    if (!wr(bno, 0x3D, 0)) return false; // CONFIGMODE
    vTaskDelay(pdMS_TO_TICKS(25));
    if (!wr(bno, 0x3F, 0x20)) return false; // Reset fusion/calibration.
    vTaskDelay(pdMS_TO_TICKS(700));
    uint8_t id;
    if (!rd(bno, 0, &id, 1) || id != 0xA0) return false;
    if (!wr(bno, 0x07, 0) || !wr(bno, 0x3E, 0) || !wr(bno, 0x3B, 0) || !wr(bno, 0x3F, 0)) return false;
    vTaskDelay(pdMS_TO_TICKS(20));
    if (!wr(bno, 0x3D, 0x0C)) return false; // NDOF, internal crystal.
    vTaskDelay(pdMS_TO_TICKS(30));
    return true;
}

static bool init_mpu(void) {
    if (!wr(mpu, 0x6B, 0x80)) return false;
    vTaskDelay(pdMS_TO_TICKS(100));
    // PLL clock, 1 kHz / 10 sample rate, 21 Hz LPF, +/-500 dps, +/-4 g.
    if (!wr(mpu, 0x6B, 1) || !wr(mpu, 0x19, 9) || !wr(mpu, 0x1A, 4) ||
        !wr(mpu, 0x1B, 8) || !wr(mpu, 0x1C, 8)) return false;
    ESP_LOGI(TAG, "Keep still: calibrating backup gyro for 2 seconds");
    uint8_t data[14];
    for (int i = 0; i < 400; i++) {
        if (!rd(mpu, 0x3B, data, sizeof data)) return false;
        for (int j = 0; j < 3; j++) bias[j] += be16(data + 8 + 2 * j) / 65.5f / 400;
        vTaskDelay(pdMS_TO_TICKS(5));
    }
    float x = be16(data), y = be16(data + 2), z = be16(data + 4);
    roll = atan2f(y, z) * 180 / M_PI;
    pitch = atan2f(-x, sqrtf(y*y + z*z)) * 180 / M_PI;
    return true;
}

static void sample_mpu(int64_t now) {
    uint8_t data[14];
    if (!rd(mpu, 0x3B, data, sizeof data)) { mpu_errors++; return; }
    float dt = (now - previous_mpu) / 1000000.0f;
    previous_mpu = now;
    if (dt <= 0 || dt > .1f) dt = .01f;
    float x = be16(data), y = be16(data + 2), z = be16(data + 4);
    roll = .98f * (roll + (be16(data + 8)/65.5f-bias[0])*dt) + .02f * atan2f(y,z)*180/M_PI;
    pitch = .98f * (pitch + (be16(data + 10)/65.5f-bias[1])*dt) + .02f * atan2f(-x,sqrtf(y*y+z*z))*180/M_PI;
    yaw += (be16(data + 12)/65.5f-bias[2])*dt;
    // Diagnostic redundancy only. No unvalidated axis comparison or automatic yaw failover.
}

static void sample_bno(int64_t now) {
    uint8_t euler[14], state[6];
    bool good = rd(bno, 0x1A, euler, sizeof euler) && rd(bno, 0x35, state, 6);
    // state: calibration, self-test, interrupt, clock, SYS_STATUS, SYS_ERR.
    if (!good) bno_errors++;
    point_attitude_t next = {.source = 1, .reference = 1, .accuracy_cdeg = POINT_HEADING_ACCURACY_CDEG};
    if (good) {
        float heading = le16(euler)/16.0f;
        bool plausible = heading >= 0 && heading < 360 && state[4] == 5 && state[5] == 0 && (state[1] & 15) == 15;
        double norm = 0;
        for (int i = 0; i < 4; i++) {
            next.quaternion[i] = le16(euler + 6 + 2*i);
            double value = next.quaternion[i] / 16384.0;
            norm += value * value;
        }
        plausible = plausible && norm >= 0.90 && norm <= 1.10;
        heading = fmodf(heading + POINT_HEADING_OFFSET_DEG + 720, 360);
        next.heading_cdeg = (uint16_t)lroundf(heading * 100) % 36000;
        next.calibration = state[0];
        next.health = (plausible ? 1 : 0) | (POINT_MOUNT_VALID ? 2 : 0);
    }
    portENTER_CRITICAL(&lock);
    current = next;
    sampled_us = good ? now : 0;
    portEXIT_CRITICAL(&lock);
}

static void diagnostic_task(void *unused) {
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(5000));
        point_attitude_t a = point_sensors_snapshot();
        float angles[3]; uint32_t counts[3];
        portENTER_CRITICAL(&lock);
        for (int i=0; i<3; i++) { angles[i]=diagnostic_angles[i]; counts[i]=diagnostic_counts[i]; }
        portEXIT_CRITICAL(&lock);
        ESP_LOGI(TAG, "BNO heading=%.2f cal=%u/%u/%u/%u health=%02x age=%u; MPU roll=%.1f pitch=%.1f yaw=%.1f; errors=%lu/%lu late=%lu",
                 a.heading_cdeg/100.0, a.calibration>>6, (a.calibration>>4)&3,
                 (a.calibration>>2)&3, a.calibration&3, a.health, a.age_ms,
                 angles[0],angles[1],angles[2],(unsigned long)counts[0],(unsigned long)counts[1],(unsigned long)counts[2]);
    }
}

static void sensor_task(void *unused) {
    esp_task_wdt_add(NULL);
    TickType_t wake = xTaskGetTickCount();
    unsigned iteration = 0;
    for (;;) {
        int64_t now = esp_timer_get_time();
        if (mpu) sample_mpu(now);
        if (bno && iteration++ % 2 == 0) sample_bno(now);
        portENTER_CRITICAL(&lock);
        diagnostic_angles[0]=roll; diagnostic_angles[1]=pitch; diagnostic_angles[2]=yaw;
        diagnostic_counts[0]=bno_errors; diagnostic_counts[1]=mpu_errors; diagnostic_counts[2]=missed_ticks;
        portEXIT_CRITICAL(&lock);
        esp_task_wdt_reset();
        if (xTaskGetTickCount() - wake >= pdMS_TO_TICKS(10)) { missed_ticks++; wake = xTaskGetTickCount(); }
        vTaskDelayUntil(&wake, pdMS_TO_TICKS(10));
    }
}

esp_err_t point_sensors_start(void) {
    i2c_master_bus_config_t config = {.i2c_port = 0, .sda_io_num = 2, .scl_io_num = 1,
        .clk_source = I2C_CLK_SRC_DEFAULT, .glitch_ignore_cnt = 7, .flags.enable_internal_pullup = true};
    i2c_master_bus_handle_t bus;
    esp_err_t err = i2c_new_master_bus(&config, &bus);
    if (err != ESP_OK) return err;
    // Let the BNO055 finish its power-on boot before probing.
    vTaskDelay(pdMS_TO_TICKS(900));
    bno = find(bus, 0x28, 0x29, 0, 0xA0);
    mpu = find(bus, 0x68, 0x69, 0x75, 0x68);
    if (bno && !init_bno()) { ESP_LOGE(TAG, "BNO initialization failed"); i2c_master_bus_rm_device(bno); bno = NULL; }
    if (mpu && !init_mpu()) { ESP_LOGE(TAG, "MPU initialization failed"); i2c_master_bus_rm_device(mpu); mpu = NULL; }
    if (!bno) { current.source = mpu ? 2 : 1; current.reference = 0; current.health = mpu ? 8 : 0; }
    ESP_LOGW(TAG, "Pointing mount validated=%d; heading uncertainty=%.2f degrees", POINT_MOUNT_VALID, POINT_HEADING_ACCURACY_CDEG/100.0);
    // Own error counters replace per-transaction logging that could block the IMU.
    esp_log_level_set("i2c.master", ESP_LOG_NONE);
    if (xTaskCreate(diagnostic_task, "point_diag", 3072, NULL, 1, NULL) != pdPASS) return ESP_ERR_NO_MEM;
    return xTaskCreate(sensor_task, "point_imu", 4096, NULL, 6, NULL) == pdPASS ? ESP_OK : ESP_ERR_NO_MEM;
}

point_attitude_t point_sensors_snapshot(void) {
    int64_t now = esp_timer_get_time();
    portENTER_CRITICAL(&lock);
    point_attitude_t result = current;
    int64_t sample = sampled_us;
    portEXIT_CRITICAL(&lock);
    int64_t age = sample ? (now - sample)/1000 : 65535;
    result.age_ms = age < 0 || age > 65535 ? 65535 : (uint16_t)age;
    if (result.age_ms > 100) result.health &= ~1;
    return result;
}
bool point_sensors_present(void) { return bno || mpu; }
