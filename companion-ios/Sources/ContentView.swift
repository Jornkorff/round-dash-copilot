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

                // Live Minimap Preview + Telemetry Card
                HStack(spacing: 16) {
                    // 130x130 Live Vector Minimap Preview (mirrors CYD 240x240 display)
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.035, green: 0.05, blue: 0.09))
                        Canvas { ctx, size in
                            let cx = size.width * 0.5
                            let cy = size.height * (145.0 / 240.0)
                            let scaleRatio = size.width / 240.0
                            let cmPerPx = Double(max(20, engine.currentScaleCmPerPx))

                            for r in engine.previewRoads {
                                let x1 = cx + (Double(r.x1) * 10.0 / cmPerPx) * scaleRatio
                                let y1 = cy - (Double(r.y1) * 10.0 / cmPerPx) * scaleRatio
                                let x2 = cx + (Double(r.x2) * 10.0 / cmPerPx) * scaleRatio
                                let y2 = cy - (Double(r.y2) * 10.0 / cmPerPx) * scaleRatio
                                var path = Path()
                                path.move(to: CGPoint(x: x1, y: y1))
                                path.addLine(to: CGPoint(x: x2, y: y2))

                                let isCur = (r.flags & 0x01) != 0
                                let isClosed = (r.flags & 0x02) != 0
                                let isMajor = (r.flags & 0x04) != 0

                                let color: Color = isClosed ? .red : (isCur ? .cyan : (isMajor ? Color(white: 0.88) : Color(red: 0.58, green: 0.64, blue: 0.72)))
                                let width: CGFloat = (isCur || isMajor) ? 3.5 : 2.5
                                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                            }
                            // Car marker
                            var car = Path()
                            car.move(to: CGPoint(x: cx, y: cy - 6))
                            car.addLine(to: CGPoint(x: cx + 4.5, y: cy + 5))
                            car.addLine(to: CGPoint(x: cx, y: cy + 2))
                            car.addLine(to: CGPoint(x: cx - 4.5, y: cy + 5))
                            car.closeSubpath()
                            ctx.fill(car, with: .color(.cyan))
                        }
                        .clipShape(Circle())
                        Circle()
                            .stroke(Color(red: 0.12, green: 0.16, blue: 0.23), lineWidth: 2)
                    }
                    .frame(width: 130, height: 130)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(Int(engine.speedKmh))")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Text("km/h")
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                            Spacer()
                            Text("\(Int(engine.headingDeg))°")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundColor(.cyan)
                        }
                        Divider().background(Color.white.opacity(0.1))
                        Text("Streets: \(engine.activeRoadCount) segs")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text("POIs: \(engine.activePoiCount) markers")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
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
