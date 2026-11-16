import Foundation

enum AlertTier: UInt8 {
    case none      = 0
    case speedCam  = 1 // P1: Fixed/mobile speed cam, red-light, trajectcontrole
    case emergency = 2 // P2: Ambulance / emergency vehicle
    case hazard    = 3 // P3: Accident, stationary vehicle, road closure
}

enum PoiType: UInt8 {
    case fixedCam        = 1
    case mobileTrap      = 2
    case trajectcontrole = 3
    case closureHazard   = 4
    case gasStation      = 5
    case garage          = 6
    case evCharger       = 7
    case parking         = 8
}

struct RoadSegment {
    var x1: Int16
    var y1: Int16
    var x2: Int16
    var y2: Int16
    var flags: UInt8 // bit 0 = current road (0x01), bit 1 = closed (0x02), bit 2 = major road (0x04)
}

struct PoiItem {
    var x: Int16
    var y: Int16
    var poiType: PoiType
}

struct BinaryFrameBuilder {
    static let maxTotalRoads = 140
    static let roadsPerChunk = 20
    static let maxPois       = 10

    /// Builds chunked BLE packets (msg_type = 0x02, max 238 bytes/chunk) carrying up to 140 road segments (in 0.1m decimeters) and 10 POIs
    static func buildChunks(scaleCmPerPx: UInt16,
                            alert: AlertTier,
                            roads: [RoadSegment],
                            pois: [PoiItem]) -> [Data] {
        let clampedRoads = Array(roads.prefix(maxTotalRoads))
        let clampedPois  = Array(pois.prefix(maxPois))

        let totalChunks = max(1, (clampedRoads.count + roadsPerChunk - 1) / roadsPerChunk)
        var packets: [Data] = []

        for chunkIdx in 0..<totalChunks {
            let start = chunkIdx * roadsPerChunk
            let end = min(clampedRoads.count, start + roadsPerChunk)
            let chunkRoads = (start < end) ? Array(clampedRoads[start..<end]) : []
            let chunkPois = (chunkIdx == 0) ? clampedPois : []

            var data = Data()
            data.append(0x02) // msg_type = 0x02 (Chunked Map Frame)
            withUnsafeBytes(of: scaleCmPerPx.littleEndian) { data.append(contentsOf: $0) }
            data.append(alert.rawValue)
            data.append(UInt8(chunkIdx))
            data.append(UInt8(totalChunks))
            data.append(UInt8(chunkRoads.count))
            data.append(UInt8(chunkPois.count))

            for r in chunkRoads {
                withUnsafeBytes(of: r.x1.littleEndian) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: r.y1.littleEndian) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: r.x2.littleEndian) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: r.y2.littleEndian) { data.append(contentsOf: $0) }
                data.append(r.flags)
            }

            for p in chunkPois {
                withUnsafeBytes(of: p.x.littleEndian) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: p.y.littleEndian) { data.append(contentsOf: $0) }
                data.append(p.poiType.rawValue)
            }

            packets.append(data)
        }

        return packets
    }
}
