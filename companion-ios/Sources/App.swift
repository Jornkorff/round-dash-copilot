import SwiftUI

@main
struct RoundDashCompanionApp: App {
    @StateObject private var engine = MapVectorEngine()

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine, ble: engine.ble)
        }
    }
}
