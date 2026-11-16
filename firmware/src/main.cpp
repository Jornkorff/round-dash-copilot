#include <Arduino.h>
#include <lvgl.h>
#include <NimBLEDevice.h>
#include "nimble/nimble/host/include/host/ble_hs.h"
#include "nimble/nimble/host/include/host/ble_gatt.h"
#include "nimble/nimble/host/include/host/ble_hs_mbuf.h"
#include "nimble/nimble/host/src/ble_hs_conn_priv.h"
#include <math.h>
#include <vector>
#include <string>
#include <algorithm>
#include "board_config.h"
#include "protocol.h"
#include "icons.h"

// Prevent Arduino Core 3.x from releasing BLE controller memory at boot
extern "C" bool bleInUse(void) {
    return true;
}

static LGFX tft;

// LVGL partial draw buffer (SCREEN_WIDTH x 20 px, safe without PSRAM)
static lv_disp_draw_buf_t draw_buf;
static lv_color_t buf1[SCREEN_WIDTH * 20];

// UI Objects
static lv_obj_t* circle_viewport = nullptr;
static lv_obj_t* poi_markers[MAX_POIS];
static lv_obj_t* poi_icons[MAX_POIS];
static lv_obj_t* car_shadow = nullptr;
static lv_obj_t* car_icon = nullptr;
static lv_point_t car_points[5];
static lv_obj_t* alert_badge = nullptr;
static lv_obj_t* alert_badge_icon = nullptr;

#if ENABLE_DEBUG_STRIP
static lv_obj_t* debug_label = nullptr;
#endif

// Shared State
static volatile bool ble_connected = false;
static volatile bool frame_dirty = false;
static volatile bool coords_in_decimeters = false;
static uint32_t rx_packets = 0;

static uint16_t current_scale_cm_px = 120;
static uint8_t incoming_alert = ALERT_NONE;
static uint8_t dismissed_alert = ALERT_NONE;
static uint8_t active_road_count = 0;
static uint8_t active_poi_count = 0;
static RoadSegment roads[MAX_ROAD_SEGMENTS];
static PoiItem pois[MAX_POIS];

// Staging buffer for multi-chunk BLE map frames (msg_type 0x02)
static uint8_t staging_road_count = 0;
static uint8_t staging_poi_count = 0;
static RoadSegment staging_roads[MAX_ROAD_SEGMENTS];
static PoiItem staging_pois[MAX_POIS];

// Car anchor inside 240x240 circle (offset down for forward look-ahead)
static constexpr int CAR_CENTER_X = 120;
static constexpr int CAR_CENTER_Y = 145;

// --- Apple ANCS (Apple Notification Center Service) Client State ---
static const NimBLEUUID ancs_svc_uuid("7905F431-B5CE-4E99-A40F-4B1E122D00D0");
static const NimBLEUUID ancs_notif_src_uuid("9FBF120D-6301-42D9-8C58-25E699A21DBD");
static const NimBLEUUID ancs_ctrl_pt_uuid("69D1D8F3-45E1-49A8-9821-9BBDFDA47993");
static const NimBLEUUID ancs_data_src_uuid("22EAC6E9-24D6-4BB5-BE44-44488A732C2B");

static uint16_t ancs_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint16_t ancs_notif_src_val_handle = 0;
static uint16_t ancs_ctrl_pt_val_handle = 0;
static uint16_t ancs_data_src_val_handle = 0;
static uint32_t active_ancs_uid = 0;
static ble_gap_event_fn *orig_gap_cb = nullptr;
static void *orig_gap_arg = nullptr;

static std::vector<uint8_t> data_src_buf;
static struct ble_gatt_svc ancs_cached_svc;

// Display Flush Callback
static void my_disp_flush(lv_disp_drv_t* disp, const lv_area_t* area, lv_color_t* color_p) {
    uint32_t w = (area->x2 - area->x1 + 1);
    uint32_t h = (area->y2 - area->y1 + 1);
    tft.startWrite();
    tft.setAddrWindow(area->x1, area->y1, w, h);
    tft.writePixels((lgfx::swap565_t*)&color_p->full, w * h);
    tft.endWrite();
    lv_disp_flush_ready(disp);
}

// Touch Read Callback
static void my_touchpad_read(lv_indev_drv_t* indev_driver, lv_indev_data_t* data) {
    uint16_t touchX, touchY;
    bool touched = tft.getTouch(&touchX, &touchY);
    if (!touched) {
        data->state = LV_INDEV_STATE_REL;
    } else {
        data->state = LV_INDEV_STATE_PR;
        data->point.x = touchX;
        data->point.y = touchY;
    }
}

// Full-Screen Tap Dismisses Active Alert Badge
static void on_viewport_tapped(lv_event_t* e) {
    if (incoming_alert != ALERT_NONE) {
        dismissed_alert = incoming_alert;
        lv_obj_add_flag(alert_badge, LV_OBJ_FLAG_HIDDEN);
    }
}

