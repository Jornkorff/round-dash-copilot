#!/usr/bin/env bash
set -euo pipefail

mkdir -p .agents/rules \
         .agents/skills/build-and-flash-cyd \
         .agents/skills/port-to-waveshare-s3 \
         docs \
         firmware/include \
         firmware/src \
         companion-ios/Sources

# ------------------------------------------------------------------------------
# 1. .gitignore
# ------------------------------------------------------------------------------
cat << 'INNER' > .gitignore
.pio/
.vscode/.browse.c_cpp.db*
.vscode/c_cpp_properties.json
.vscode/launch.json
.vscode/ipch/
__pycache__/
.venv/
.DS_Store
*.swp
INNER

# ------------------------------------------------------------------------------
# 2. GEMINI.md & AGENTS.md (Antigravity Always-On Root Rules)
# ------------------------------------------------------------------------------
cat << 'INNER' > GEMINI.md
# Project: Round Dash Copilot (`round-dash-copilot`)

## Core Objective
Build a minimalist 1.28-inch (240x240) circular dashboard minimap and speed-camera radar powered by an ESP32-S3, paired over Bluetooth Low Energy (BLE) with an iPhone while Apple CarPlay runs simultaneously on the vehicle's main head unit.

## Non-Negotiable Architecture Invariants
1. **Apple CarPlay Coexistence:** The iPhone stays connected to Apple CarPlay (wired or wireless) at all times. NEVER use iPhone Personal Hotspot (which disconnects Wireless CarPlay). All iPhone-to-ESP32 communication uses Bluetooth Low Energy (custom GATT stream + Apple ANCS).
2. **Worldwide Zero-Upload Maps:** NEVER store map tiles, `.osm.pbf` extracts, or regional road databases on the ESP32. The iPhone dynamically queries nearby road centerlines and POIs around live GPS coordinates and streams pre-rotated, car-relative vector segments (~5 Hz) over BLE.
3. **Pure Minimap UI (Zero Text or Number Clutter):**
   - Render ONLY: rotating vector road lines, centered player car icon (`0°` heading-up), road-anchored POI icons, and a single minimal warning badge at the top of the circle when an alert is active.
   - FORBIDDEN on screen: current speed readouts, speed limit signs, clocks, menus, settings icons, or distance counters.
   - Vehicle speed is used invisibly on the iPhone solely to adjust the map zoom scale sent over BLE.
4. **No Audio & No Heavy Animations:**
   - FORBIDDEN: piezo buzzers, speaker chimes, pulsing borders, flashing overlays, or heavy shaders. Visual static warning badges only to keep LVGL frame rates smooth.
5. **Hands-Free First + Full-Screen Tap Only:**
   - Normal driving operation is 100% hands-free.
   - FORBIDDEN: small touchscreen buttons or swipe navigation. Tapping anywhere on the 240x240 circular viewport dismisses an active top warning badge.
6. **Hardware Migration Path & Power:**
   - Phase 1 (Current): Prototype on ESP32 Cheap Yellow Display (`ESP32-2432S028R`, no PSRAM) using a centered `240x240` circular mask + NimBLE.
   - Phase 2 (Target): Migrate identical LVGL + NimBLE firmware to **Waveshare ESP32-S3-Touch-LCD-1.28**.
   - Power: Switched ignition USB-C first; later hardwired via 12V-to-5V ACC fuse-tap buck converter. NEVER design around an internal LiPo battery due to dashboard heat.

## Repository Map
- `GEMINI.md` / `AGENTS.md` — Always-on workspace rules.
- `.agents/rules/` — Path-scoped rules for `firmware/` and `companion-ios/`.
- `.agents/skills/` — Reusable build, flash, and migration skills.
- `docs/` — Functional requirements, hardware BOM/pinouts, BLE protocol spec, and decisions log.
- `firmware/` — PlatformIO (C++ / LVGL v8.3 / LovyanGFX / NimBLE-Arduino) project.
- `companion-ios/` — Swift CoreLocation, CoreBluetooth, Overpass OSM, and Dutch NDW OTM streamer.
INNER

cp GEMINI.md AGENTS.md

# ------------------------------------------------------------------------------
# 3. Path-Scoped Antigravity Rules (.agents/rules/)
# ------------------------------------------------------------------------------
cat << 'INNER' > .agents/rules/embedded-firmware.md
---
trigger: glob
globs: ["firmware/**"]
---

