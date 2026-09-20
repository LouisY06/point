#include "point_ble.h"

#include <stdint.h>
#include <string.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "protocol.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "os/os_mbuf.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#define BT_TEST_DEVICE_NAME "Point S3"
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

static const char *TAG = "point_ble";
static uint8_t s_own_addr_type;
static uint16_t s_status_value_handle;
static uint8_t s_status_value[BT_TEST_STATUS_MAX_LEN] = "ready";
static uint16_t s_status_value_len = sizeof("ready") - 1U;

static void advertise(void);

static portMUX_TYPE link_lock = portMUX_INITIALIZER_UNLOCKED;
static uint32_t link_epoch;
static bool link_connected, link_subscribed;
static uint16_t link_handle;
static int64_t stop_time;
static QueueHandle_t request_queue;

static void link_changed(bool connected, uint16_t handle) {
    portENTER_CRITICAL(&link_lock);
    link_epoch++;
    link_connected = connected;
    link_subscribed = false;
    link_handle = handle;
    stop_time = esp_timer_get_time();
    portEXIT_CRITICAL(&link_lock);
}

bool point_ble_active(uint32_t epoch) {
    portENTER_CRITICAL(&link_lock);
    bool active = link_connected && link_subscribed && link_epoch == epoch;
    portEXIT_CRITICAL(&link_lock);
    return active;
}

int64_t point_ble_stop_time(void) {
    portENTER_CRITICAL(&link_lock);
    int64_t time = stop_time;
    portEXIT_CRITICAL(&link_lock);
    return time;
}

void point_ble_reply(const point_request_t *request, const uint8_t *data, size_t length) {
    if (length > sizeof(s_status_value)) return;
    portENTER_CRITICAL(&link_lock);
    bool active = link_connected && link_subscribed && link_epoch == request->epoch;
    uint16_t handle = link_handle;
    if (active) { memcpy(s_status_value, data, length); s_status_value_len = length; }
    portEXIT_CRITICAL(&link_lock);
    if (!active) return;
    struct os_mbuf *buffer = ble_hs_mbuf_from_flat(data, length);
    if (buffer) {
        int rc = ble_gatts_notify_custom(handle, s_status_value_handle, buffer);
        if (rc) ESP_LOGW(TAG, "Notify failed: %d", rc);
    }
}

static int gatt_access(uint16_t conn_handle, uint16_t attr_handle,
                       struct ble_gatt_access_ctxt *ctxt, void *arg) {
    (void)conn_handle; (void)attr_handle; (void)arg;
    if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR && ble_uuid_cmp(ctxt->chr->uuid, &s_status_uuid.u) == 0) {
        uint8_t data[20]; uint16_t length;
        portENTER_CRITICAL(&link_lock);
        length = s_status_value_len; memcpy(data, s_status_value, length);
        portEXIT_CRITICAL(&link_lock);
        return os_mbuf_append(ctxt->om, data, length) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR || ble_uuid_cmp(ctxt->chr->uuid, &s_command_uuid.u) != 0)
        return BLE_ATT_ERR_UNLIKELY;
    point_request_t request = { .received_us = esp_timer_get_time() };
    uint16_t length = OS_MBUF_PKTLEN(ctxt->om), copied = 0;
    if (length > 16) return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    if (ble_hs_mbuf_to_flat(ctxt->om, request.data, 16, &copied)) return BLE_ATT_ERR_UNLIKELY;
    request.length = copied;
    point_command_t c;
    bool binary = copied && request.data[0] == 0xA7;
    if (binary && !point_decode(request.data, copied, &c)) return BLE_ATT_ERR_UNLIKELY;
    portENTER_CRITICAL(&link_lock);
    request.epoch = link_epoch;
    bool active = link_connected && link_subscribed;
    if (active && binary && c.op == POINT_HAPTIC && c.kind == 0) stop_time = request.received_us;
    portEXIT_CRITICAL(&link_lock);
    if (!active) return BLE_ATT_ERR_UNLIKELY;
    return xQueueSend(request_queue, &request, 0) == pdTRUE ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
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
            link_changed(true, event->connect.conn_handle);
        } else {
            ESP_LOGW(TAG, "Connection failed: status=%d", event->connect.status);
            advertise();
        }
        return 0;

    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "Phone disconnected: reason=%d",
                 event->disconnect.reason);
        link_changed(false, 0);
        advertise();
        return 0;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        ESP_LOGI(TAG, "Advertising stopped: reason=%d; restarting",
                 event->adv_complete.reason);
        advertise();
        return 0;

    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle == s_status_value_handle) {
            portENTER_CRITICAL(&link_lock);
            link_subscribed = event->subscribe.cur_notify;
            if (!link_subscribed) { link_epoch++; stop_time = esp_timer_get_time(); }
            portEXIT_CRITICAL(&link_lock);
        }
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
    link_changed(false, 0);
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

esp_err_t point_ble_start(QueueHandle_t requests)
{
    request_queue = requests;
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
