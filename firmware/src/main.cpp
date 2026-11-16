#include <Arduino.h>
#include <lvgl.h>
#include <NimBLEDevice.h>
#include <math.h>
#include "board_config.h"
#include "protocol.h"

static LGFX tft;

// LVGL partial draw buffer (240 x 20 px = 9.6 KB internal DRAM, safe without PSRAM)
static lv_disp_draw_buf_t draw_buf;
static lv_color_t buf1[240 * 20];

// UI Objects
static lv_obj_t* circle_viewport = nullptr;
static lv_obj_t* road_lines[MAX_ROAD_SEGMENTS];
static lv_point_t road_points[MAX_ROAD_SEGMENTS][2];
static lv_obj_t* poi_markers[MAX_POIS];
static lv_obj_t* car_icon = nullptr;
static lv_point_t car_points[4];
static lv_obj_t* alert_badge = nullptr;

#if ENABLE_DEBUG_STRIP
static lv_obj_t* debug_label = nullptr;
#endif

// Shared State
static volatile bool ble_connected = false;
static volatile bool frame_dirty = false;
static volatile uint32_t rx_packets = 0;

static uint16_t current_scale_cm_px = 165;
static uint8_t incoming_alert = ALERT_NONE;
static uint8_t dismissed_alert = ALERT_NONE;
static uint8_t active_road_count = 0;
static uint8_t active_poi_count = 0;
static RoadSegment roads[MAX_ROAD_SEGMENTS];
static PoiItem pois[MAX_POIS];

// Car anchor inside 240x240 circle (offset down for forward look-ahead)
static constexpr int CAR_CENTER_X = 120;
static constexpr int CAR_CENTER_Y = 145;

// Display Flush Callback
static void my_disp_flush(lv_disp_drv_t* disp, const lv_area_t* area, lv_color_t* color_p) {
    uint32_t w = (area->x2 - area->x1 + 1);
    uint32_t h = (area->y2 - area->y1 + 1);
    tft.startWrite();
    tft.setAddrWindow(area->x1, area->y1, w, h);
    tft.writePixels((lgfx::rgb565_t*)&color_p->full, w * h);
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

// BLE GATT Frame Receiver
class MapFrameCallbacks : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* pCharacteristic) override {
        std::string val = pCharacteristic->getValue();
        if (val.size() < sizeof(FrameHeader)) return;

        const uint8_t* ptr = reinterpret_cast<const uint8_t*>(val.data());
        FrameHeader hdr;
        memcpy(&hdr, ptr, sizeof(FrameHeader));
        if (hdr.msg_type != 0x01) return;

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
        rx_packets++;
        frame_dirty = true;
    }
};

class ServerCallbacks : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer* pServer) override { ble_connected = true; }
    void onDisconnect(NimBLEServer* pServer) override {
        ble_connected = false;
        NimBLEDevice::startAdvertising();
    }
};

static inline lv_coord_t meters_to_px_x(int16_t mx) {
    int32_t cm = static_cast<int32_t>(mx) * 100;
    return static_cast<lv_coord_t>(CAR_CENTER_X + (cm / current_scale_cm_px));
}

static inline lv_coord_t meters_to_px_y(int16_t my) {
    int32_t cm = static_cast<int32_t>(my) * 100;
    return static_cast<lv_coord_t>(CAR_CENTER_Y - (cm / current_scale_cm_px));
}