# Embedded Firmware Rules (ESP32 CYD & Waveshare S3)
- Keep RAM usage compatible with classic `ESP32-WROOM-32` (520 KB SRAM, NO PSRAM) during Phase 1: always use `NimBLE-Arduino` (never Bluedroid) and an LVGL partial draw buffer (`240 * 20` pixels in internal DRAM).
- All trigonometric rotation and lat/lon-to-meter projection is performed on the iPhone. Firmware receives car-relative `(x, y)` meter coordinates (`+Y` = forward heading) and scales them directly to pixels using `scale_cm_per_px`.
- Maintain strict separation between hardware pin/driver setup (`include/board_config.h`), binary BLE wire structs (`include/protocol.h`), and LVGL rendering (`src/main.cpp`).
- Never add audio outputs, buzzer PWM code, or pulsing/blinking LVGL animations.
INNER

cat << 'INNER' > .agents/rules/ios-companion.md
---
trigger: glob
globs: ["companion-ios/**"]
---

# iOS Companion App Rules (Swift)
- Maintain simultaneous Apple CarPlay compatibility: never require Wi-Fi Hotspot or take exclusive audio session focus.
- Configure `CLLocationManager` for background automotive navigation (`kCLLocationAccuracyBestForNavigation`, `allowsBackgroundLocationUpdates = true`, `pausesLocationUpdatesAutomatically = false`).
- Project all road segments and POIs into car-relative meters (`+Y` aligned with `course` heading) before packing into the binary BLE frame defined in `firmware/include/protocol.h`.
- Enforce the 4-tier POI priority order when truncating packets to fit BLE MTU limits: P1 Speed/Red-Light/Trajectcontrole Cameras > P2 Emergency Vehicles > P3 Road Closures/Accidents/Roadworks > P4 Fuel Stations.
INNER

# ------------------------------------------------------------------------------
# 4. Antigravity Skills (.agents/skills/)
# ------------------------------------------------------------------------------
cat << 'INNER' > .agents/skills/build-and-flash-cyd/SKILL.md
---
name: build-and-flash-cyd
description: Compile, verify, and flash Phase 1 firmware onto the ESP32 Cheap Yellow Display (CYD) using PlatformIO.
---

# Build and Flash CYD Prototype

## Steps
1. Navigate to `firmware/` and run `pio run -e cyd_proto` to compile the CYD target.
2. Verify that RAM usage stays safely below 65% of internal DRAM so NimBLE + LVGL run without heap fragmentation.
3. If a board is connected via USB, run `pio run -e cyd_proto -t upload` and open serial telemetry at `115200` baud (`pio device monitor -b 115200`).
4. Confirm on the CYD screen:
   - Centered `240x240` black circular viewport mask.
   - White player chevron fixed at `(120, 145)` pointing straight up.
   - Smooth simulated road rotation and speed-camera POI movement when no iPhone is connected.
   - Bottom `80px` debug strip displaying BLE status, FPS, and active alert tier.
   - Tapping anywhere inside the circle dismisses the top warning badge.
INNER

cat << 'INNER' > .agents/skills/port-to-waveshare-s3/SKILL.md
---
name: port-to-waveshare-s3
description: Switch build target from Phase 1 CYD to Phase 2 Waveshare ESP32-S3-Touch-LCD-1.28 hardware.
---

# Port Firmware to Waveshare ESP32-S3-Touch-LCD-1.28

## Steps
1. Verify display (`GC9A01` SPI) and touch (`CST816S` I2C) GPIO assignments in `firmware/include/board_config.h` against the Waveshare ESP32-S3-Touch-LCD-1.28 schematic.
2. Disable the CYD bottom debug bar (`ENABLE_DEBUG_STRIP 0`) so the `240x240` circular container fills `(0, 0)` to `(240, 240)` natively.
3. Compile with `pio run -e waveshare_s3_round` and flash over USB-C (`pio run -e waveshare_s3_round -t upload`).
4. Optional enhancement: fuse `QMI8658` 6-axis IMU yaw rate to interpolate road rotation smoothly between 5 Hz BLE frames.
INNER

# ------------------------------------------------------------------------------
# 5. Documentation Suite (docs/)
# ------------------------------------------------------------------------------
cat << 'INNER' > docs/01-requirements.md
# 01 — Functional & UX Requirements