// Flitsmeister ANCS Keyword Classifier
static void classify_flitsmeister_alert(uint32_t notif_uid,
                                        const std::string& app_id,
                                        const std::string& title,
                                        const std::string& subtitle,
                                        const std::string& message) {
    std::string lower_app = app_id;
    std::transform(lower_app.begin(), lower_app.end(), lower_app.begin(), ::tolower);

    // Accept notifications originating from Flitsmeister
    if (lower_app.find("flitsmeister") == std::string::npos) {
        return;
    }

    std::string text = title + " " + subtitle + " " + message;
    std::transform(text.begin(), text.end(), text.begin(), ::tolower);

    AlertTier tier = ALERT_NONE;

    // P1 (Highest): Fixed/mobile speed traps, red-light cameras, laser, trajectcontroles
    if (text.find("flitser") != std::string::npos ||
        text.find("flitspaal") != std::string::npos ||
        text.find("mobiele") != std::string::npos ||
        text.find("laser") != std::string::npos ||
        text.find("controle") != std::string::npos ||
        text.find("trajectcontrole") != std::string::npos ||
        text.find("speed camera") != std::string::npos ||
        text.find("radar") != std::string::npos) {
        tier = ALERT_SPEED_CAM;
    }
    // P2 (High): Emergency vehicles (ambulances, priority vehicles)
    else if (text.find("ambulance") != std::string::npos ||
             text.find("hulpdienst") != std::string::npos ||
             text.find("voorrangsvoertuig") != std::string::npos ||
             text.find("emergency") != std::string::npos) {
        tier = ALERT_EMERGENCY;
    }
    // P3 (Medium): Accidents, stationary vehicles, closures, roadworks
    else if (text.find("ongeval") != std::string::npos ||
             text.find("ongeluk") != std::string::npos ||
             text.find("stilstaand") != std::string::npos ||
             text.find("afgesloten") != std::string::npos ||
             text.find("wegwerkzaamheden") != std::string::npos ||
             text.find("file") != std::string::npos ||
             text.find("accident") != std::string::npos ||
             text.find("closure") != std::string::npos) {
        tier = ALERT_HAZARD;
    }

    if (tier != ALERT_NONE) {
        Serial.printf("[ANCS] Flitsmeister alert matched: Tier %u (UID: %lu)\n",
                      static_cast<unsigned>(tier), static_cast<unsigned long>(notif_uid));
        incoming_alert = tier;
        dismissed_alert = ALERT_NONE;
        active_ancs_uid = notif_uid;
        frame_dirty = true;
    }
}

// Data Source Stream Parser
static void process_data_source_stream(const uint8_t* data, size_t len) {
    data_src_buf.insert(data_src_buf.end(), data, data + len);

    if (data_src_buf.size() < 5) return;
    if (data_src_buf[0] != 0x00) { // CommandID 0x00 = GetNotificationAttributes
        data_src_buf.clear();
        return;
    }

    uint32_t uid = 0;
    memcpy(&uid, &data_src_buf[1], 4);

    size_t offset = 5;
    std::string app_id;
    std::string title;
    std::string subtitle;
    std::string message;

    while (offset + 3 <= data_src_buf.size()) {
        uint8_t attr_id = data_src_buf[offset];
        uint16_t attr_len = data_src_buf[offset + 1] | (static_cast<uint16_t>(data_src_buf[offset + 2]) << 8);

        if (offset + 3 + attr_len > data_src_buf.size()) {
            return; // Wait for remainder of notification packet
        }

        std::string val(reinterpret_cast<const char*>(&data_src_buf[offset + 3]), attr_len);
        offset += 3 + attr_len;

        if (attr_id == 0) app_id = val;
        else if (attr_id == 1) title = val;
        else if (attr_id == 2) subtitle = val;
        else if (attr_id == 3) message = val;
    }

    data_src_buf.clear();
    classify_flitsmeister_alert(uid, app_id, title, subtitle, message);
}

// Notification Source Handler
static void handle_ancs_notif_source(const uint8_t* data, size_t len) {
    if (len < 8) return;
    uint8_t event_id = data[0];
    uint32_t uid = 0;
    memcpy(&uid, &data[4], 4);

    if (event_id == 2) { // EventIDNotificationRemoved
        if (uid == active_ancs_uid) {
            Serial.printf("[ANCS] Notification removed (UID: %lu)\n", static_cast<unsigned long>(uid));
            incoming_alert = ALERT_NONE;
            dismissed_alert = ALERT_NONE;
            active_ancs_uid = 0;
            frame_dirty = true;
        }
    } else if (event_id == 0 || event_id == 1) { // Added or Modified
        if (ancs_conn_handle != BLE_HS_CONN_HANDLE_NONE && ancs_ctrl_pt_val_handle != 0) {
            uint8_t cmd[19];
            cmd[0] = 0x00; // CommandIDGetNotificationAttributes
            memcpy(&cmd[1], &uid, 4);
            size_t idx = 5;
            cmd[idx++] = 0x00; // AppIdentifier
            cmd[idx++] = 0x01; cmd[idx++] = 64; cmd[idx++] = 0;  // Title (max 64)
            cmd[idx++] = 0x02; cmd[idx++] = 64; cmd[idx++] = 0;  // Subtitle (max 64)
            cmd[idx++] = 0x03; cmd[idx++] = 128; cmd[idx++] = 0; // Message (max 128)

            data_src_buf.clear();
            ble_gattc_write_flat(ancs_conn_handle, ancs_ctrl_pt_val_handle, cmd, idx, nullptr, nullptr);
        }
    }
}

// ANCS CCCD Subscription Discovery Callback
static int on_ancs_dsc_disc(uint16_t conn_handle, const struct ble_gatt_error *error,
                            uint16_t chr_val_handle, const struct ble_gatt_dsc *dsc, void *arg) {
    if (error->status == 0 && dsc != nullptr) {
        if (dsc->uuid.u.type == BLE_UUID_TYPE_16 && dsc->uuid.u16.value == 0x2902) {
            uint16_t sub_val = 0x0001;
            ble_gattc_write_flat(conn_handle, dsc->handle, &sub_val, sizeof(sub_val), nullptr, nullptr);
            Serial.printf("[ANCS] Subscribed to CCCD handle: %u\n", dsc->handle);
        }
    }
    return 0;
}

