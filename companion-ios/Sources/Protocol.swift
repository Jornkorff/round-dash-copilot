import Foundation

enum AlertTier: UInt8 {
    case none      = 0
    case speedCam  = 1 // P1: Fixed/mobile speed cam, red-light, trajectcontrole
    case emergency = 2 // P2: Ambulance / emergency vehicle
    case hazard    = 3 // P3: Accident, stationary vehicle, road closure
}

enum PoiType: UInt8 {
    case fixedCam       = 1
    case mobileTrap     = 2
    case trajectcontrole = 3
    case closureHazard  = 4
    case gasStation     = 5
}

struct RoadSegment {
    var x1: Int16
    var y1: Int16
    var x2: Int16
    var y2: Int16
    var flags: UInt8 // bit 0 = current road, bit 1 = closed
}

struct PoiItem {
    var x: Int16
    var y: Int16
    var poiType: PoiType
}

struct BinaryFrameBuilder {
    static func build(scaleCmPerPx: UInt16,
                      alert: AlertTier,
                      roads: [RoadSegment],
                      pois: [PoiItem]) -> Data {
        let clampedRoads = Array(roads.prefix(32))
        let clampedPois  = Array(pois.prefix(16))

        var data = Data()
        data.append(0x01) // msg_type
        withUnsafeBytes(of: scaleCmPerPx.littleEndian) { data.append(contentsOf: $0) }
        data.append(alert.rawValue)
        data.append(UInt8(clampedRoads.count))
        data.append(UInt8(clampedPois.count))

        for r in clampedRoads {
            withUnsafeBytes(of: r.x1.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: r.y1.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: r.x2.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: r.y2.littleEndian) { data.append(contentsOf: $0) }
            data.append(r.flags)
        }

        for p in clampedPois {
            withUnsafeBytes(of: p.x.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: p.y.littleEndian) { data.append(contentsOf: $0) }
            data.append(p.poiType.rawValue)
        }
        return data
    }
}