## 1. Visual Layout (240x240 Circular Viewport)
- **Background:** Pure black (`#000000`) for maximum contrast and zero night glare.
- **Center Anchor (`x=120, y=145`):** White directional car/chevron icon offset slightly below geometric center to maximize forward look-ahead, fixed pointing straight up (`0°`).
- **Heading-Up Rotation:** Roads and POIs rotate smoothly around the player car so direction of travel is always straight up.
- **Road Styling:**
  - Active/matched road: `5 px` stroke width, pure white (`#FFFFFF`).
  - Connecting/surrounding roads: `2 px` stroke width, muted slate gray (`#4A5568`).
  - Closed roads: `3 px` crimson (`#E53E3E`).
- **Dynamic Speed Auto-Zoom (Calculated Invisibly on iPhone):**
  - `<= 35 km/h`: ~`120 m` look-ahead radius (`100 cm/px`)
  - `50 km/h`: ~`200 m` look-ahead radius (`165 cm/px`)
  - `80 km/h`: ~`350 m` look-ahead radius (`290 cm/px`)
  - `>= 100 km/h`: ~`500 m` look-ahead radius (`415 cm/px`)

## 2. Four-Tier Alert & POI Priority Hierarchy
| Tier | Category | Source | Map Marker | Top Warning Badge (`x=120, y=26`) |
| :--- | :--- | :--- | :--- | :--- |
| **P1 (Highest)** | Fixed speed cams, red-light cams, *trajectcontroles*, mobile speed traps, laser checks | OSM (`highway=speed_camera`, `enforcement`) + Flitsmeister ANCS | Red camera/radar dot on road | Solid red camera badge |
| **P2 (High)** | Approaching emergency vehicles (ambulances) | Flitsmeister ANCS | Blue/red beacon icon (when coords available) | Solid blue/red siren badge |
| **P3 (Medium)** | Accidents, stationary vehicles, road closures, roadworks | Flitsmeister ANCS + Dutch NDW OTM live feed | Amber triangle / red closure bar on road | Solid amber hazard badge |
| **P4 (Ambient)** | Gas stations | OSM (`amenity=fuel`) | Dimmed cyan/gray fuel icon off-road | None (map icon only) |
| **Excluded** | Current speed readout, speed limits, overspeed alerts | — | — | Explicitly excluded |

## 3. Interaction & Feedback Rules
- **Audio:** Disabled (zero buzzer or speaker output).
- **Animations:** Smooth coordinate updates only; no pulsing, blinking, or heavy shader effects.
- **Touch Input:** Full-screen hit area (`240x240`). Single tap anywhere dismisses the active top warning badge; road POI markers remain visible until passed.
INNER

cat << 'INNER' > docs/02-hardware-bom.md
# 02 — Hardware Bill of Materials & Pinout Reference

