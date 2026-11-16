import SwiftUI

struct ContentView: View {
    @ObservedObject var engine: MapVectorEngine
    @ObservedObject var ble: BLEBroadcaster

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.06, blue: 0.11)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RoundDash Copilot")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text("CarPlay Coexistent BLE Streamer")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(red: 0.4, green: 0.47, blue: 0.58))
                    }
                    Spacer()
                    Circle()
                        .fill(ble.isConnected ? Color.green : Color.orange)
                        .frame(width: 12, height: 12)
                        .shadow(color: ble.isConnected ? .green : .orange, radius: 6)
                }
                .padding(.horizontal)
                .padding(.top, 16)

                // BLE Status Card
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: ble.isConnected ? "antenna.radiowaves.left.and.right" : "rays")
                            .foregroundColor(ble.isConnected ? .green : .orange)
                            .font(.system(size: 20))
                        Text(ble.peripheralName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Text(ble.isConnected ? "LIVE" : "WAITING")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(ble.isConnected ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                            .foregroundColor(ble.isConnected ? .green : .orange)
                            .cornerRadius(6)
                    }

                    Divider().background(Color.white.opacity(0.1))

                    HStack {
                        Text("Frames Streamed:")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                        Spacer()
                        Text("\(ble.packetsSent) pkts (~5 Hz)")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.cyan)
                    }
                }
                .padding()
                .background(Color(red: 0.07, green: 0.10, blue: 0.17))
                .cornerRadius(16)
                .padding(.horizontal)

                // Navigation Telemetry Card
                VStack(spacing: 16) {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading) {
                            Text("Speed")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.gray)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(Int(engine.speedKmh))")
                                    .font(.system(size: 36, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                Text("km/h")
                                    .font(.system(size: 14))
                                    .foregroundColor(.gray)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("Heading")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.gray)
                            Text("\(Int(engine.headingDeg))°")
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                                .foregroundColor(.cyan)
                        }
                    }

                    Divider().background(Color.white.opacity(0.1))

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Roads in View")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                            Text("\(engine.activeRoadCount) segments")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Nearby POIs")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                            Text("\(engine.activePoiCount) markers")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding()
                .background(Color(red: 0.07, green: 0.10, blue: 0.17))
                .cornerRadius(16)
                .padding(.horizontal)

                // Background & Data Status Card
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "map.fill")
                            .foregroundColor(.cyan)
                        Text("Data Source")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Text("OSM + NDW")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.cyan)
                    }

                    Text(engine.statusMessage)
                        .font(.system(size: 13))
                        .foregroundColor(Color(red: 0.6, green: 0.68, blue: 0.78))

                    HStack(spacing: 6) {
                        Image(systemName: "car.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 12))
                        Text("Apple CarPlay Wireless Safe (No Hotspot Used)")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                    }
                    .padding(.top, 4)
                }
                .padding()
                .background(Color(red: 0.07, green: 0.10, blue: 0.17))
                .cornerRadius(16)
                .padding(.horizontal)

                Spacer()

                Text("Keep this app open in the background while driving.\nFlitsmeister notifications and vector map will stream automatically.")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundColor(Color.gray.opacity(0.8))
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
    }
}
