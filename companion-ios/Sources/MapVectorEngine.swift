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
            .sorted { $0.1.rawValue < $1.1.rawValue }
            .map { poi in
                let pt = projectToCarMeters(origin: loc.coordinate, headingDeg: heading, target: poi.0)
                return PoiItem(x: pt.0, y: pt.1, poiType: poi.1)
            }

        // Active Alert Evaluation based on 4-Tier Hierarchy:
        // P1: Speed Cam ahead (forward lookahead 0..350m, within +/-50m corridor)
        // P3: Closure/Roadworks ahead (forward lookahead 0..300m, within +/-40m corridor)
        var activeAlert: AlertTier = .none
        let hasSpeedCamAhead = projectedPois.contains { poi in
            (poi.poiType == .fixedCam || poi.poiType == .mobileTrap || poi.poiType == .trajectcontrole) &&
            poi.y > 0 && poi.y < 350 && abs(poi.x) < 50
        }
        let hasClosureAhead = projectedRoads.contains { r in
            (r.flags & 0x02 != 0) && ((r.y1 > 0 && r.y1 < 300) || (r.y2 > 0 && r.y2 < 300))
        } || projectedPois.contains { poi in
            poi.poiType == .closureHazard && poi.y > 0 && poi.y < 300 && abs(poi.x) < 50
        }

        if hasSpeedCamAhead {
            activeAlert = .speedCam
        } else if hasClosureAhead {
            activeAlert = .hazard
        }

        let packet = BinaryFrameBuilder.build(
            scaleCmPerPx: scale,
            alert: activeAlert,
            roads: projectedRoads,
            pois: projectedPois
        )
        ble.sendFrame(packet)
    }

    private func refreshNearbyVectors(around center: CLLocationCoordinate2D) async {
        async let osmResult = fetchOsmVectors(around: center)
        async let ndwResult = fetchNdwClosures(around: center)

        let (osmRoads, osmPois) = await osmResult
        let (ndwRoads, ndwPois) = await ndwResult

        let mergedRoads = osmRoads + ndwRoads
        let mergedPois = osmPois + ndwPois

        DispatchQueue.main.async {
            self.cachedRoads = mergedRoads
            self.cachedPois = mergedPois
        }
    }

    // Queries OpenStreetMap Overpass API within 600m for roads, cameras, fuel, garages, EV chargers, parking
    private func fetchOsmVectors(around center: CLLocationCoordinate2D) async -> ([(CLLocationCoordinate2D, CLLocationCoordinate2D, Bool)], [(CLLocationCoordinate2D, PoiType)]) {
        let query = """
        [out:json][timeout:10];
        (
          way["highway"~"motorway|trunk|primary|secondary|tertiary|residential"](around:600,\(center.latitude),\(center.longitude));
          node["highway"="speed_camera"](around:600,\(center.latitude),\(center.longitude));
          node["amenity"="fuel"](around:600,\(center.latitude),\(center.longitude));
          node["amenity"="charging_station"](around:600,\(center.latitude),\(center.longitude));
          node["shop"="car_repair"](around:600,\(center.latitude),\(center.longitude));
          node["amenity"="parking"](around:600,\(center.latitude),\(center.longitude));
        );
        out body geom;
        """
        guard let url = URL(string: "https://overpass-api.de/api/interpreter"),
              let body = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")".data(using: .utf8) else {
            return ([], [])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let elements = json["elements"] as? [[String: Any]] else { return ([], []) }

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
                    } else if tags["amenity"] == "charging_station" {
                        newPois.append((coord, .evCharger))
                    } else if tags["shop"] == "car_repair" || tags["amenity"] == "car_repair" {
                        newPois.append((coord, .garage))
                    } else if tags["amenity"] == "parking" {
                        newPois.append((coord, .parking))
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
            return (newRoads, newPois)
        } catch {
            return ([], [])
        }
    }

    /// Fetches live road closures, roadworks, and traffic events from Dutch NDW Open Data (opendata.ndw.nu)
    private func fetchNdwClosures(around center: CLLocationCoordinate2D) async -> ([(CLLocationCoordinate2D, CLLocationCoordinate2D, Bool)], [(CLLocationCoordinate2D, PoiType)]) {
        // NDW live roadworks and traffic events open data feed URL
        guard let url = URL(string: "https://opendata.ndw.nu/gebeurtenissen.geojson") else {
            return ([], [])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
                return ([], [])
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ([], [])
            }

            var ndwRoads: [(CLLocationCoordinate2D, CLLocationCoordinate2D, Bool)] = []
            var ndwPois: [(CLLocationCoordinate2D, PoiType)] = []
            let centerLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)

            // Support GeoJSON FeatureCollection format (used by NDW OTM / GeoJSON export)
            if let features = json["features"] as? [[String: Any]] {
                for feat in features {
                    let props = feat["properties"] as? [String: Any] ?? [:]
                    let geom = feat["geometry"] as? [String: Any] ?? [:]
                    let geomType = geom["type"] as? String

                    // Check for road closure or roadwork keywords in properties
                    let situationType = (props["type"] as? String ?? "").lowercased()
                    let situationDesc = (props["description"] as? String ?? "").lowercased()
                    let isClosure = situationType.contains("close") || situationType.contains("afsluit") ||
                                    situationDesc.contains("afgesloten") || situationDesc.contains("dicht") ||
                                    situationType.contains("work") || situationDesc.contains("werkzaamheden")

                    if geomType == "Point", let coords = geom["coordinates"] as? [Double], coords.count >= 2 {
                        let ptCoord = CLLocationCoordinate2D(latitude: coords[1], longitude: coords[0])
                        let ptLoc = CLLocation(latitude: ptCoord.latitude, longitude: ptCoord.longitude)
                        if centerLoc.distance(from: ptLoc) <= 600 {
                            ndwPois.append((ptCoord, .closureHazard))
                        }
                    } else if geomType == "LineString", let coords = geom["coordinates"] as? [[Double]] {
                        for idx in 0..<max(0, coords.count - 1) {
                            let c1 = coords[idx]
                            let c2 = coords[idx + 1]
                            if c1.count >= 2 && c2.count >= 2 {
                                let coord1 = CLLocationCoordinate2D(latitude: c1[1], longitude: c1[0])
                                let coord2 = CLLocationCoordinate2D(latitude: c2[1], longitude: c2[0])
                                let pLoc = CLLocation(latitude: coord1.latitude, longitude: coord1.longitude)
                                if centerLoc.distance(from: pLoc) <= 600 {
                                    ndwRoads.append((coord1, coord2, isClosure))
                                }
                            }
                        }
                    }
                }
            } else if let events = json["events"] as? [[String: Any]] {
                // Support direct OTM (OpenTripModel) events format
                for ev in events {
                    if let loc = ev["location"] as? [String: Double],
                       let lat = loc["latitude"], let lon = loc["longitude"] {
                        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                        if centerLoc.distance(from: CLLocation(latitude: lat, longitude: lon)) <= 600 {
                            ndwPois.append((coord, .closureHazard))
                        }
                    }
                }
            }

            return (ndwRoads, ndwPois)
        } catch {
            return ([], [])
        }
    }
}