## Phase 1: Bench Prototype (ESP32 Cheap Yellow Display)
- **Board:** `ESP32-2432S028R` (2.8" `240x320` ILI9341 SPI TFT + XPT2046 resistive touch, classic `ESP32-WROOM-32`, 520 KB SRAM, no PSRAM).
- **Display Strategy:** Centered `240x240` circular LVGL mask (`y = 0..239`), plus bottom `240x80` (`y = 240..319`) developer status bar.
- **Verified CYD Pinout:**
  - TFT SPI (`HSPI`): `SCLK=14`, `MOSI=13`, `MISO=12`, `CS=15`, `DC=2`, `RST=-1`, `BL=21`
  - Touch SPI (`VSPI`): `SCLK=25`, `MOSI=32`, `MISO=39`, `CS=33`, `IRQ=36`

## Phase 2: Production 1.28" Round Dashboard Unit
- **Board:** Waveshare `ESP32-S3-Touch-LCD-1.28`
  - MCU: `ESP32-S3R2` (240 MHz dual-core, 16 MB Flash, 2 MB PSRAM)
  - Display: 1.28" IPS round LCD, `240x240` RGB565 (`GC9A01A` SPI)
  - Touch: `CST816S` capacitive touch controller (I2C)
  - IMU: `QMI8658` 6-axis accelerometer/gyroscope
- **Power & Mounting:**
  - No LiPo battery (thermal safety behind windshield).
  - Stage A: Switched 12V socket USB-C adapter + right-angle USB-C cable.
  - Stage B: 12V-to-5V 3A hardwire buck converter + Add-a-Circuit `ACC` fuse tap.
  - Enclosure: 3D-printed dash/vent pod in **PETG** or **ASA** (never PLA).
INNER

cat << 'INNER' > docs/03-architecture.md
# 03 — Technical Architecture & BLE Protocol

## 1. Dual-Channel BLE Architecture
1. **Channel A — Apple Notification Center Service (ANCS Client):**
   - ESP32 bonds with iPhone over BLE and subscribes to Apple ANCS (`7905F431-B5CE-4E99-A40F-4B1E122D00D0`).
   - Filters notifications where `AppIdentifier` matches Flitsmeister.
   - Keyword classification (case-insensitive):
     - **P1 (`ALERT_SPEED_CAM`):** `flitser`, `flitspaal`, `mobiele`, `laser`, `controle`, `trajectcontrole`, `speed camera`, `radar`
     - **P2 (`ALERT_EMERGENCY`):** `ambulance`, `hulpdienst`, `voorrangsvoertuig`, `emergency`
     - **P3 (`ALERT_HAZARD`):** `ongeval`, `ongeluk`, `stilstaand`, `afgesloten`, `wegwerkzaamheden`, `file`, `accident`, `closure`
2. **Channel B — Custom Vector Map GATT Service (`5 Hz` Binary Stream):**
   - Service UUID: `4FAFC201-1FB5-459E-8FCC-C5C9C331914B`
   - Frame Characteristic UUID (Write Without Response): `BEB5483E-36E1-4688-B7F5-EA07361B26A8`
   - All coordinates are pre-rotated on the iPhone into car-relative meters (`dx` right/left, `dy` forward/back, clamped to `±600m`).

## 2. Packed Binary Frame Layout (`<= 512 bytes`)
- **Header (`6 bytes`):**
  - `uint8_t msg_type` (`0x01`)
  - `uint16_t scale_cm_per_px` (little-endian)
  - `uint8_t active_alert_type` (`0`=None, `1`=P1_Cam, `2`=P2_Emergency, `3`=P3_Hazard)
  - `uint8_t road_count` (`0..32`)
  - `uint8_t poi_count` (`0..16`)
- **Road Segment (`9 bytes` each × `road_count`):**
  - `int16_t x1, y1, x2, y2` (meters relative to car)
  - `uint8_t flags` (`bit 0` = `is_current_road`, `bit 1` = `is_closed`)
- **POI Item (`5 bytes` each × `poi_count`):**
  - `int16_t x, y` (meters relative to car)
  - `uint8_t poi_type` (`1`=FixedCam, `2`=MobileTrap, `3`=Trajectcontrole, `4`=Closure/Hazard, `5`=GasStation)
INNER

cat << 'INNER' > docs/04-decisions-log.md
# 04 — Design & Engineering Decisions Log

| Date | Area | Settled Decision | Rationale |
| :--- | :--- | :--- | :--- |
| 2026-11-16 | Connectivity | BLE (Custom GATT + ANCS), no Wi-Fi Hotspot | Preserves simultaneous Apple CarPlay and 5G cellular data. |
| 2026-11-16 | Maps | Live phone-streamed local vectors (no onboard map files) | Worldwide coverage without pre-uploading regional tiles. |
| 2026-11-16 | Driving UI | Pure heading-up vector minimap + speed auto-zoom; zero text/speed HUD | Maximum legibility on a 1.28" round display without clutter. |
| 2026-11-16 | Alerts | Priority: Speed/fines > Emergency > Accidents/closures; static badge only, no audio/pulsing | Keeps LVGL frame rate locked and avoids audio overlap with CarPlay. |
| 2026-11-16 | Controls | Hands-free default; full-screen single tap to dismiss alerts | Eliminates small touchscreen targets while driving. |
| 2026-11-16 | Hardware | Prototype on owned ESP32 CYD (`240x240` mask) before migrating to Waveshare S3 1.28" | Validates NimBLE + ANCS + LVGL vector pipeline immediately. |
| 2026-11-16 | Power | Switched USB-C first, optional 12V ACC fuse-tap buck converter later; no battery | Eliminates LiPo thermal hazards on the dashboard. |
INNER

# ------------------------------------------------------------------------------
# 6. PlatformIO Firmware (firmware/)
# ------------------------------------------------------------------------------
cat << 'INNER' > firmware/platformio.ini
[env:cyd_proto]
platform = espressif32
board = esp32dev
framework = arduino
monitor_speed = 115200
build_flags =
    -D TARGET_CYD=1
    -D LV_CONF_SIMPLE=1
    -D LV_MEM_SIZE="(48U * 1024U)"
    -D LV_COLOR_16_SWAP=1
lib_deps =
    lovyan03/LovyanGFX@^1.1.16
    lvgl/lvgl@^8.3.11
    h2zero/NimBLE-Arduino@^1.4.2

[env:waveshare_s3_round]
platform = espressif32
board = esp32-s3-devkitc-1
framework = arduino
monitor_speed = 115200
board_build.flash_size = 16MB
build_flags =
    -D TARGET_WAVESHARE_S3=1
    -D ARDUINO_USB_CDC_ON_BOOT=1
    -D LV_CONF_SIMPLE=1
    -D LV_MEM_SIZE="(64U * 1024U)"
    -D LV_COLOR_16_SWAP=1
lib_deps =
    lovyan03/LovyanGFX@^1.1.16
    lvgl/lvgl@^8.3.11
    h2zero/NimBLE-Arduino@^1.4.2
INNER

cat << 'INNER' > firmware/include/protocol.h
#pragma once
#include <stdint.h>

#define MAP_SERVICE_UUID        "4FAFC201-1FB5-459E-8FCC-C5C9C331914B"
#define MAP_FRAME_CHAR_UUID     "BEB5483E-36E1-4688-B7F5-EA07361B26A8"

#define MAX_ROAD_SEGMENTS       32
#define MAX_POIS                16

enum AlertTier : uint8_t {
    ALERT_NONE      = 0,
    ALERT_SPEED_CAM = 1, // P1: Fixed/mobile speed cam, red-light, trajectcontrole
    ALERT_EMERGENCY = 2, // P2: Approaching ambulance / emergency vehicle
    ALERT_HAZARD    = 3  // P3: Accident, stationary vehicle, road closure
};

enum PoiType : uint8_t {
    POI_FIXED_CAM       = 1,
    POI_MOBILE_TRAP     = 2,
    POI_TRAJECTCONTROLE = 3,
    POI_CLOSURE_HAZARD  = 4,
    POI_GAS_STATION     = 5
};

enum RoadFlags : uint8_t {
    ROAD_FLAG_CURRENT = 1 << 0,
    ROAD_FLAG_CLOSED  = 1 << 1
};

#pragma pack(push, 1)
struct FrameHeader {
    uint8_t  msg_type;          // 0x01 = Map Frame
    uint16_t scale_cm_per_px;   // Dynamic zoom factor from iPhone speed
    uint8_t  active_alert_type; // AlertTier enum
    uint8_t  road_count;
    uint8_t  poi_count;
};

struct RoadSegment {
    int16_t x1;
    int16_t y1;
    int16_t x2;
    int16_t y2;
    uint8_t flags;
};

struct PoiItem {
    int16_t x;
    int16_t y;
    uint8_t poi_type;
};
#pragma pack(pop)
INNER

cat << 'INNER' > firmware/include/board_config.h
#pragma once
#include <LovyanGFX.hpp>

#if defined(TARGET_CYD)

#define SCREEN_WIDTH        240
#define SCREEN_HEIGHT       320
#define VIEWPORT_OFFSET_Y   0
#define ENABLE_DEBUG_STRIP  1

class LGFX : public lgfx::LGFX_Device {
    lgfx::Panel_ILI9341 _panel_instance;
    lgfx::Bus_SPI       _bus_instance;
    lgfx::Light_PWM     _light_instance;
    lgfx::Touch_XPT2046 _touch_instance;

public:
    LGFX(void) {
        {
            auto cfg = _bus_instance.config();
            cfg.spi_host   = HSPI_HOST;
            cfg.spi_mode   = 0;
            cfg.freq_write = 40000000;
            cfg.freq_read  = 16000000;
            cfg.spi_3wire  = false;
            cfg.use_lock   = true;
            cfg.dma_channel = SPI_DMA_CH_AUTO;
            cfg.pin_sclk   = 14;
            cfg.pin_mosi   = 13;
            cfg.pin_miso   = 12;
            cfg.pin_dc     = 2;
            _bus_instance.config(cfg);
            _panel_instance.setBus(&_bus_instance);
        }
        {
            auto cfg = _panel_instance.config();
            cfg.pin_cs           = 15;
            cfg.pin_rst          = -1;
            cfg.pin_busy         = -1;
            cfg.panel_width      = 240;
            cfg.panel_height     = 320;
            cfg.offset_rotation  = 0;
            cfg.readable         = true;
            cfg.invert           = false;
            cfg.rgb_order        = false;
            cfg.bus_shared       = false;
            _panel_instance.config(cfg);
        }
        {
            auto cfg = _light_instance.config();
            cfg.pin_bl      = 21;
            cfg.invert      = false;
            cfg.freq        = 44100;
            cfg.pwm_channel = 7;
            _light_instance.config(cfg);
            _panel_instance.setLight(&_light_instance);
        }
        {
            auto cfg = _touch_instance.config();
            cfg.x_min       = 300;
            cfg.x_max       = 3900;
            cfg.y_min       = 200;
            cfg.y_max       = 3700;
            cfg.pin_int     = 36;
            cfg.bus_shared  = false;
            cfg.offset_rotation = 0;
            cfg.spi_host    = VSPI_HOST;
            cfg.freq        = 1000000;
            cfg.pin_sclk    = 25;
            cfg.pin_mosi    = 32;
            cfg.pin_miso    = 39;
            cfg.pin_cs      = 33;
            _touch_instance.config(cfg);
            _panel_instance.setTouch(&_touch_instance);
        }
        setPanel(&_panel_instance);
    }
};

#elif defined(TARGET_WAVESHARE_S3)

#define SCREEN_WIDTH        240
#define SCREEN_HEIGHT       240
#define VIEWPORT_OFFSET_Y   0
#define ENABLE_DEBUG_STRIP  0

// Note: Verify GPIO pin assignments against Waveshare ESP32-S3-Touch-LCD-1.28 schematic
class LGFX : public lgfx::LGFX_Device {
    lgfx::Panel_GC9A01  _panel_instance;
    lgfx::Bus_SPI       _bus_instance;
    lgfx::Light_PWM     _light_instance;
    lgfx::Touch_CST816S _touch_instance;

public:
    LGFX(void) {
        {
            auto cfg = _bus_instance.config();
            cfg.spi_host   = SPI2_HOST;
            cfg.spi_mode   = 0;
            cfg.freq_write = 80000000;
            cfg.freq_read  = 20000000;
            cfg.spi_3wire  = true;
            cfg.use_lock   = true;
            cfg.dma_channel = SPI_DMA_CH_AUTO;
            cfg.pin_sclk   = 10;
            cfg.pin_mosi   = 11;
            cfg.pin_miso   = 12;
            cfg.pin_dc     = 8;
            _bus_instance.config(cfg);
            _panel_instance.setBus(&_bus_instance);
        }
        {
            auto cfg = _panel_instance.config();
            cfg.pin_cs           = 9;
            cfg.pin_rst          = 14;
            cfg.pin_busy         = -1;
            cfg.panel_width      = 240;
            cfg.panel_height     = 240;
            cfg.invert           = true;
            cfg.rgb_order        = false;
            cfg.bus_shared       = false;
            _panel_instance.config(cfg);
        }
        {
            auto cfg = _light_instance.config();
            cfg.pin_bl      = 2;
            cfg.invert      = false;
            cfg.freq        = 44100;
            cfg.pwm_channel = 7;
            _light_instance.config(cfg);
            _panel_instance.setLight(&_light_instance);
        }
        {
            auto cfg = _touch_instance.config();
            cfg.i2c_port   = 0;
            cfg.i2c_addr   = 0x15;
            cfg.pin_sda    = 6;
            cfg.pin_scl    = 7;
            cfg.pin_int    = 5;
            cfg.pin_rst    = 13;
            cfg.freq       = 400000;
            _touch_instance.config(cfg);
            _panel_instance.setTouch(&_touch_instance);
        }
        setPanel(&_panel_instance);
    }
};

#endif
INNER

cat << 'INNER' > firmware/src/main.cpp
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
INNER

# ------------------------------------------------------------------------------
# 7. iOS Companion App Blueprint & Swift Core (companion-ios/)
# ------------------------------------------------------------------------------
cat << 'INNER' > companion-ios/README.md
# iOS Background Companion (`RoundDashCompanion`)

## Xcode Setup
1. Create a new iOS App in Xcode (`SwiftUI`, minimum deployment `iOS 16.0`).
2. Enable **Signing & Capabilities -> Background Modes**:
   - `Location updates`
   - `Uses Bluetooth LE accessories`
   - `Background fetch`
3. Add `NSLocationAlwaysAndWhenInUseUsageDescription` and `NSBluetoothAlwaysUsageDescription` to `Info.plist`.
4. Drop `Sources/Protocol.swift`, `Sources/BLEBroadcaster.swift`, and `Sources/MapVectorEngine.swift` into your target.
5. Keep **Flitsmeister** running in the background on your iPhone alongside **Apple CarPlay**—the ESP32 automatically receives Flitsmeister notifications via Apple ANCS while this companion streams live road vectors, speed cameras, NDW closures, and fuel stations over BLE.
INNER

cat << 'INNER' > companion-ios/Sources/Protocol.swift
import Foundation

enum AlertTier: UInt8 {
    case none      = 0
    case speedCam  = 1 // P1: Fixed/mobile speed cam, red-light, trajectcontrole
    case emergency = 2 // P2: Ambulance / emergency vehicle
    case hazard    = 3 // P3: Accident, stationary vehicle, road closure
}

enum PoiType: UInt8 {
    case fixedCam       = 1
    case mobileTrap     = 2
    case trajectcontrole = 3
    case closureHazard  = 4
    case gasStation     = 5
}

struct RoadSegment {
    var x1: Int16
    var y1: Int16
    var x2: Int16
    var y2: Int16
    var flags: UInt8 // bit 0 = current road, bit 1 = closed
}

struct PoiItem {
    var x: Int16
    var y: Int16
    var poiType: PoiType
}

struct BinaryFrameBuilder {
    static func build(scaleCmPerPx: UInt16,
                      alert: AlertTier,
                      roads: [RoadSegment],
                      pois: [PoiItem]) -> Data {
        let clampedRoads = Array(roads.prefix(32))
        let clampedPois  = Array(pois.prefix(16))

        var data = Data()
        data.append(0x01) // msg_type
        withUnsafeBytes(of: scaleCmPerPx.littleEndian) { data.append(contentsOf: $0) }
        data.append(alert.rawValue)
        data.append(UInt8(clampedRoads.count))
        data.append(UInt8(clampedPois.count))

        for r in clampedRoads {
            withUnsafeBytes(of: r.x1.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: r.y1.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: r.x2.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: r.y2.littleEndian) { data.append(contentsOf: $0) }
            data.append(r.flags)
        }

        for p in clampedPois {
            withUnsafeBytes(of: p.x.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: p.y.littleEndian) { data.append(contentsOf: $0) }
            data.append(p.poiType.rawValue)
        }
        return data
    }
}
INNER

cat << 'INNER' > companion-ios/Sources/BLEBroadcaster.swift
import Foundation
import CoreBluetooth

final class BLEBroadcaster: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let serviceUUID = CBUUID(string: "4FAFC201-1FB5-459E-8FCC-C5C9C331914B")
    static let charUUID    = CBUUID(string: "BEB5483E-36E1-4688-B7F5-EA07361B26A8")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var frameChar: CBCharacteristic?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        self.frameChar = nil
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics([Self.charUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        frameChar = service.characteristics?.first(where: { $0.uuid == Self.charUUID })
    }

    func sendFrame(_ data: Data) {
        guard let p = peripheral, let c = frameChar, p.state == .connected else { return }
        p.writeValue(data, for: c, type: .withoutResponse)
    }
}
INNER

cat << 'INNER' > companion-ios/Sources/MapVectorEngine.swift
import Foundation
import CoreLocation

final class MapVectorEngine: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let ble = BLEBroadcaster()
    private var streamTimer: Timer?

    private var latestLocation: CLLocation?
    private var cachedRoads: [(CLLocationCoordinate2D, CLLocationCoordinate2D, Bool)] = []
    private var cachedPois: [(CLLocationCoordinate2D, PoiType)] = []
    private var lastFetchLocation: CLLocation?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.requestAlwaysAuthorization()
        locationManager.startUpdatingLocation()

        // Stream 5 Hz car-relative vector frames over BLE
        streamTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.emitFrame()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        latestLocation = loc

        if lastFetchLocation == nil || loc.distance(from: lastFetchLocation!) > 250 {
            lastFetchLocation = loc
            Task { await refreshNearbyVectors(around: loc.coordinate) }
        }
    }

    private func dynamicScaleCmPerPx(speedMps: Double) -> UInt16 {
        let kmh = max(0, speedMps * 3.6)
        switch kmh {
        case ..<35:   return 100 // ~120m radius
        case ..<65:   return 165 // ~200m radius
        case ..<95:   return 290 // ~350m radius
        default:      return 415 // ~500m radius
        }
    }

    // Projects world lat/lon into car-relative meters (+Y = vehicle heading)
    private func projectToCarMeters(origin: CLLocationCoordinate2D,
                                    headingDeg: Double,
                                    target: CLLocationCoordinate2D) -> (Int16, Int16) {
        let latScale = 111_320.0
        let lonScale = 111_320.0 * cos(origin.latitude * .pi / 180.0)
        let east  = (target.longitude - origin.longitude) * lonScale
        let north = (target.latitude  - origin.latitude)  * latScale

        let rad = headingDeg * .pi / 180.0
        let relX =  east * cos(rad) - north * sin(rad)
        let relY =  east * sin(rad) + north * cos(rad)

        let cx = Int16(max(-600, min(600, Int(relX.rounded()))))
        let cy = Int16(max(-600, min(600, Int(relY.rounded()))))
        return (cx, cy)
    }

    private func emitFrame() {
        guard let loc = latestLocation else { return }
        let heading = loc.course >= 0 ? loc.course : 0
        let scale = dynamicScaleCmPerPx(speedMps: loc.speed)

        let projectedRoads: [RoadSegment] = cachedRoads.map { seg in
            let p1 = projectToCarMeters(origin: loc.coordinate, headingDeg: heading, target: seg.0)
            let p2 = projectToCarMeters(origin: loc.coordinate, headingDeg: heading, target: seg.1)
            return RoadSegment(x1: p1.0, y1: p1.1, x2: p2.0, y2: p2.1, flags: seg.2 ? 0x02 : 0x00)
        }

        let projectedPois: [PoiItem] = cachedPois
            .sorted { $0.0.rawValue < $1.0.rawValue }
            .map { poi in
                let pt = projectToCarMeters(origin: loc.coordinate, headingDeg: heading, target: poi.0)
                return PoiItem(x: pt.0, y: pt.1, poiType: poi.1)
            }

        let packet = BinaryFrameBuilder.build(
            scaleCmPerPx: scale,
            alert: .none,
            roads: projectedRoads,
            pois: projectedPois
        )
        ble.sendFrame(packet)
    }

    private func refreshNearbyVectors(around center: CLLocationCoordinate2D) async {
        // Queries OpenStreetMap Overpass API within 600m for roads, speed cameras, and fuel stations
        let query = """
        [out:json][timeout:10];
        (
          way["highway"~"motorway|trunk|primary|secondary|tertiary|residential"](around:600,\(center.latitude),\(center.longitude));
          node["highway"="speed_camera"](around:600,\(center.latitude),\(center.longitude));
          node["amenity"="fuel"](around:600,\(center.latitude),\(center.longitude));
        );
        out body geom;
        """
        guard let url = URL(string: "https://overpass-api.de/api/interpreter"),
              let body = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")".data(using: .utf8) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let elements = json["elements"] as? [[String: Any]] else { return }

            var newRoads: [(CLLocationCoordinate2D, CLLocationCoordinate2D, Bool)] = []
            var newPois: [(CLLocationCoordinate2D, PoiType)] = []

            for el in elements {
                let type = el["type"] as? String
                let tags = el["tags"] as? [String: String] ?? [:]

                if type == "node", let lat = el["lat"] as? Double, let lon = el["lon"] as? Double {
                    let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    if tags["highway"] == "speed_camera" {
                        newPois.append((coord, .fixedCam))
                    } else if tags["amenity"] == "fuel" {
                        newPois.append((coord, .gasStation))
                    }
                } else if type == "way", let geom = el["geometry"] as? [[String: Double]] {
                    for idx in 0..<max(0, geom.count - 1) {
                        if let lat1 = geom[idx]["lat"], let lon1 = geom[idx]["lon"],
                           let lat2 = geom[idx + 1]["lat"], let lon2 = geom[idx + 1]["lon"] {
                            newRoads.append((
                                CLLocationCoordinate2D(latitude: lat1, longitude: lon1),
                                CLLocationCoordinate2D(latitude: lat2, longitude: lon2),
                                false
                            ))
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                self.cachedRoads = newRoads
                self.cachedPois = newPois
            }
        } catch {
            // Retain previous cached vectors on transient network drop
        }
    }
}
INNER

git init -q
git add .
git commit -q -m "Initial round-dash-copilot Antigravity workspace"
echo "Workspace initialized successfully."
