---
trigger: glob
globs: "companion-ios/**"
---

# iOS Companion App Rules (Swift)
- Maintain simultaneous Apple CarPlay compatibility: never require Wi-Fi Hotspot or take exclusive audio session focus.
- Configure `CLLocationManager` for background automotive navigation (`kCLLocationAccuracyBestForNavigation`, `allowsBackgroundLocationUpdates = true`, `pausesLocationUpdatesAutomatically = false`).
- Project all road segments and POIs into car-relative meters (`+Y` aligned with `course` heading) before packing into the binary BLE frame defined in `firmware/include/protocol.h`.
- Enforce the 4-tier POI priority order when truncating packets to fit BLE MTU limits: P1 Speed/Red-Light/Trajectcontrole Cameras > P2 Emergency Vehicles > P3 Road Closures/Accidents/Roadworks > P4 Fuel Stations.