// ANCS Characteristic Discovery Callback
static int on_ancs_chr_disc(uint16_t conn_handle, const struct ble_gatt_error *error,
                            const struct ble_gatt_chr *chr, void *arg) {
    if (error->status == 0 && chr != nullptr) {
        if (ble_uuid_cmp(&chr->uuid.u, &ancs_notif_src_uuid.getNative()->u) == 0) {
            ancs_notif_src_val_handle = chr->val_handle;
            Serial.printf("[ANCS] Found Notification Source handle: %u\n", chr->val_handle);
        } else if (ble_uuid_cmp(&chr->uuid.u, &ancs_ctrl_pt_uuid.getNative()->u) == 0) {
            ancs_ctrl_pt_val_handle = chr->val_handle;
            Serial.printf("[ANCS] Found Control Point handle: %u\n", chr->val_handle);
        } else if (ble_uuid_cmp(&chr->uuid.u, &ancs_data_src_uuid.getNative()->u) == 0) {
            ancs_data_src_val_handle = chr->val_handle;
            Serial.printf("[ANCS] Found Data Source handle: %u\n", chr->val_handle);
        }
    } else if (error->status == BLE_HS_EDONE) {
        const struct ble_gatt_svc* svc = reinterpret_cast<const struct ble_gatt_svc*>(arg);
        if (svc) {
            ble_gattc_disc_all_dscs(conn_handle, svc->start_handle, svc->end_handle, on_ancs_dsc_disc, nullptr);
        }
    }
    return 0;
}

// ANCS Service Discovery Callback
static int on_ancs_svc_disc(uint16_t conn_handle, const struct ble_gatt_error *error,
                            const struct ble_gatt_svc *service, void *arg) {
    if (error->status == 0 && service != nullptr) {
        Serial.printf("[ANCS] Found ANCS service (handles %u..%u)\n", service->start_handle, service->end_handle);
        ancs_cached_svc = *service;
        ble_gattc_disc_all_chrs(conn_handle, service->start_handle, service->end_handle, on_ancs_chr_disc, &ancs_cached_svc);
    }
    return 0;
}

// Intercepts Incoming GATT Notifications for ANCS
static int custom_gap_event(struct ble_gap_event *event, void *arg) {
    if (event->type == BLE_GAP_EVENT_NOTIFY_RX) {
        uint16_t attr_handle = event->notify_rx.attr_handle;
        uint32_t len = OS_MBUF_PKTLEN(event->notify_rx.om);
        uint8_t stack_buf[256];
        uint16_t flat_len = 0;
        uint16_t read_len = min<uint32_t>(len, sizeof(stack_buf));
        ble_hs_mbuf_to_flat(event->notify_rx.om, stack_buf, read_len, &flat_len);

        if (attr_handle == ancs_notif_src_val_handle) {
            handle_ancs_notif_source(stack_buf, flat_len);
            return 0;
        } else if (attr_handle == ancs_data_src_val_handle) {
            process_data_source_stream(stack_buf, flat_len);
            return 0;
        }
    }

    if (orig_gap_cb) {
        return orig_gap_cb(event, orig_gap_arg);
    }
    return 0;
}

// BLE GATT Frame Receiver (Supports 0x01 Single-Frame and 0x02 Multi-Chunk 160-Road Frame)
class MapFrameCallbacks : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* pCharacteristic) override {
        std::string val = pCharacteristic->getValue();
        if (val.empty()) return;

        const uint8_t* ptr = reinterpret_cast<const uint8_t*>(val.data());
        uint8_t msg_type = ptr[0];

        if (msg_type == 0x01) {
            if (val.size() < sizeof(FrameHeader)) return;
            FrameHeader hdr;
            memcpy(&hdr, ptr, sizeof(FrameHeader));

            uint8_t r_cnt = min<uint8_t>(hdr.road_count, MAX_ROAD_SEGMENTS);
            uint8_t p_cnt = min<uint8_t>(hdr.poi_count, MAX_POIS);
            size_t expected_len = sizeof(FrameHeader) + r_cnt * sizeof(RoadSegment) + p_cnt * sizeof(PoiItem);
            if (val.size() < expected_len) return;

            current_scale_cm_px = max<uint16_t>(hdr.scale_cm_per_px, 20);
            if (hdr.active_alert_type != incoming_alert) {
                incoming_alert = hdr.active_alert_type;
                if (incoming_alert == ALERT_NONE) {
                    dismissed_alert = ALERT_NONE;
                }
            }

            const uint8_t* body = ptr + sizeof(FrameHeader);
            if (r_cnt > 0) {
                memcpy(roads, body, r_cnt * sizeof(RoadSegment));
                body += r_cnt * sizeof(RoadSegment);
            }
            if (p_cnt > 0) {
                memcpy(pois, body, p_cnt * sizeof(PoiItem));
            }

            active_road_count = r_cnt;
            active_poi_count = p_cnt;
            coords_in_decimeters = false;
            rx_packets = rx_packets + 1;
            frame_dirty = true;
        } else if (msg_type == 0x02) {
            if (val.size() < sizeof(ChunkedFrameHeader)) return;
            ChunkedFrameHeader hdr;
            memcpy(&hdr, ptr, sizeof(ChunkedFrameHeader));

            uint8_t r_cnt = hdr.road_count;
            uint8_t p_cnt = min<uint8_t>(hdr.poi_count, MAX_POIS);
            size_t expected_len = sizeof(ChunkedFrameHeader) + r_cnt * sizeof(RoadSegment) + p_cnt * sizeof(PoiItem);
            if (val.size() < expected_len) return;

            if (hdr.chunk_idx == 0) {
                staging_road_count = 0;
                staging_poi_count = 0;
            }

            const uint8_t* body = ptr + sizeof(ChunkedFrameHeader);
            uint8_t space_left = (staging_road_count < MAX_ROAD_SEGMENTS) ? (MAX_ROAD_SEGMENTS - staging_road_count) : 0;
            uint8_t to_copy = min<uint8_t>(r_cnt, space_left);
            if (to_copy > 0) {
                memcpy(&staging_roads[staging_road_count], body, to_copy * sizeof(RoadSegment));
                staging_road_count += to_copy;
            }
            body += r_cnt * sizeof(RoadSegment);

            if (p_cnt > 0) {
                memcpy(staging_pois, body, p_cnt * sizeof(PoiItem));
                staging_poi_count = p_cnt;
            }

            rx_packets = rx_packets + 1;

            if (hdr.chunk_idx + 1 >= hdr.total_chunks) {
                current_scale_cm_px = max<uint16_t>(hdr.scale_cm_per_px, 20);
                if (hdr.active_alert_type != incoming_alert) {
                    incoming_alert = hdr.active_alert_type;
                    if (incoming_alert == ALERT_NONE) {
                        dismissed_alert = ALERT_NONE;
                    }
                }
                memcpy(roads, staging_roads, staging_road_count * sizeof(RoadSegment));
                active_road_count = staging_road_count;
                if (staging_poi_count > 0 || hdr.chunk_idx == 0) {
                    memcpy(pois, staging_pois, staging_poi_count * sizeof(PoiItem));
                    active_poi_count = staging_poi_count;
                }
                coords_in_decimeters = true;
                frame_dirty = true;
            }
        }
    }
};

