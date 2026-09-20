#include "haptics.h"
#include "motor_pattern.h"
#include "haptic_led.h"
#include "driver/i2c_master.h"
#include "esp_log.h"

static i2c_master_dev_handle_t driver;
static bool ready;
static uint8_t output;
static int64_t next_health;
static point_motor_pattern_t pattern;

static bool write_reg(uint8_t reg, uint8_t value) {
    uint8_t bytes[] = {reg, value};
    return driver && i2c_master_transmit(driver, bytes, 2, 5) == ESP_OK;
}
static bool read_reg(uint8_t reg, uint8_t *value) {
    return driver && i2c_master_transmit_receive(driver, &reg, 1, value, 1, 5) == ESP_OK;
}

void point_haptics_stop(void) {
    point_haptic_led_set(false);
    pattern.active = false;
    bool stopped = write_reg(0x02, 0); // RTP zero, then standby; attempt both on failure.
    bool standby = write_reg(0x01, 0x40);
    output = 0;
    if (!stopped || !standby) { ready = false; ESP_LOGE("point_motor", "Motor stop I2C failed; check wiring/power"); }
}

esp_err_t point_haptics_init(void) {
    esp_err_t led = point_haptic_led_init();
    if (led != ESP_OK) ESP_LOGE("point_motor", "LED unavailable: %s", esp_err_to_name(led));
    i2c_master_bus_config_t bus_cfg = {.i2c_port = 1, .sda_io_num = 41, .scl_io_num = 42,
        .clk_source = I2C_CLK_SRC_DEFAULT, .glitch_ignore_cnt = 7, .flags.enable_internal_pullup = true};
    i2c_master_bus_handle_t bus;
    esp_err_t err = i2c_new_master_bus(&bus_cfg, &bus);
    if (err != ESP_OK) return err;
    if (i2c_master_probe(bus, 0x5A, 10) != ESP_OK) return ESP_ERR_NOT_FOUND;
    i2c_device_config_t cfg = {.dev_addr_length = I2C_ADDR_BIT_LEN_7, .device_address = 0x5A, .scl_speed_hz = 400000};
    err = i2c_master_bus_add_device(bus, &cfg, &driver);
    if (err != ESP_OK) return err;
    uint8_t id, feedback, control;
    if (!read_reg(0, &id) || ((id & 0xE0) != 0xE0 && (id & 0xE0) != 0x60) ||
        !read_reg(0x1A, &feedback) || !read_reg(0x1D, &control)) return ESP_ERR_INVALID_RESPONSE;
    // Same ERM/open-loop assumption as the verified sketch. Preserve rated voltage
    // and overdrive clamp registers; no undocumented motor-voltage tuning.
    ready = write_reg(0x01, 0) && write_reg(0x02, 0) && write_reg(0x0C, 0) &&
        write_reg(0x03, 1) && write_reg(0x04, 47) && write_reg(0x05, 0) &&
        write_reg(0x0D, 0) && write_reg(0x0E, 0) && write_reg(0x0F, 0) && write_reg(0x10, 0) &&
        write_reg(0x1A, feedback & 0x7F) && write_reg(0x1D, control | 0x28);
    point_haptics_stop();
    ESP_LOGI("point_motor", "DRV2605L id=0x%02x ready=%d; ERM, unsigned RTP; no startup vibration", id, ready);
    return ready ? ESP_OK : ESP_FAIL;
}

bool point_haptics_ready(void) { return ready; }

bool point_haptics_play(const point_command_t *c, int64_t now) {
    if (c->kind == 0) { point_haptics_stop(); return ready; }
    if (!ready || !point_pattern_start(&pattern, c, now)) return false;
    output = point_pattern_output(&pattern, now);
    if (!write_reg(0x02, 0) || !write_reg(0x01, 5) || !write_reg(0x02, output)) {
        ready = false; point_haptics_stop(); return false;
    }
    point_haptic_led_set(output > 0);
    ESP_LOGI("point_motor", "Accepted kind=%u duration=%ums strength=%u", pattern.kind,
             (unsigned)((pattern.deadline_us-pattern.started_us)/1000), pattern.intensity);
    return true;
}

void point_haptics_tick(int64_t now) {
    if (!driver) return;
    bool was_active = pattern.active;
    uint8_t requested = point_pattern_output(&pattern, now);
    if (was_active && !pattern.active) {
        point_haptics_stop();
        ESP_LOGI("point_motor", "Finite cue complete");
    }
    if (ready && now >= next_health) {
        next_health = now + 100000;
        uint8_t status;
        if (!read_reg(0, &status) || (status & 3)) {
            ready = false; point_haptics_stop();
            ESP_LOGE("point_motor", "Driver health failure; motor disabled until reboot");
        }
    }
    if (!pattern.active) return;
    if (requested != output) {
        if (!write_reg(0x02, requested)) { ready = false; point_haptics_stop(); }
        else { output = requested; point_haptic_led_set(output > 0); }
    }
}
