import Foundation
import CoreLocation

final class MapVectorEngine: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let ble = BLEBroadcaster()
    private var streamTimer: Timer?

    private var latestLocation: CLLocation?
    private var cachedRoads: [(CLLocationCoordinate2D, CLLocationCoordinate2D, Bool)] = []
    private var cachedPois: [(CLLocationCoordinate2D, PoiType)] = []
    private var lastFetchLocation: CLLocation?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.requestAlwaysAuthorization()
        locationManager.startUpdatingLocation()

        // Stream 5 Hz car-relative vector frames over BLE
        streamTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.emitFrame()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        latestLocation = loc

        if lastFetchLocation == nil || loc.distance(from: lastFetchLocation!) > 250 {
            lastFetchLocation = loc
            Task { await refreshNearbyVectors(around: loc.coordinate) }
        }
    }

    private func dynamicScaleCmPerPx(speedMps: Double) -> UInt16 {
        let kmh = max(0, speedMps * 3.6)
        switch kmh {
        case ..<35:   return 100 // ~120m radius
        case ..<65:   return 165 // ~200m radius
        case ..<95:   return 290 // ~350m radius
        default:      return 415 // ~500m radius
        }
    }

    // Projects world lat/lon into car-relative meters (+Y = vehicle heading)
    private func projectToCarMeters(origin: CLLocationCoordinate2D,
                                    headingDeg: Double,
                                    target: CLLocationCoordinate2D) -> (Int16, Int16) {
        let latScale = 111_320.0
        let lonScale = 111_320.0 * cos(origin.latitude * .pi / 180.0)
        let east  = (target.longitude - origin.longitude) * lonScale
        let north = (target.latitude  - origin.latitude)  * latScale

        let rad = headingDeg * .pi / 180.0
        let relX =  east * cos(rad) - north * sin(rad)
        let relY =  east * sin(rad) + north * cos(rad)

        let cx = Int16(max(-600, min(600, Int(relX.rounded()))))
        let cy = Int16(max(-600, min(600, Int(relY.rounded()))))
        return (cx, cy)
    }

    private func emitFrame() {
        guard let loc = latestLocation else { return }
        let heading = loc.course >= 0 ? loc.course : 0
        let scale = dynamicScaleCmPerPx(speedMps: loc.speed)

        let projectedRoads: [RoadSegment] = cachedRoads.map { seg in
            let p1 = projectToCarMeters(origin: loc.coordinate, headingDeg: heading, target: seg.0)
            let p2 = projectToCarMeters(origin: loc.coordinate, headingDeg: heading, target: seg.1)
            return RoadSegment(x1: p1.0, y1: p1.1, x2: p2.0, y2: p2.1, flags: seg.2 ? 0x02 : 0x00)
        }

        let projectedPois: [PoiItem] = cachedPois
            .sorted { $0.0.rawValue < $1.0.rawValue }
            .map { poi in
                let pt = projectToCarMeters(origin: loc.coordinate, headingDeg: heading, target: poi.0)
                return PoiItem(x: pt.0, y: pt.1, poiType: poi.1)
            }

        let packet = BinaryFrameBuilder.build(
            scaleCmPerPx: scale,
            alert: .none,
            roads: projectedRoads,
            pois: projectedPois
        )
        ble.sendFrame(packet)
    }

    private func refreshNearbyVectors(around center: CLLocationCoordinate2D) async {
        // Queries OpenStreetMap Overpass API within 600m for roads, speed cameras, and fuel stations
        let query = """
        [out:json][timeout:10];
        (
          way["highway"~"motorway|trunk|primary|secondary|tertiary|residential"](around:600,\(center.latitude),\(center.longitude));
          node["highway"="speed_camera"](around:600,\(center.latitude),\(center.longitude));
          node["amenity"="fuel"](around:600,\(center.latitude),\(center.longitude));
        );
        out body geom;
        """
        guard let url = URL(string: "https://overpass-api.de/api/interpreter"),
              let body = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")".data(using: .utf8) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let elements = json["elements"] as? [[String: Any]] else { return }

            var newRoads: [(CLLocationCoordinate2D, CLLocationCoordinate2D, Bool)] = []
            var newPois: [(CLLocationCoordinate2D, PoiType)] = []

            for el in elements {
                let type = el["type"] as? String
                let tags = el["tags"] as? [String: String] ?? [:]

                if type == "node", let lat = el["lat"] as? Double, let lon = el["lon"] as? Double {
                    let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    if tags["highway"] == "speed_camera" {
                        newPois.append((coord, .fixedCam))
                    } else if tags["amenity"] == "fuel" {
                        newPois.append((coord, .gasStation))
                    }
                } else if type == "way", let geom = el["geometry"] as? [[String: Double]] {
                    for idx in 0..<max(0, geom.count - 1) {
                        if let lat1 = geom[idx]["lat"], let lon1 = geom[idx]["lon"],
                           let lat2 = geom[idx + 1]["lat"], let lon2 = geom[idx + 1]["lon"] {
                            newRoads.append((
                                CLLocationCoordinate2D(latitude: lat1, longitude: lon1),
                                CLLocationCoordinate2D(latitude: lat2, longitude: lon2),
                                false
                            ))
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                self.cachedRoads = newRoads
                self.cachedPois = newPois
            }
        } catch {
            // Retain previous cached vectors on transient network drop
        }
    }
}
