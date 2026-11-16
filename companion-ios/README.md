# iOS Background Companion (`RoundDashCompanion`)

## Option A: Automated Cloud Build (No Mac Required)
1. Push the repository to GitHub (`https://github.com/Jornkorff/round-dash-copilot`).
2. GitHub Actions ([`.github/workflows/build_ios.yml`](../.github/workflows/build_ios.yml)) automatically runs `xcodegen` ([`project.yml`](project.yml)) and `xcodebuild` on a cloud macOS runner to produce `RoundDashCompanion.ipa`.
3. Download the `RoundDashCompanion-IPA` artifact from the **Actions** tab on GitHub and install it onto your iPhone using **Sideloadly** or **SideStore** with your free Apple ID.

## Option B: Local Xcode Setup
1. Create a new iOS App in Xcode (`SwiftUI`, minimum deployment `iOS 16.0`), or run `xcodegen generate` in this folder.
2. Enable **Signing & Capabilities -> Background Modes**:
   - `Location updates`
   - `Uses Bluetooth LE accessories`
   - `Background fetch`
3. Add `NSLocationAlwaysAndWhenInUseUsageDescription` and `NSBluetoothAlwaysUsageDescription` to `Info.plist`.
4. Drop `Sources/Protocol.swift`, `Sources/BLEBroadcaster.swift`, and `Sources/MapVectorEngine.swift` into your target.
5. Keep **Flitsmeister** running in the background on your iPhone alongside **Apple CarPlay**—the ESP32 automatically receives Flitsmeister notifications via Apple ANCS while this companion streams live road vectors, speed cameras, NDW closures, and fuel stations over BLE.
