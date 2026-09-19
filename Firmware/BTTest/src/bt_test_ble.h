#pragma once

#include "esp_err.h"

/**
 * Start the NimBLE peripheral and its host task.
 *
 * The device advertises as "BT Test C6" and exposes a small command/status
 * service intended for validation from a generic BLE phone application.
 */
esp_err_t bt_test_ble_start(void);
