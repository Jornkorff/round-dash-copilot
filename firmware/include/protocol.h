#pragma once
#include <stdint.h>

#define MAP_SERVICE_UUID        "4FAFC201-1FB5-459E-8FCC-C5C9C331914B"
#define MAP_FRAME_CHAR_UUID     "BEB5483E-36E1-4688-B7F5-EA07361B26A8"

#define MAX_ROAD_SEGMENTS       32
#define MAX_POIS                16

enum AlertTier : uint8_t {
    ALERT_NONE      = 0,
    ALERT_SPEED_CAM = 1, // P1: Fixed/mobile speed cam, red-light, trajectcontrole
    ALERT_EMERGENCY = 2, // P2: Approaching ambulance / emergency vehicle
    ALERT_HAZARD    = 3  // P3: Accident, stationary vehicle, road closure
};

enum PoiType : uint8_t {
    POI_FIXED_CAM       = 1,
    POI_MOBILE_TRAP     = 2,
    POI_TRAJECTCONTROLE = 3,
    POI_CLOSURE_HAZARD  = 4,
    POI_GAS_STATION     = 5
};

enum RoadFlags : uint8_t {
    ROAD_FLAG_CURRENT = 1 << 0,
    ROAD_FLAG_CLOSED  = 1 << 1
};

#pragma pack(push, 1)
struct FrameHeader {
    uint8_t  msg_type;          // 0x01 = Map Frame
    uint16_t scale_cm_per_px;   // Dynamic zoom factor from iPhone speed
    uint8_t  active_alert_type; // AlertTier enum
    uint8_t  road_count;
    uint8_t  poi_count;
};

struct RoadSegment {
    int16_t x1;
    int16_t y1;
    int16_t x2;
    int16_t y2;
    uint8_t flags;
};

struct PoiItem {
    int16_t x;
    int16_t y;
    uint8_t poi_type;
};
#pragma pack(pop)
