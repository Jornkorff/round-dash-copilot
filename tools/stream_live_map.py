#!/usr/bin/env python3
"""
RoundDash Live Map Streamer (Linux Mint / PC)
Connects directly to the ESP32 CYD over Bluetooth LE and streams real OpenStreetMap
road vectors and POIs around any city or coordinates.
"""

import asyncio
import math
import struct
import sys
import requests
from bleak import BleakClient, BleakScanner

SERVICE_UUID = "4FAFC201-1FB5-459E-8FCC-C5C9C331914B"
CHAR_UUID    = "BEB5483E-36E1-4688-B7F5-EA07361B26A8"

# Default coordinates: Amsterdam Dam Square (or pass lat lon as CLI arguments)
DEFAULT_LAT = 52.3731
DEFAULT_LON = 4.8926

POI_FIXED_CAM       = 1
POI_MOBILE_TRAP     = 2
POI_TRAJECTCONTROLE = 3
POI_CLOSURE_HAZARD  = 4
POI_GAS_STATION     = 5
POI_GARAGE          = 6
POI_EV_CHARGER      = 7
POI_PARKING         = 8

def fetch_osm_data(lat, lon, radius=600):
    print(f"[OSM] Querying Overpass API around ({lat:.4f}, {lon:.4f}) within {radius}m...")
    query = f"""
    [out:json][timeout:15];
    (
      way["highway"~"motorway|trunk|primary|secondary|tertiary|residential"](around:{radius},{lat},{lon});
      node["highway"="speed_camera"](around:{radius},{lat},{lon});
      node["amenity"="fuel"](around:{radius},{lat},{lon});
      node["amenity"="charging_station"](around:{radius},{lat},{lon});
      node["shop"="car_repair"](around:{radius},{lat},{lon});
      node["amenity"="parking"](around:{radius},{lat},{lon});
    );
    out body;
    >;
    out skel qt;
    """
    url = "https://overpass-api.de/api/interpreter"
    resp = requests.post(url, data=query, timeout=20)
    data = resp.json()

    nodes = {}
    for el in data.get("elements", []):
        if el["type"] == "node":
            nodes[el["id"]] = (el["lat"], el["lon"])

    roads = []
    pois = []

    for el in data.get("elements", []):
        if el["type"] == "way":
            w_nodes = el.get("nodes", [])
            for i in range(len(w_nodes) - 1):
                n1 = w_nodes[i]
                n2 = w_nodes[i+1]
                if n1 in nodes and n2 in nodes:
                    roads.append((nodes[n1], nodes[n2]))
        elif el["type"] == "node":
            tags = el.get("tags", {})
            poi_type = None
            if tags.get("highway") == "speed_camera":
                poi_type = POI_FIXED_CAM
            elif tags.get("amenity") == "fuel":
                poi_type = POI_GAS_STATION
            elif tags.get("amenity") == "charging_station":
                poi_type = POI_EV_CHARGER
            elif tags.get("shop") == "car_repair":
                poi_type = POI_GARAGE
            elif tags.get("amenity") == "parking":
                poi_type = POI_PARKING
            if poi_type:
                pois.append(((el["lat"], el["lon"]), poi_type))

    print(f"[OSM] Retrieved {len(roads)} road segments and {len(pois)} POIs.")
    return roads, pois

def project_to_car_meters(origin_lat, origin_lon, heading_deg, target_lat, target_lon):
    lat_scale = 111320.0
    lon_scale = 111320.0 * math.cos(math.radians(origin_lat))
    east = (target_lon - origin_lon) * lon_scale
    north = (target_lat - origin_lat) * lat_scale

    rad = math.radians(heading_deg)
    rel_x = east * math.cos(rad) - north * math.sin(rad)
    rel_y = east * math.sin(rad) + north * math.cos(rad)

    cx = max(-600, min(600, int(round(rel_x))))
    cy = max(-600, min(600, int(round(rel_y))))
    return cx, cy

def build_packet(scale_cm_per_px, alert_tier, projected_roads, projected_pois):
    clamped_roads = projected_roads[:32]
    clamped_pois = projected_pois[:16]

    # Header: msg_type (1B), scale (2B little-endian), alert (1B), road_count (1B), poi_count (1B)
    hdr = struct.pack("<BHBBB", 0x01, scale_cm_per_px, alert_tier, len(clamped_roads), len(clamped_pois))
    body = bytearray()

    for (x1, y1, x2, y2, flags) in clamped_roads:
        body.extend(struct.pack("<hhhhB", x1, y1, x2, y2, flags))

    for (px, py, ptype) in clamped_pois:
        body.extend(struct.pack("<hhB", px, py, ptype))

    return hdr + body

async def run_streamer(lat, lon):
    roads, pois = fetch_osm_data(lat, lon)

    print("[BLE] Scanning for RoundDash-Copilot...")
    device = await BleakScanner.find_device_by_filter(
        lambda d, adv: d.name and "RoundDas" in d.name,
        timeout=10.0
    )
    if not device:
        print("[BLE] Error: RoundDash-Copilot device not found! Ensure ESP32 is powered on.")
        return

    print(f"[BLE] Connecting to {device.name} ({device.address})...")
    async with BleakClient(device) as client:
        print("[BLE] Connected! Streaming live real-world map at 5 Hz...")

        heading = 0.0
        cur_lat = lat
        cur_lon = lon

        # Simulate vehicle driving forward at ~45 km/h
        speed_mps = 12.5 # ~45 km/h
        dt = 0.2

        while True:
            # Move position forward in heading direction
            d_meters = speed_mps * dt
            cur_lat += (d_meters * math.cos(math.radians(heading))) / 111320.0
            cur_lon += (d_meters * math.sin(math.radians(heading))) / (111320.0 * math.cos(math.radians(cur_lat)))
            heading = (heading + 0.3) % 360.0 # gentle curve

            projected_roads = []
            for ((lat1, lon1), (lat2, lon2)) in roads:
                x1, y1 = project_to_car_meters(cur_lat, cur_lon, heading, lat1, lon1)
                x2, y2 = project_to_car_meters(cur_lat, cur_lon, heading, lat2, lon2)
                # Check if in visible radius
                if max(abs(x1), abs(y1), abs(x2), abs(y2)) < 550:
                    flags = 0x01 if (abs(x1) < 20 and y1 > -50 and y2 > 0) else 0x00
                    projected_roads.append((x1, y1, x2, y2, flags))

            projected_pois = []
            for ((plat, plon), ptype) in pois:
                px, py = project_to_car_meters(cur_lat, cur_lon, heading, plat, plon)
                if abs(px) < 500 and abs(py) < 500:
                    projected_pois.append((px, py, ptype))

            scale_cm_per_px = 150
            alert = 0
            # If camera ahead
            for (px, py, ptype) in projected_pois:
                if ptype == POI_FIXED_CAM and 0 < py < 250 and abs(px) < 35:
                    alert = 1
                    break

            packet = build_packet(scale_cm_per_px, alert, projected_roads, projected_pois)
            await client.write_gatt_char(CHAR_UUID, packet, response=False)
            await asyncio.sleep(0.2)

if __name__ == "__main__":
    lat = float(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_LAT
    lon = float(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_LON
    try:
        asyncio.run(run_streamer(lat, lon))
    except KeyboardInterrupt:
        print("\n[BLE] Stopped.")
