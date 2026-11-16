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
