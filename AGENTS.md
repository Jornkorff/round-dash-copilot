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
