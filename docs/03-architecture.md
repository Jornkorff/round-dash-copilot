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