class ServerCallbacks : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer* pServer) override {
        ble_connected = true;
    }

    void onConnect(NimBLEServer* pServer, ble_gap_conn_desc* desc) override {
        ble_connected = true;
        ancs_conn_handle = desc->conn_handle;
        Serial.printf("[BLE] iPhone connected, handle=%u\n", desc->conn_handle);

        struct ble_hs_conn* conn = ble_hs_conn_find(desc->conn_handle);
        if (conn) {
            orig_gap_cb = conn->bhc_cb;
            orig_gap_arg = conn->bhc_cb_arg;
            ble_gap_set_event_cb(desc->conn_handle, custom_gap_event, nullptr);
        }

        // Initiate ANCS Service discovery on connected iOS central
        ble_gattc_disc_svc_by_uuid(desc->conn_handle, &ancs_svc_uuid.getNative()->u, on_ancs_svc_disc, nullptr);
    }

    void onDisconnect(NimBLEServer* pServer) override {
        ble_connected = false;
        ancs_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        ancs_notif_src_val_handle = 0;
        ancs_ctrl_pt_val_handle = 0;
        ancs_data_src_val_handle = 0;
        active_ancs_uid = 0;
        data_src_buf.clear();
        NimBLEDevice::startAdvertising();
    }
};

static uint16_t render_scale_cm_px = 90;
static int16_t legacy_offset_x = 0;
static int16_t legacy_offset_y = 0;

static inline lv_coord_t coord_to_px_x(int16_t val) {
    int32_t cm = coords_in_decimeters
        ? (static_cast<int32_t>(val) * 10)
        : (static_cast<int32_t>(val - legacy_offset_x) * 100);
    return static_cast<lv_coord_t>(CAR_CENTER_X + (cm / render_scale_cm_px));
}

static inline lv_coord_t coord_to_px_y(int16_t val) {
    int32_t cm = coords_in_decimeters
        ? (static_cast<int32_t>(val) * 10)
        : (static_cast<int32_t>(val - legacy_offset_y) * 100);
    return static_cast<lv_coord_t>(CAR_CENTER_Y - (cm / render_scale_cm_px));
}

