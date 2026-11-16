import Foundation
import CoreLocation

struct RawRoadSegment {
    let start: CLLocationCoordinate2D
    let end: CLLocationCoordinate2D
    let wayId: Int64
    let isClosed: Bool
    let isMajor: Bool
}

final class MapVectorEngine: NSObject, ObservableObject, CLLocationManagerDelegate {
    let ble = BLEBroadcaster()
    private let locationManager = CLLocationManager()
    private var streamTimer: Timer?

    @Published var speedKmh: Double = 0.0
    @Published var headingDeg: Double = 0.0
    @Published var latitude: Double = 0.0
    @Published var longitude: Double = 0.0
    @Published var activeRoadCount: Int = 0
    @Published var activePoiCount: Int = 0
    @Published var currentScaleCmPerPx: UInt16 = 90
    @Published var previewRoads: [RoadSegment] = []
    @Published var statusMessage: String = "Waiting for GPS fix..."

    private var latestLocation: CLLocation?
    private var lastValidHeading: Double = 0.0
    private var cachedRoads: [RawRoadSegment] = []
    private var cachedPois: [(CLLocationCoordinate2D, PoiType)] = []
    private var lastFetchLocation: CLLocation?
    private var isFetching: Bool = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.requestAlwaysAuthorization()
        locationManager.startUpdatingLocation()

        // Stream 4 Hz car-relative vector frames over BLE
        streamTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.emitFrame()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        latestLocation = loc

        if loc.course >= 0 && loc.speed >= 1.0 {
            lastValidHeading = loc.course
        }

