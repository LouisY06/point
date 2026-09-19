idf_component_register(
    SRCS
        "main.c"
        "bt_test_ble.c"
    INCLUDE_DIRS "."
    REQUIRES
        bt
        nvs_flash
)
