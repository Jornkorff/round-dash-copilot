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
