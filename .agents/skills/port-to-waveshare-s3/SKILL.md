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