static void render_map_frame() {
    // 1. Update Road Polylines
    for (uint8_t i = 0; i < MAX_ROAD_SEGMENTS; i++) {
        if (i < active_road_count) {
            road_points[i][0].x = meters_to_px_x(roads[i].x1);
            road_points[i][0].y = meters_to_px_y(roads[i].y1);
            road_points[i][1].x = meters_to_px_x(roads[i].x2);
            road_points[i][1].y = meters_to_px_y(roads[i].y2);
            lv_line_set_points(road_lines[i], road_points[i], 2);

            if (roads[i].flags & ROAD_FLAG_CLOSED) {
                lv_obj_set_style_line_color(road_lines[i], lv_color_hex(0xE53E3E), 0);
                lv_obj_set_style_line_width(road_lines[i], 3, 0);
            } else if (roads[i].flags & ROAD_FLAG_CURRENT) {
                lv_obj_set_style_line_color(road_lines[i], lv_color_hex(0xFFFFFF), 0);
                lv_obj_set_style_line_width(road_lines[i], 5, 0);
            } else {
                lv_obj_set_style_line_color(road_lines[i], lv_color_hex(0x4A5568), 0);
                lv_obj_set_style_line_width(road_lines[i], 2, 0);
            }
            lv_obj_clear_flag(road_lines[i], LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(road_lines[i], LV_OBJ_FLAG_HIDDEN);
        }
    }

    // 2. Update POI Icons
    for (uint8_t i = 0; i < MAX_POIS; i++) {
        if (i < active_poi_count) {
            lv_coord_t px = meters_to_px_x(pois[i].x) - 6;
            lv_coord_t py = meters_to_px_y(pois[i].y) - 6;
            lv_obj_set_pos(poi_markers[i], px, py);

            switch (pois[i].poi_type) {
                case POI_FIXED_CAM:
                case POI_MOBILE_TRAP:
                case POI_TRAJECTCONTROLE:
                    lv_obj_set_style_bg_color(poi_markers[i], lv_color_hex(0xFF2A2A), 0);
                    lv_obj_set_size(poi_markers[i], 14, 14);
                    break;
                case POI_CLOSURE_HAZARD:
                    lv_obj_set_style_bg_color(poi_markers[i], lv_color_hex(0xF6AD55), 0);
                    lv_obj_set_size(poi_markers[i], 12, 12);
                    break;
                case POI_GAS_STATION:
                default:
                    lv_obj_set_style_bg_color(poi_markers[i], lv_color_hex(0x38B2AC), 0);
                    lv_obj_set_size(poi_markers[i], 9, 9);
                    break;
            }
            lv_obj_clear_flag(poi_markers[i], LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(poi_markers[i], LV_OBJ_FLAG_HIDDEN);
        }
    }

    // 3. Update Static Top Warning Badge
    if (incoming_alert != ALERT_NONE && incoming_alert != dismissed_alert) {
        if (incoming_alert == ALERT_SPEED_CAM) {
            lv_obj_set_style_bg_color(alert_badge, lv_color_hex(0xE53E3E), 0);
        } else if (incoming_alert == ALERT_EMERGENCY) {
            lv_obj_set_style_bg_color(alert_badge, lv_color_hex(0x3182CE), 0);
        } else {
            lv_obj_set_style_bg_color(alert_badge, lv_color_hex(0xDD6B20), 0);
        }
        lv_obj_clear_flag(alert_badge, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(alert_badge, LV_OBJ_FLAG_HIDDEN);
    }
}

// Bench Demo Simulation when no iPhone is connected
static void run_bench_demo() {
    static float sim_t = 0.0f;
    sim_t += 0.05f;
    int16_t cam_y = static_cast<int16_t>(180 - fmodf(sim_t * 25.0f, 240.0f));
    float sway = sinf(sim_t * 0.6f) * 25.0f;

    current_scale_cm_px = 150;
    active_road_count = 3;

    // Main current road curving gently ahead
    roads[0] = {0, -120, static_cast<int16_t>(sway * 0.4f), 80, ROAD_FLAG_CURRENT};
    roads[1] = {static_cast<int16_t>(sway * 0.4f), 80, static_cast<int16_t>(sway), 260, ROAD_FLAG_CURRENT};
    // Cross street
    roads[2] = {-160, static_cast<int16_t>(cam_y - 20), 160, static_cast<int16_t>(cam_y + 10), 0};

    active_poi_count = 2;
    pois[0] = {static_cast<int16_t>(sway * 0.5f), cam_y, POI_FIXED_CAM};
    pois[1] = {55, static_cast<int16_t>(cam_y - 60), POI_GAS_STATION};

    incoming_alert = (cam_y > 0 && cam_y < 140) ? ALERT_SPEED_CAM : ALERT_NONE;
    if (incoming_alert == ALERT_NONE) dismissed_alert = ALERT_NONE;
}

static void init_ui() {
    lv_obj_t* scr = lv_scr_act();
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x111318), 0);

    // 240x240 Circular Viewport Mask
    circle_viewport = lv_obj_create(scr);
    lv_obj_set_size(circle_viewport, 240, 240);
    lv_obj_set_pos(circle_viewport, 0, VIEWPORT_OFFSET_Y);
    lv_obj_set_style_radius(circle_viewport, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_clip_corner(circle_viewport, true, 0);
    lv_obj_set_style_bg_color(circle_viewport, lv_color_hex(0x000000), 0);
    lv_obj_set_style_border_width(circle_viewport, 2, 0);
    lv_obj_set_style_border_color(circle_viewport, lv_color_hex(0x2D3748), 0);
    lv_obj_set_style_pad_all(circle_viewport, 0, 0);
    lv_obj_clear_flag(circle_viewport, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_event_cb(circle_viewport, on_viewport_tapped, LV_EVENT_CLICKED, nullptr);

    // Road Lines Pool
    for (uint8_t i = 0; i < MAX_ROAD_SEGMENTS; i++) {
        road_lines[i] = lv_line_create(circle_viewport);
        lv_obj_set_style_line_rounded(road_lines[i], true, 0);
        lv_obj_add_flag(road_lines[i], LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(road_lines[i], LV_OBJ_FLAG_CLICKABLE);
    }

    // POI Markers Pool
    for (uint8_t i = 0; i < MAX_POIS; i++) {
        poi_markers[i] = lv_obj_create(circle_viewport);
        lv_obj_set_style_radius(poi_markers[i], LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_border_width(poi_markers[i], 2, 0);
        lv_obj_set_style_border_color(poi_markers[i], lv_color_hex(0x000000), 0);
        lv_obj_add_flag(poi_markers[i], LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(poi_markers[i], LV_OBJ_FLAG_CLICKABLE);
    }

    // Fixed Player Car Chevron (0° Heading-Up)
    car_points[0] = {CAR_CENTER_X, CAR_CENTER_Y - 10};
    car_points[1] = {CAR_CENTER_X + 7, CAR_CENTER_Y + 8};
    car_points[2] = {CAR_CENTER_X, CAR_CENTER_Y + 3};
    car_points[3] = {CAR_CENTER_X - 7, CAR_CENTER_Y + 8};
    car_icon = lv_line_create(circle_viewport);
    lv_line_set_points(car_icon, car_points, 4);
    lv_obj_set_style_line_color(car_icon, lv_color_hex(0x00E5FF), 0);
    lv_obj_set_style_line_width(car_icon, 3, 0);
    lv_obj_set_style_line_rounded(car_icon, true, 0);
    lv_obj_clear_flag(car_icon, LV_OBJ_FLAG_CLICKABLE);

    // Static Top Warning Badge (No pulsing, tap anywhere to dismiss)
    alert_badge = lv_obj_create(circle_viewport);
    lv_obj_set_size(alert_badge, 36, 22);
    lv_obj_set_pos(alert_badge, 120 - 18, 16);
    lv_obj_set_style_radius(alert_badge, 11, 0);
    lv_obj_set_style_border_width(alert_badge, 2, 0);
    lv_obj_set_style_border_color(alert_badge, lv_color_hex(0xFFFFFF), 0);
    lv_obj_add_flag(alert_badge, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(alert_badge, LV_OBJ_FLAG_CLICKABLE);

#if ENABLE_DEBUG_STRIP
    debug_label = lv_label_create(scr);
    lv_obj_set_pos(debug_label, 8, 248);
    lv_obj_set_style_text_color(debug_label, lv_color_hex(0xA0AEC0), 0);
    lv_label_set_text(debug_label, "CYD PROTOTYPE | Waiting for BLE...");
#endif
}

static void init_ble() {
    NimBLEDevice::init("RoundDash-Copilot");
    NimBLEDevice::setMTU(512);
    NimBLEDevice::setSecurityAuth(true, true, true); // Required for Apple ANCS bonding

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
    pAdv->setScanResponse(true);
    pAdv->start();
}

void setup() {
    Serial.begin(115200);
    tft.init();
    tft.setBrightness(210);

    lv_init();
    lv_disp_draw_buf_init(&draw_buf, buf1, nullptr, 240 * 20);

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
    if (now - last_dbg >= 500) {
        last_dbg = now;
        lv_label_set_text_fmt(
            debug_label,
            "MODE: %s\nPKTS: %lu | SCALE: %u cm/px\nALERT TIER: %u (TAP CIRCLE TO CLEAR)",
            ble_connected ? "LIVE iPHONE BLE" : "BENCH DEMO SIM",
            static_cast<unsigned long>(rx_packets),
            current_scale_cm_px,
            incoming_alert
        );
    }
#endif

    lv_timer_handler();
    delay(5);
}
