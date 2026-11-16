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
