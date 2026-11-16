---
trigger: glob
globs: ["firmware/**"]
---

# Embedded Firmware Rules (ESP32 CYD & Waveshare S3)
- Keep RAM usage compatible with classic `ESP32-WROOM-32` (520 KB SRAM, NO PSRAM) during Phase 1: always use `NimBLE-Arduino` (never Bluedroid) and an LVGL partial draw buffer (`240 * 20` pixels in internal DRAM).
- All trigonometric rotation and lat/lon-to-meter projection is performed on the iPhone. Firmware receives car-relative `(x, y)` meter coordinates (`+Y` = forward heading) and scales them directly to pixels using `scale_cm_per_px`.
- Maintain strict separation between hardware pin/driver setup (`include/board_config.h`), binary BLE wire structs (`include/protocol.h`), and LVGL rendering (`src/main.cpp`).
- Never add audio outputs, buzzer PWM code, or pulsing/blinking LVGL animations.
