idf_component_register(SRCS "main.c" "point_ble.c" "protocol.c" "sensors.c" "haptics.c" "motor_pattern.c"
    INCLUDE_DIRS "." REQUIRES bt nvs_flash esp_driver_i2c esp_driver_uart esp_timer esp_system)