        if !isFetching && (lastFetchLocation == nil || loc.distance(from: lastFetchLocation!) > 120 || cachedRoads.isEmpty) {
            lastFetchLocation = loc
            Task { await refreshNearbyVectors(around: loc.coordinate) }
        }
    }

    private func dynamicScaleCmPerPx(speedMps: Double) -> UInt16 {
        let kmh = max(0, speedMps * 3.6)
        switch kmh {
        case ..<35:   return 90  // ~110m radius (clear game/car street minimap)
        case ..<60:   return 130 // ~155m radius (city arterial)
        case ..<90:   return 200 // ~240m radius (provincial road)
        default:      return 300 // ~360m radius (motorway)
        }
    }

    // Projects world lat/lon into car-relative decimeters (0.1m units, +Y = vehicle heading)
    // Using 0.1m (10cm) units in Int16 preserves exact curve/roundabout shapes up to +-3,000m without angle-clipping
    private func projectToCarDecimeters(origin: CLLocationCoordinate2D,
                                        headingDeg: Double,
                                        target: CLLocationCoordinate2D) -> (Int16, Int16) {
        let latScale = 111_320.0
        let lonScale = 111_320.0 * cos(origin.latitude * .pi / 180.0)
        let eastMeters  = (target.longitude - origin.longitude) * lonScale
        let northMeters = (target.latitude  - origin.latitude)  * latScale

        let rad = headingDeg * .pi / 180.0
        let relX_dm = (eastMeters * cos(rad) - northMeters * sin(rad)) * 10.0
        let relY_dm = (eastMeters * sin(rad) + northMeters * cos(rad)) * 10.0

        let cx = Int16(max(-30000, min(30000, Int(relX_dm.rounded()))))
        let cy = Int16(max(-30000, min(30000, Int(relY_dm.rounded()))))
        return (cx, cy)
    }

    // Point-to-segment squared distance (in decimeters^2) from car origin (0,0)
    private func distSqToOrigin(x1: Int16, y1: Int16, x2: Int16, y2: Int16) -> Double {
        let ax = Double(x1), ay = Double(y1)
        let bx = Double(x2), by = Double(y2)
        let dx = bx - ax, dy = by - ay
        let lenSq = dx * dx + dy * dy
        if lenSq < 1.0 {
            return ax * ax + ay * ay
        }
        let t = max(0.0, min(1.0, -(ax * dx + ay * dy) / lenSq))
        let px = ax + t * dx
        let py = ay + t * dy
        return px * px + py * py
    }

    private func emitFrame() {
        guard let loc = latestLocation else { return }
        let heading = (loc.course >= 0 && loc.speed >= 1.0) ? loc.course : lastValidHeading
        let scale = dynamicScaleCmPerPx(speedMps: loc.speed)

        // Maximum visible distance from car in decimeters (165 px * scale_cm_per_px / 10 cm_per_dm)
        let maxVisibleDm = Double(scale) * 18.0
        let maxVisibleDistSq = maxVisibleDm * maxVisibleDm

        struct ProjectedWithMeta {
            var seg: RoadSegment
            let wayId: Int64
            let distSq: Double
        }

        var items: [ProjectedWithMeta] = []
        items.reserveCapacity(cachedRoads.count)

        for raw in cachedRoads {
            let p1 = projectToCarDecimeters(origin: loc.coordinate, headingDeg: heading, target: raw.start)
            let p2 = projectToCarDecimeters(origin: loc.coordinate, headingDeg: heading, target: raw.end)
            let dsq = distSqToOrigin(x1: p1.0, y1: p1.1, x2: p2.0, y2: p2.1)
            if dsq <= maxVisibleDistSq {
                var flags: UInt8 = 0
                if raw.isClosed { flags |= 0x02 }
                if raw.isMajor  { flags |= 0x04 }
                items.append(ProjectedWithMeta(
                    seg: RoadSegment(x1: p1.0, y1: p1.1, x2: p2.0, y2: p2.1, flags: flags),
                    wayId: raw.wayId,
                    distSq: dsq
                ))
            }
        }

        // Sort by closest distance to the vehicle (0,0) so the nearest 140 road segments are streamed
        items.sort { $0.distSq < $1.distSq }

        // Highlight all segments belonging to the current street (closest wayId to the car)
        if let currentWayId = items.first?.wayId, currentWayId != 0 {
            for i in items.indices {
                if items[i].wayId == currentWayId && (items[i].seg.flags & 0x02 == 0) {
                    items[i].seg.flags |= 0x01
                }
            }
        }

        let projectedRoads = Array(items.prefix(BinaryFrameBuilder.maxTotalRoads)).map { $0.seg }

        let projectedPois: [PoiItem] = cachedPois
            .map { poi in
                let pt = projectToCarDecimeters(origin: loc.coordinate, headingDeg: heading, target: poi.0)
                return PoiItem(x: pt.0, y: pt.1, poiType: poi.1)
            }
            .sorted { a, b in
                let da = Double(a.x) * Double(a.x) + Double(a.y) * Double(a.y)
                let db = Double(b.x) * Double(b.x) + Double(b.y) * Double(b.y)
                return da < db
            }

        var activeAlert: AlertTier = .none
        let hasSpeedCamAhead = projectedPois.contains { poi in
            (poi.poiType == .fixedCam || poi.poiType == .mobileTrap || poi.poiType == .trajectcontrole) &&
            poi.y > 0 && poi.y < 3500 && abs(poi.x) < 500
        }
        let hasClosureAhead = projectedRoads.contains { r in
            (r.flags & 0x02 != 0) && ((r.y1 > 0 && r.y1 < 3000) || (r.y2 > 0 && r.y2 < 3000))
        } || projectedPois.contains { poi in
            poi.poiType == .closureHazard && poi.y > 0 && poi.y < 3000 && abs(poi.x) < 500
        }

        if hasSpeedCamAhead {
            activeAlert = .speedCam
        } else if hasClosureAhead {
            activeAlert = .hazard
        }

        let packets = BinaryFrameBuilder.buildChunks(
            scaleCmPerPx: scale,
            alert: activeAlert,
            roads: projectedRoads,
            pois: projectedPois
        )
        for pkt in packets {
            ble.sendFrame(pkt)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.speedKmh = max(0, loc.speed * 3.6)
            self.headingDeg = heading
            self.latitude = loc.coordinate.latitude
            self.longitude = loc.coordinate.longitude
            self.activeRoadCount = projectedRoads.count
            self.activePoiCount = min(projectedPois.count, BinaryFrameBuilder.maxPois)
            self.currentScaleCmPerPx = scale
            self.previewRoads = projectedRoads
        }
    }

    private func refreshNearbyVectors(around center: CLLocationCoordinate2D) async {
        DispatchQueue.main.async {
            self.isFetching = true
            self.statusMessage = "Fetching OSM & NDW road vectors..."
        }
        async let osmResult = fetchOsmVectors(around: center)
        async let ndwResult = fetchNdwClosures(around: center)

        let (osmRoads, osmPois) = await osmResult
        let (ndwRoads, ndwPois) = await ndwResult

        let mergedRoads = osmRoads + ndwRoads
        let mergedPois = osmPois + ndwPois

        DispatchQueue.main.async {
            self.isFetching = false
            if !mergedRoads.isEmpty {
                self.cachedRoads = mergedRoads
                self.cachedPois = mergedPois
                self.statusMessage = "Live (\(mergedRoads.count) road segments, \(mergedPois.count) POIs)"
            } else if self.cachedRoads.isEmpty {
                self.statusMessage = "Retrying OSM road fetch..."
            }
        }
    }

    // Queries OpenStreetMap Overpass API within 350m for all drivable Dutch street classes + POIs
    private func fetchOsmVectors(around center: CLLocationCoordinate2D) async -> ([RawRoadSegment], [(CLLocationCoordinate2D, PoiType)]) {
        let query = """
        [out:json][timeout:10];
        (
          way["highway"~"^(motorway|motorway_link|trunk|trunk_link|primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|unclassified|residential|living_street)$"](around:350,\(center.latitude),\(center.longitude));
          node["highway"="speed_camera"](around:500,\(center.latitude),\(center.longitude));
          node["amenity"="fuel"](around:500,\(center.latitude),\(center.longitude));
          node["amenity"="charging_station"](around:500,\(center.latitude),\(center.longitude));
          node["shop"="car_repair"](around:500,\(center.latitude),\(center.longitude));
          node["amenity"="parking"](around:500,\(center.latitude),\(center.longitude));
        );
        out body geom;
        """

        let endpoints = [
            "https://overpass-api.de/api/interpreter",
            "https://overpass.kumi.systems/api/interpreter",
            "https://maps.mail.ru/osm/tools/overpass/api/interpreter"
        ]

        for endpoint in endpoints {
            guard let url = URL(string: endpoint),
                  let body = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")".data(using: .utf8) else {
                continue
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = body
            req.timeoutInterval = 8
            req.setValue("RoundDashCopilot/1.0", forHTTPHeaderField: "User-Agent")

            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let elements = json["elements"] as? [[String: Any]] else { continue }

                var newRoads: [RawRoadSegment] = []
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
                        let wayId = (el["id"] as? Int64) ?? Int64((el["id"] as? Int) ?? 0)
                        let hw = tags["highway"] ?? ""
                        let isMajor = hw.hasPrefix("motorway") || hw.hasPrefix("trunk") ||
                                      hw.hasPrefix("primary")  || hw.hasPrefix("secondary") ||
                                      hw.hasPrefix("tertiary")

                        for idx in 0..<max(0, geom.count - 1) {
                            if let lat1 = geom[idx]["lat"], let lon1 = geom[idx]["lon"],
                               let lat2 = geom[idx + 1]["lat"], let lon2 = geom[idx + 1]["lon"] {
                                newRoads.append(RawRoadSegment(
                                    start: CLLocationCoordinate2D(latitude: lat1, longitude: lon1),
                                    end: CLLocationCoordinate2D(latitude: lat2, longitude: lon2),
                                    wayId: wayId,
                                    isClosed: false,
                                    isMajor: isMajor
                                ))
                            }
                        }
                    }
                }

                if !newRoads.isEmpty {
                    return (newRoads, newPois)
                }
            } catch {
                continue
            }
        }
        return ([], [])
    }

    /// Fetches live road closures, roadworks, and traffic events from Dutch NDW Open Data (opendata.ndw.nu)
    private func fetchNdwClosures(around center: CLLocationCoordinate2D) async -> ([RawRoadSegment], [(CLLocationCoordinate2D, PoiType)]) {
        guard let url = URL(string: "https://opendata.ndw.nu/gebeurtenissen.geojson") else {
            return ([], [])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ([], [])
            }

            var ndwRoads: [RawRoadSegment] = []
            var ndwPois: [(CLLocationCoordinate2D, PoiType)] = []
            let centerLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)

            if let features = json["features"] as? [[String: Any]] {
                for feat in features {
                    let props = feat["properties"] as? [String: Any] ?? [:]
                    let geom = feat["geometry"] as? [String: Any] ?? [:]
                    let geomType = geom["type"] as? String

                    let situationType = (props["type"] as? String ?? "").lowercased()
                    let situationDesc = (props["description"] as? String ?? "").lowercased()
                    let isClosure = situationType.contains("close") || situationType.contains("afsluit") ||
                                    situationDesc.contains("afgesloten") || situationDesc.contains("dicht") ||
                                    situationType.contains("work") || situationDesc.contains("werkzaamheden")

                    if geomType == "Point", let coords = geom["coordinates"] as? [Double], coords.count >= 2 {
                        let ptCoord = CLLocationCoordinate2D(latitude: coords[1], longitude: coords[0])
                        let ptLoc = CLLocation(latitude: ptCoord.latitude, longitude: ptCoord.longitude)
                        if centerLoc.distance(from: ptLoc) <= 500 {
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
                                if centerLoc.distance(from: pLoc) <= 500 {
                                    ndwRoads.append(RawRoadSegment(
                                        start: coord1,
                                        end: coord2,
                                        wayId: -1,
                                        isClosed: isClosure,
                                        isMajor: false
                                    ))
                                }
                            }
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
