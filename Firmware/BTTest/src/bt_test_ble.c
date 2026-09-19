#include "bt_test_ble.h"

#include <stdint.h>
#include <string.h>

#include "esp_log.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "os/os_mbuf.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#define BT_TEST_DEVICE_NAME "BT Test C6"
/* ACK plus payload stays within the 20-byte default ATT notification payload. */
#define BT_TEST_COMMAND_MAX_LEN 16U
#define BT_TEST_STATUS_MAX_LEN 20U

/*
 * UUIDs as displayed by common BLE phone applications:
 *   Service: 7f510001-1b15-4f0d-9e82-8a7c4d6e5f01
 *   Command: 7f510002-1b15-4f0d-9e82-8a7c4d6e5f01 (write / write-no-rsp)
 *   Status:  7f510003-1b15-4f0d-9e82-8a7c4d6e5f01 (read / notify)
 *
 * BLE_UUID128_INIT takes the bytes in little-endian wire order.
 */
static const ble_uuid128_t s_service_uuid = BLE_UUID128_INIT(
    0x01, 0x5f, 0x6e, 0x4d, 0x7c, 0x8a, 0x82, 0x9e,
    0x0d, 0x4f, 0x15, 0x1b, 0x01, 0x00, 0x51, 0x7f);

static const ble_uuid128_t s_command_uuid = BLE_UUID128_INIT(
    0x01, 0x5f, 0x6e, 0x4d, 0x7c, 0x8a, 0x82, 0x9e,
    0x0d, 0x4f, 0x15, 0x1b, 0x02, 0x00, 0x51, 0x7f);

static const ble_uuid128_t s_status_uuid = BLE_UUID128_INIT(
    0x01, 0x5f, 0x6e, 0x4d, 0x7c, 0x8a, 0x82, 0x9e,
    0x0d, 0x4f, 0x15, 0x1b, 0x03, 0x00, 0x51, 0x7f);

static const char *TAG = "bt_test_ble";
static uint8_t s_own_addr_type;
static uint16_t s_status_value_handle;
static uint8_t s_status_value[BT_TEST_STATUS_MAX_LEN] = "ready";
static uint16_t s_status_value_len = sizeof("ready") - 1U;

static void advertise(void);

static void set_status(const uint8_t *value, uint16_t length)
{
    if (length > sizeof(s_status_value)) {
        length = sizeof(s_status_value);
    }

    memcpy(s_status_value, value, length);
    s_status_value_len = length;

    if (s_status_value_handle != 0U) {
        ble_gatts_chr_updated(s_status_value_handle);
    }
}

static int gatt_access(uint16_t conn_handle, uint16_t attr_handle,
                       struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)arg;

    if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR &&
        ble_uuid_cmp(ctxt->chr->uuid, &s_status_uuid.u) == 0) {
        return os_mbuf_append(ctxt->om, s_status_value, s_status_value_len) == 0
                   ? 0
                   : BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR &&
        ble_uuid_cmp(ctxt->chr->uuid, &s_command_uuid.u) == 0) {
        const uint16_t command_len = OS_MBUF_PKTLEN(ctxt->om);
        uint8_t command[BT_TEST_COMMAND_MAX_LEN];
        uint16_t copied_len = 0;

        if (command_len > sizeof(command)) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }

        const int rc = ble_hs_mbuf_to_flat(ctxt->om, command,
                                           sizeof(command), &copied_len);
        if (rc != 0) {
            return BLE_ATT_ERR_UNLIKELY;
        }

        uint8_t response[BT_TEST_STATUS_MAX_LEN] = {'A', 'C', 'K', ':'};
        uint16_t response_len = 4U;
        const uint16_t response_room = sizeof(response) - response_len;
        const uint16_t echo_len = copied_len < response_room
                                      ? copied_len
                                      : response_room;

        memcpy(response + response_len, command, echo_len);
        response_len += echo_len;
        set_status(response, response_len);

        ESP_LOGI(TAG, "Received command (%u bytes); status notification queued",
                 (unsigned)copied_len);
        return 0;
    }

    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def s_gatt_services[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_service_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &s_command_uuid.u,
                .access_cb = gatt_access,
                .flags = BLE_GATT_CHR_F_WRITE |
                         BLE_GATT_CHR_F_WRITE_NO_RSP,
            },
            {
                .uuid = &s_status_uuid.u,
                .access_cb = gatt_access,
                .flags = BLE_GATT_CHR_F_READ |
                         BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &s_status_value_handle,
            },
            {0},
        },
    },
    {0},
};

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;

    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            struct ble_gap_conn_desc desc;
            if (ble_gap_conn_find(event->connect.conn_handle, &desc) == 0) {
                ESP_LOGI(TAG,
                         "Phone connected: handle=%u interval=%.2f ms latency=%u",
                         (unsigned)event->connect.conn_handle,
                         desc.conn_itvl * 1.25f,
                         (unsigned)desc.conn_latency);
            } else {
                ESP_LOGI(TAG, "Phone connected: handle=%u",
                         (unsigned)event->connect.conn_handle);
            }
            set_status((const uint8_t *)"connected", sizeof("connected") - 1U);
        } else {
            ESP_LOGW(TAG, "Connection failed: status=%d", event->connect.status);
            advertise();
        }
        return 0;

    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "Phone disconnected: reason=%d",
                 event->disconnect.reason);
        set_status((const uint8_t *)"ready", sizeof("ready") - 1U);
        advertise();
        return 0;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        ESP_LOGI(TAG, "Advertising stopped: reason=%d; restarting",
                 event->adv_complete.reason);
        advertise();
        return 0;

    case BLE_GAP_EVENT_SUBSCRIBE:
        ESP_LOGI(TAG, "Status notifications %s",
                 event->subscribe.cur_notify ? "enabled" : "disabled");
        return 0;

    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "MTU updated: %u", (unsigned)event->mtu.value);
        return 0;

    default:
        return 0;
    }
}

