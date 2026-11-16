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