// Custom 3-Pass Automotive / Game Minimap Road Renderer (Casing + Paved Surface + Active Route)
static void on_viewport_draw(lv_event_t* e) {
    lv_obj_t* obj = lv_event_get_target(e);
    lv_draw_ctx_t* draw_ctx = lv_event_get_draw_ctx(e);
    if (!draw_ctx || active_road_count == 0) return;

    lv_area_t vp;
    lv_obj_get_coords(obj, &vp);

    // Find closest road to (0,0) if none explicitly flagged as current
    int closest_idx = -1;
    int64_t best_dsq = 0x7FFFFFFFFFFFFFFFLL;
    bool has_explicit_current = false;
    for (uint8_t i = 0; i < active_road_count; i++) {
        if (roads[i].flags & ROAD_FLAG_CURRENT) has_explicit_current = true;
        int64_t mx = (static_cast<int64_t>(roads[i].x1) + roads[i].x2) / 2;
        int64_t my = (static_cast<int64_t>(roads[i].y1) + roads[i].y2) / 2;
        int64_t dsq = mx * mx + my * my;
        if (dsq < best_dsq) {
            best_dsq = dsq;
            closest_idx = i;
        }
    }

    lv_draw_line_dsc_t line_dsc;
    lv_draw_line_dsc_init(&line_dsc);
    line_dsc.round_start = 1;
    line_dsc.round_end = 1;
    line_dsc.opa = LV_OPA_COVER;

    // Pass 1: Pure Black Road Casing / Outline (gives every street razor-sharp borders & merges intersections)
    line_dsc.color = lv_color_hex(0x000000);
    for (uint8_t i = 0; i < active_road_count; i++) {
        lv_point_t p1 = {
            static_cast<lv_coord_t>(vp.x1 + coord_to_px_x(roads[i].x1)),
            static_cast<lv_coord_t>(vp.y1 + coord_to_px_y(roads[i].y1))
        };
        lv_point_t p2 = {
            static_cast<lv_coord_t>(vp.x1 + coord_to_px_x(roads[i].x2)),
            static_cast<lv_coord_t>(vp.y1 + coord_to_px_y(roads[i].y2))
        };
        if (max(p1.x, p2.x) < vp.x1 - 12 || min(p1.x, p2.x) > vp.x2 + 12 ||
            max(p1.y, p2.y) < vp.y1 - 12 || min(p1.y, p2.y) > vp.y2 + 12) continue;

        bool is_major = (roads[i].flags & ROAD_FLAG_MAJOR) != 0;
        bool is_cur = (roads[i].flags & ROAD_FLAG_CURRENT) || (!has_explicit_current && i == closest_idx);
        line_dsc.width = (is_major || is_cur) ? 10 : 8;
        lv_draw_line(draw_ctx, &line_dsc, &p1, &p2);
    }

    // Pass 2: High-Contrast Paved Street Surface (Residential & Major Roads)
    for (uint8_t i = 0; i < active_road_count; i++) {
        bool is_cur = (roads[i].flags & ROAD_FLAG_CURRENT) || (!has_explicit_current && i == closest_idx);
        bool is_closed = (roads[i].flags & ROAD_FLAG_CLOSED) != 0;
        if (is_cur || is_closed) continue;

        lv_point_t p1 = {
            static_cast<lv_coord_t>(vp.x1 + coord_to_px_x(roads[i].x1)),
            static_cast<lv_coord_t>(vp.y1 + coord_to_px_y(roads[i].y1))
        };
        lv_point_t p2 = {
            static_cast<lv_coord_t>(vp.x1 + coord_to_px_x(roads[i].x2)),
            static_cast<lv_coord_t>(vp.y1 + coord_to_px_y(roads[i].y2))
        };
        if (max(p1.x, p2.x) < vp.x1 - 12 || min(p1.x, p2.x) > vp.x2 + 12 ||
            max(p1.y, p2.y) < vp.y1 - 12 || min(p1.y, p2.y) > vp.y2 + 12) continue;

        if (roads[i].flags & ROAD_FLAG_MAJOR) {
            line_dsc.color = lv_color_hex(0xE2E8F0); // Bright Alabaster Arterial Road
            line_dsc.width = 7;
        } else {
            line_dsc.color = lv_color_hex(0x94A3B8); // Crisp Silver-Slate Residential Street
            line_dsc.width = 5;
        }
        lv_draw_line(draw_ctx, &line_dsc, &p1, &p2);
    }

    // Pass 3: Active Current Road (Electric Cyan) & Closed Roads (Crimson) on top
    for (uint8_t i = 0; i < active_road_count; i++) {
        bool is_cur = (roads[i].flags & ROAD_FLAG_CURRENT) || (!has_explicit_current && i == closest_idx);
        bool is_closed = (roads[i].flags & ROAD_FLAG_CLOSED) != 0;
        if (!is_cur && !is_closed) continue;

        lv_point_t p1 = {
            static_cast<lv_coord_t>(vp.x1 + coord_to_px_x(roads[i].x1)),
            static_cast<lv_coord_t>(vp.y1 + coord_to_px_y(roads[i].y1))
        };
        lv_point_t p2 = {
            static_cast<lv_coord_t>(vp.x1 + coord_to_px_x(roads[i].x2)),
            static_cast<lv_coord_t>(vp.y1 + coord_to_px_y(roads[i].y2))
        };
        if (max(p1.x, p2.x) < vp.x1 - 12 || min(p1.x, p2.x) > vp.x2 + 12 ||
            max(p1.y, p2.y) < vp.y1 - 12 || min(p1.y, p2.y) > vp.y2 + 12) continue;

        if (is_closed) {
            line_dsc.color = lv_color_hex(0xEF4444); // Crimson Closure
            line_dsc.width = 6;
        } else {
            line_dsc.color = lv_color_hex(0x38BDF8); // Electric Sky / Cyan Active Street
            line_dsc.width = 7;
        }
        lv_draw_line(draw_ctx, &line_dsc, &p1, &p2);
    }
}