static void advertise(void)
{
    struct ble_hs_adv_fields adv_fields = {0};
    struct ble_hs_adv_fields scan_response = {0};
    struct ble_gap_adv_params params = {0};

    adv_fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    adv_fields.uuids128 = (ble_uuid128_t *)&s_service_uuid;
    adv_fields.num_uuids128 = 1;
    adv_fields.uuids128_is_complete = 1;

    int rc = ble_gap_adv_set_fields(&adv_fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "Could not set advertising fields: rc=%d", rc);
        return;
    }

    const char *device_name = ble_svc_gap_device_name();
    scan_response.name = (uint8_t *)device_name;
    scan_response.name_len = strlen(device_name);
    scan_response.name_is_complete = 1;

    rc = ble_gap_adv_rsp_set_fields(&scan_response);
    if (rc != 0) {
        ESP_LOGE(TAG, "Could not set scan response: rc=%d", rc);
        return;
    }

    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    params.itvl_min = 0x00a0; /* 100 ms */
    params.itvl_max = 0x00f0; /* 150 ms */

    rc = ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER,
                           &params, gap_event, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "Could not start advertising: rc=%d", rc);
        return;
    }

    ESP_LOGI(TAG, "Advertising as '%s'", BT_TEST_DEVICE_NAME);
}

static void on_reset(int reason)
{
    ESP_LOGE(TAG, "NimBLE host reset: reason=%d", reason);
}

static void on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    if (rc != 0) {
        ESP_LOGE(TAG, "No BLE identity address: rc=%d", rc);
        return;
    }

    rc = ble_hs_id_infer_auto(0, &s_own_addr_type);
    if (rc != 0) {
        ESP_LOGE(TAG, "Could not determine BLE address type: rc=%d", rc);
        return;
    }

    uint8_t address[6];
    rc = ble_hs_id_copy_addr(s_own_addr_type, address, NULL);
    if (rc == 0) {
        ESP_LOGI(TAG, "BLE address %02X:%02X:%02X:%02X:%02X:%02X",
                 address[5], address[4], address[3],
                 address[2], address[1], address[0]);
    }

    advertise();
}

static void host_task(void *param)
{
    (void)param;
    ESP_LOGI(TAG, "NimBLE host task started");
    nimble_port_run();
    nimble_port_freertos_deinit();
}

esp_err_t bt_test_ble_start(void)
{
    esp_err_t err = nimble_port_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "NimBLE initialization failed: %s", esp_err_to_name(err));
        return err;
    }

    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.sync_cb = on_sync;

    ble_svc_gap_init();
    ble_svc_gatt_init();

    int rc = ble_gatts_count_cfg(s_gatt_services);
    if (rc == 0) {
        rc = ble_gatts_add_svcs(s_gatt_services);
    }
    if (rc != 0) {
        ESP_LOGE(TAG, "GATT service initialization failed: rc=%d", rc);
        return ESP_FAIL;
    }

    rc = ble_svc_gap_device_name_set(BT_TEST_DEVICE_NAME);
    if (rc != 0) {
        ESP_LOGE(TAG, "Could not set device name: rc=%d", rc);
        return ESP_FAIL;
    }

    nimble_port_freertos_init(host_task);
    return ESP_OK;
}
