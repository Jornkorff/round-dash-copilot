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