static void render_map_frame() {
    render_scale_cm_px = current_scale_cm_px;

    // Legacy 0x01 fallback: if running old un-sorted IPA where closest road is >60m away, center on closest road
    if (!coords_in_decimeters && active_road_count > 0) {
        int closest_idx = 0;
        int32_t best_dsq = 0x7FFFFFFF;
        for (uint8_t i = 0; i < active_road_count; i++) {
            int32_t mx = (roads[i].x1 + roads[i].x2) / 2;
            int32_t my = (roads[i].y1 + roads[i].y2) / 2;
            int32_t dsq = mx * mx + my * my;
            if (dsq < best_dsq) {
                best_dsq = dsq;
                closest_idx = i;
            }
        }
        if (best_dsq > 60 * 60) {
            legacy_offset_x = (roads[closest_idx].x1 + roads[closest_idx].x2) / 2;
            legacy_offset_y = (roads[closest_idx].y1 + roads[closest_idx].y2) / 2;
        } else {
            legacy_offset_x = 0;
            legacy_offset_y = 0;
        }
    } else {
        legacy_offset_x = 0;
        legacy_offset_y = 0;
    }

    // 1. Trigger custom 3-pass road redraw on circular viewport
    lv_obj_invalidate(circle_viewport);

    // 2. Update POI Icons
    for (uint8_t i = 0; i < MAX_POIS; i++) {
        if (i < active_poi_count) {
            lv_coord_t px = coord_to_px_x(pois[i].x) - 9;
            lv_coord_t py = coord_to_px_y(pois[i].y) - 9;
            lv_obj_set_pos(poi_markers[i], px, py);

            const lv_img_dsc_t* icon_src = &icon_fuel_pump;
            uint32_t bg_hex = 0x06B6D4;

            switch (pois[i].poi_type) {
                case POI_FIXED_CAM:
                case POI_MOBILE_TRAP:
                case POI_TRAJECTCONTROLE:
                    bg_hex = 0xF43F5E; // Rose Crimson
                    icon_src = &icon_camera;
                    break;
                case POI_CLOSURE_HAZARD:
                    bg_hex = 0xF59E0B; // Vibrant Amber
                    icon_src = &icon_hazard;
                    break;
                case POI_GAS_STATION:
                    bg_hex = 0x06B6D4; // Electric Teal
                    icon_src = &icon_fuel_pump;
                    break;
                case POI_GARAGE:
                    bg_hex = 0x64748B; // Modern Slate
                    icon_src = &icon_wrench;
                    break;
                case POI_EV_CHARGER:
                    bg_hex = 0x10B981; // Vivid Emerald
                    icon_src = &icon_ev_charger;
                    break;
                case POI_PARKING:
                    bg_hex = 0x3B82F6; // Electric Cobalt
                    icon_src = &icon_parking;
                    break;
                default:
                    bg_hex = 0x06B6D4;
                    icon_src = &icon_fuel_pump;
                    break;
            }

            lv_obj_set_style_bg_color(poi_markers[i], lv_color_hex(bg_hex), 0);
            lv_img_set_src(poi_icons[i], icon_src);
            lv_obj_clear_flag(poi_markers[i], LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(poi_markers[i], LV_OBJ_FLAG_HIDDEN);
        }
    }

    // 3. Update Static Top Warning Badge (State change only - prevents flicker/flashing)
    static uint8_t last_rendered_alert = 0xFF;
    static uint8_t last_rendered_dismissed = 0xFF;

    if (incoming_alert != last_rendered_alert || dismissed_alert != last_rendered_dismissed) {
        last_rendered_alert = incoming_alert;
        last_rendered_dismissed = dismissed_alert;

        if (incoming_alert != ALERT_NONE && incoming_alert != dismissed_alert) {
            if (incoming_alert == ALERT_SPEED_CAM) {
                lv_obj_set_style_bg_color(alert_badge, lv_color_hex(0xF43F5E), 0);
                lv_img_set_src(alert_badge_icon, &icon_camera);
            } else if (incoming_alert == ALERT_EMERGENCY) {
                lv_obj_set_style_bg_color(alert_badge, lv_color_hex(0x3B82F6), 0);
                lv_img_set_src(alert_badge_icon, &icon_hazard);
            } else {
                lv_obj_set_style_bg_color(alert_badge, lv_color_hex(0xF59E0B), 0);
                lv_img_set_src(alert_badge_icon, &icon_hazard);
            }
            lv_obj_clear_flag(alert_badge, LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(alert_badge, LV_OBJ_FLAG_HIDDEN);
        }
    }
}

// Bench Demo Simulation when no iPhone is connected (Realistic Neighborhood Street Grid)
static void run_bench_demo() {
    static float sim_t = 0.0f;
    sim_t += 0.035f;
    int16_t scroll_y = static_cast<int16_t>(fmodf(sim_t * 14.0f, 160.0f));
    float sway = sinf(sim_t * 0.35f) * 14.0f;

    current_scale_cm_px = 110;
    coords_in_decimeters = false;
    uint8_t idx = 0;

    // Smoothly curving main avenue (4 segments)
    int16_t x_m1 = static_cast<int16_t>(-sway * 0.3f);
    int16_t x_0  = 0;
    int16_t x_1  = static_cast<int16_t>(sway * 0.4f);
    int16_t x_2  = static_cast<int16_t>(sway * 0.9f);
    int16_t x_3  = static_cast<int16_t>(sway * 1.3f);
    roads[idx++] = {x_m1, -120, x_0, -20, ROAD_FLAG_CURRENT | ROAD_FLAG_MAJOR};
    roads[idx++] = {x_0,  -20,  x_1, 60,  ROAD_FLAG_CURRENT | ROAD_FLAG_MAJOR};
    roads[idx++] = {x_1,   60,  x_2, 140, ROAD_FLAG_CURRENT | ROAD_FLAG_MAJOR};
    roads[idx++] = {x_2,  140,  x_3, 240, ROAD_FLAG_CURRENT | ROAD_FLAG_MAJOR};

    // Realistic grid of cross streets and parallel neighborhood streets scrolling past
    for (int b = -1; b <= 2; b++) {
        int16_t by = static_cast<int16_t>(b * 80 - scroll_y + 60);
        int16_t cx = static_cast<int16_t>((by > 0) ? (sway * by / 180.0f) : 0);
        // Cross street left & right
        roads[idx++] = {-140, static_cast<int16_t>(by - 8), cx, by, (b == 1) ? ROAD_FLAG_MAJOR : static_cast<uint8_t>(0)};
        roads[idx++] = {cx, by, 140, static_cast<int16_t>(by + 8), (b == 1) ? ROAD_FLAG_MAJOR : static_cast<uint8_t>(0)};
        // Parallel residential streets left (-65m) and right (+68m)
        roads[idx++] = {-65, static_cast<int16_t>(by - 80), -65, by, 0};
        roads[idx++] = {68,  static_cast<int16_t>(by - 80), 68,  by, 0};
    }
    // Diagonal side street with roadworks closure
    int16_t cy_close = static_cast<int16_t>(140 - scroll_y);
    roads[idx++] = {68, cy_close, 130, static_cast<int16_t>(cy_close + 45), ROAD_FLAG_CLOSED};

    active_road_count = idx;

    // Rich POI mix anchored to the street grid
    int16_t cam_y = static_cast<int16_t>(140 - scroll_y);
    active_poi_count = 6;
    pois[0] = {x_1, cam_y, POI_FIXED_CAM};
    pois[1] = {-65, static_cast<int16_t>(cam_y - 40), POI_GAS_STATION};
    pois[2] = {68,  static_cast<int16_t>(cam_y + 35), POI_GARAGE};
    pois[3] = {-65, static_cast<int16_t>(cam_y + 40), POI_EV_CHARGER};
    pois[4] = {68,  static_cast<int16_t>(cam_y - 45), POI_PARKING};
    pois[5] = {98,  static_cast<int16_t>(cy_close + 22), POI_CLOSURE_HAZARD};

    if (cam_y > 25 && cam_y < 125) {
        incoming_alert = ALERT_SPEED_CAM;
    } else {
        incoming_alert = ALERT_NONE;
        if (cam_y <= 0 || cam_y >= 135) {
            dismissed_alert = ALERT_NONE;
        }
    }
}

static void init_ui() {
    lv_obj_t* scr = lv_scr_act();
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x000000), 0);
    lv_obj_clear_flag(scr, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_event_cb(scr, on_viewport_tapped, LV_EVENT_CLICKED, nullptr);

    // 240x240 Circular Viewport Mask (Clean Dark Car/Game Minimap Background)
    circle_viewport = lv_obj_create(scr);
    lv_obj_set_size(circle_viewport, 240, 240);
    lv_obj_set_pos(circle_viewport, VIEWPORT_OFFSET_X, VIEWPORT_OFFSET_Y);
    lv_obj_set_style_radius(circle_viewport, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_clip_corner(circle_viewport, true, 0);
    lv_obj_set_style_bg_color(circle_viewport, lv_color_hex(0x090D16), 0);
    lv_obj_set_style_border_width(circle_viewport, 2, 0);
    lv_obj_set_style_border_color(circle_viewport, lv_color_hex(0x1E293B), 0);
    lv_obj_set_style_pad_all(circle_viewport, 0, 0);
    lv_obj_clear_flag(circle_viewport, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_event_cb(circle_viewport, on_viewport_tapped, LV_EVENT_CLICKED, nullptr);
    lv_obj_add_event_cb(circle_viewport, on_viewport_draw, LV_EVENT_DRAW_MAIN, nullptr);

    // POI Markers Pool with high-contrast icon badges
    for (uint8_t i = 0; i < MAX_POIS; i++) {
        poi_markers[i] = lv_obj_create(circle_viewport);
        lv_obj_set_size(poi_markers[i], 18, 18);
        lv_obj_set_style_radius(poi_markers[i], LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_border_width(poi_markers[i], 2, 0);
        lv_obj_set_style_border_color(poi_markers[i], lv_color_hex(0x090D16), 0);
        lv_obj_set_style_pad_all(poi_markers[i], 0, 0);
        lv_obj_clear_flag(poi_markers[i], LV_OBJ_FLAG_SCROLLABLE);
        lv_obj_clear_flag(poi_markers[i], LV_OBJ_FLAG_CLICKABLE);
        lv_obj_add_flag(poi_markers[i], LV_OBJ_FLAG_HIDDEN);

        poi_icons[i] = lv_img_create(poi_markers[i]);
        lv_obj_center(poi_icons[i]);
        lv_obj_set_style_img_recolor(poi_icons[i], lv_color_white(), 0);
        lv_obj_set_style_img_recolor_opa(poi_icons[i], LV_OPA_COVER, 0);
        lv_obj_clear_flag(poi_icons[i], LV_OBJ_FLAG_CLICKABLE);
    }

    // Fixed Player Car Navigation Chevron (0° Heading-Up, Dark Outline + Electric Cyan)
    car_points[0] = {CAR_CENTER_X, CAR_CENTER_Y - 10};
    car_points[1] = {CAR_CENTER_X + 8, CAR_CENTER_Y + 8};
    car_points[2] = {CAR_CENTER_X, CAR_CENTER_Y + 3};
    car_points[3] = {CAR_CENTER_X - 8, CAR_CENTER_Y + 8};
    car_points[4] = {CAR_CENTER_X, CAR_CENTER_Y - 10};

    car_shadow = lv_line_create(circle_viewport);
    lv_line_set_points(car_shadow, car_points, 5);
    lv_obj_set_style_line_color(car_shadow, lv_color_hex(0x000000), 0);
    lv_obj_set_style_line_width(car_shadow, 6, 0);
    lv_obj_set_style_line_rounded(car_shadow, true, 0);
    lv_obj_clear_flag(car_shadow, LV_OBJ_FLAG_CLICKABLE);

    car_icon = lv_line_create(circle_viewport);
    lv_line_set_points(car_icon, car_points, 5);
    lv_obj_set_style_line_color(car_icon, lv_color_hex(0x00F0FF), 0);
    lv_obj_set_style_line_width(car_icon, 3, 0);
    lv_obj_set_style_line_rounded(car_icon, true, 0);
    lv_obj_clear_flag(car_icon, LV_OBJ_FLAG_CLICKABLE);

    // Static Top Warning Badge with Icon (No pulsing, tap anywhere to dismiss)
    alert_badge = lv_obj_create(circle_viewport);
    lv_obj_set_size(alert_badge, 42, 22);
    lv_obj_set_pos(alert_badge, CAR_CENTER_X - 21, 14);
    lv_obj_set_style_radius(alert_badge, 11, 0);
    lv_obj_set_style_border_width(alert_badge, 2, 0);
    lv_obj_set_style_border_color(alert_badge, lv_color_hex(0xFFFFFF), 0);
    lv_obj_set_style_pad_all(alert_badge, 0, 0);
    lv_obj_clear_flag(alert_badge, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_clear_flag(alert_badge, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_flag(alert_badge, LV_OBJ_FLAG_HIDDEN);

    alert_badge_icon = lv_img_create(alert_badge);
    lv_obj_center(alert_badge_icon);
    lv_obj_set_style_img_recolor(alert_badge_icon, lv_color_white(), 0);
    lv_obj_set_style_img_recolor_opa(alert_badge_icon, LV_OPA_COVER, 0);
    lv_obj_clear_flag(alert_badge_icon, LV_OBJ_FLAG_CLICKABLE);

#if ENABLE_DEBUG_STRIP
    debug_label = lv_label_create(scr);
    lv_obj_set_pos(debug_label, 2, 215);
    lv_obj_set_style_text_color(debug_label, lv_color_hex(0x4A5568), 0);
    lv_label_set_text(debug_label, "CYD BENCH");
#endif
}

static void init_ble() {
    NimBLEDevice::init("RoundDash-Copilot");
    NimBLEDevice::setMTU(512);
    NimBLEDevice::setSecurityAuth(true, true, true); // Required for Apple ANCS bonding
    NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);

    NimBLEServer* pServer = NimBLEDevice::createServer();
    pServer->setCallbacks(new ServerCallbacks());

    NimBLEService* pService = pServer->createService(MAP_SERVICE_UUID);
    NimBLECharacteristic* pChar = pService->createCharacteristic(
        MAP_FRAME_CHAR_UUID,
        NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
    );
    pChar->setCallbacks(new MapFrameCallbacks());
    pService->start();

    NimBLEAdvertising* pAdv = NimBLEDevice::getAdvertising();
    pAdv->addServiceUUID(MAP_SERVICE_UUID);

    // Apple ANCS Service Solicitation (0x15 = BLE_HS_ADV_TYPE_SOL_UUIDS128)
    const uint8_t ancs_solicit[] = {
        0x11, 0x15,
        0xD0, 0x00, 0x2D, 0x12, 0x1E, 0x4B, 0x0F, 0xA4,
        0x99, 0x4E, 0xCE, 0xB5, 0x31, 0xF4, 0x05, 0x79
    };
    NimBLEAdvertisementData scanData;
    scanData.addData(std::string(reinterpret_cast<const char*>(ancs_solicit), sizeof(ancs_solicit)));
    pAdv->setScanResponseData(scanData);
    pAdv->setScanResponse(true);
    pAdv->start();
}

void setup() {
    Serial.begin(115200);
    delay(500);
    Serial.printf("[INIT] Starting RoundDash-Copilot CYD...\n");
    Serial.printf("[INIT] BT status before init: %d\n", (int)esp_bt_controller_get_status());
    tft.begin();
#if defined(TARGET_CYD)
    tft.setRotation(1);
#endif
    tft.fillScreen(TFT_BLACK);
    tft.setBrightness(210);
    Serial.printf("[INIT] Screen size: %dx%d, Board: %d\n", tft.width(), tft.height(), (int)tft.getBoard());

    lv_init();
    lv_disp_draw_buf_init(&draw_buf, buf1, nullptr, SCREEN_WIDTH * 20);

    static lv_disp_drv_t disp_drv;
    lv_disp_drv_init(&disp_drv);
    disp_drv.hor_res  = SCREEN_WIDTH;
    disp_drv.ver_res  = SCREEN_HEIGHT;
    disp_drv.flush_cb = my_disp_flush;
    disp_drv.draw_buf = &draw_buf;
    lv_disp_drv_register(&disp_drv);

    static lv_indev_drv_t indev_drv;
    lv_indev_drv_init(&indev_drv);
    indev_drv.type    = LV_INDEV_TYPE_POINTER;
    indev_drv.read_cb = my_touchpad_read;
    lv_indev_drv_register(&indev_drv);

    init_ui();
    init_ble();
}

void loop() {
    static uint32_t last_tick = millis();
    uint32_t now = millis();
    lv_tick_inc(now - last_tick);
    last_tick = now;

    if (!ble_connected) {
        static uint32_t last_demo = 0;
        if (now - last_demo >= 50) {
            last_demo = now;
            run_bench_demo();
            render_map_frame();
        }
    } else if (frame_dirty) {
        frame_dirty = false;
        render_map_frame();
    }

#if ENABLE_DEBUG_STRIP
    static uint32_t last_dbg = 0;
    if (now - last_dbg >= 1000) {
        last_dbg = now;
        lv_label_set_text_fmt(
            debug_label,
            "%s\n%u cm/px",
            ble_connected ? "BLE LIVE" : "DEMO",
            current_scale_cm_px
        );
    }
#endif

    static uint32_t last_serial = 0;
    if (now - last_serial >= 2000) {
        last_serial = now;
        Serial.printf("[CYD] Mode: %s | Scale: %u (render %u) cm/px | Alert: %u | Roads: %u, POIs: %u\n",
                      ble_connected ? "LIVE iPHONE BLE" : "BENCH DEMO SIM",
                      current_scale_cm_px,
                      render_scale_cm_px,
                      incoming_alert,
                      active_road_count,
                      active_poi_count);
        if (ble_connected && active_road_count > 0) {
            Serial.printf("      R0:(%d,%d)->(%d,%d) R1:(%d,%d)->(%d,%d)\n",
                          roads[0].x1, roads[0].y1, roads[0].x2, roads[0].y2,
                          roads[1].x1, roads[1].y1, roads[1].x2, roads[1].y2);
        }
    }

    lv_timer_handler();
    delay(5);
}
