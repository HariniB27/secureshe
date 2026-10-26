"""What a route actually passes through: main road or empty track, lit or not.

Uses OpenStreetMap road data (the `highway` and `lit` tags) fetched from the
public Overpass API. A route with no crime reports can still be the most
dangerous choice if it runs along an isolated, unlit track, so these numbers
are combined with the crime score in routes.py.

OpenStreetMap lighting data is incomplete in many Indian cities, so an
untagged road is not treated as lit. It gets an estimate based on the road
type instead (a main road is usually lit, a field track usually isn't).
"""

import math
import time

import requests


OVERPASS_URL = "https://overpass-api.de/api/interpreter"
# The public Overpass service is often slow. Give it about 8 s in total
# (connect + wait for the answer), then fall back to the crime-only score so
# the app is not left waiting.
OVERPASS_CONNECT_S = 2
OVERPASS_TIMEOUT_S = 6
USER_AGENT = "SecureShe/1.0 (com.secureshe.mobile)"

# How far a route point can be from a road and still count as "on" it.
MATCH_RADIUS_M = 40.0

# How busy / watched a type of road usually is, 0..1.
ROAD_ACTIVITY = {
    "trunk": 1.0,
    "primary": 1.0,
    "secondary": 1.0,
    "tertiary": 0.9,
    "trunk_link": 0.9,
    "primary_link": 0.9,
    "secondary_link": 0.9,
    "tertiary_link": 0.85,
    "residential": 0.75,
    "living_street": 0.7,
    "pedestrian": 0.7,
    "footway": 0.55,
    "unclassified": 0.45,
    "service": 0.4,
    "cycleway": 0.35,
    "steps": 0.3,
    "path": 0.15,
    "track": 0.1,
    "bridleway": 0.1,
}

# Used when a road has no `lit` tag: how likely is it to be lit?
ASSUMED_LIGHTING = {
    "trunk": 0.75,
    "primary": 0.75,
    "secondary": 0.7,
    "tertiary": 0.6,
    "residential": 0.5,
    "living_street": 0.5,
    "pedestrian": 0.6,
    "footway": 0.35,
    "unclassified": 0.3,
    "service": 0.3,
}

MAIN_ROADS = {
    "trunk", "primary", "secondary", "tertiary",
    "trunk_link", "primary_link", "secondary_link", "tertiary_link",
}

ISOLATED_ROADS = {"track", "path", "bridleway", "unclassified", "service"}

# Value for a stretch that isn't near any mapped road.
UNMAPPED_ACTIVITY = 0.1
UNMAPPED_LIGHTING = 0.1

_CACHE = {}
_CACHE_TTL_S = 6 * 3600


# ------------------------------------------------------------------
# Geometry (small distances, so a flat approximation is accurate enough)
# ------------------------------------------------------------------

def _to_xy(lat, lng, lat0):
    x = math.radians(lng) * 6371000.0 * math.cos(math.radians(lat0))
    y = math.radians(lat) * 6371000.0
    return x, y


def _point_segment_m(p, a, b):
    px, py = p
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    length_sq = dx * dx + dy * dy

    if length_sq == 0:
        return math.hypot(px - ax, py - ay)

    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length_sq))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


# ------------------------------------------------------------------
# Overpass
# ------------------------------------------------------------------

def _overpass_query(points):
    """All roads within MATCH_RADIUS_M of the given (lat, lng) points."""
    coords = ",".join(f"{lat:.5f},{lng:.5f}" for lat, lng in points)
    return (
        f"[out:json][timeout:{OVERPASS_TIMEOUT_S}];"
        f'way(around:{int(MATCH_RADIUS_M)},{coords})["highway"];'
        "out tags geom;"
    )


def fetch_roads(points):
    """Road ways near the points, as dicts with 'highway', 'lit', 'geometry'.

    Raises on network/Overpass errors so the caller can fall back.
    """
    key = tuple((round(lat, 4), round(lng, 4)) for lat, lng in points)
    cached = _CACHE.get(key)
    if cached and time.time() - cached[0] < _CACHE_TTL_S:
        return cached[1]

    response = requests.post(
        OVERPASS_URL,
        data={"data": _overpass_query(points)},
        headers={"User-Agent": USER_AGENT},
        timeout=(OVERPASS_CONNECT_S, OVERPASS_TIMEOUT_S),
    )
    response.raise_for_status()

    roads = []
    for element in response.json().get("elements", []):
        tags = element.get("tags") or {}
        geometry = element.get("geometry") or []
        if "highway" not in tags or len(geometry) < 2:
            continue
        roads.append({
            "highway": tags.get("highway"),
            "lit": tags.get("lit"),
            "geometry": [(g["lat"], g["lon"]) for g in geometry],
        })

    _CACHE[key] = (time.time(), roads)
    return roads


# ------------------------------------------------------------------
# Matching route points to roads
# ------------------------------------------------------------------

class RoadIndex:
    """Grid of road segments so each lookup only checks nearby ones."""

    CELL_DEG = 0.002  # about 220 m

    def __init__(self, roads, lat0):
        self.lat0 = lat0
        self.cells = {}

        for road in roads:
            pts = [_to_xy(lat, lng, lat0) for lat, lng in road["geometry"]]
            raw = road["geometry"]

            for i in range(len(pts) - 1):
                segment = (pts[i], pts[i + 1], road)
                lat_a, lng_a = raw[i]
                lat_b, lng_b = raw[i + 1]

                for cx in range(self._cell(min(lng_a, lng_b)) - 1,
                                self._cell(max(lng_a, lng_b)) + 2):
                    for cy in range(self._cell(min(lat_a, lat_b)) - 1,
                                    self._cell(max(lat_a, lat_b)) + 2):
                        self.cells.setdefault((cx, cy), []).append(segment)

    def _cell(self, value):
        return int(math.floor(value / self.CELL_DEG))

    def nearest(self, lat, lng):
        p = _to_xy(lat, lng, self.lat0)
        best_road = None
        best_m = MATCH_RADIUS_M

        for a, b, road in self.cells.get((self._cell(lng), self._cell(lat)), []):
            d = _point_segment_m(p, a, b)
            if d <= best_m:
                best_m = d
                best_road = road

        return best_road


def _lighting_value(road):
    lit = (road.get("lit") or "").strip().lower()

    if lit in ("yes", "24/7", "automatic", "limited", "interval"):
        return 1.0, True
    if lit == "no":
        return 0.0, True

    return ASSUMED_LIGHTING.get(road["highway"], UNMAPPED_LIGHTING), False


def describe_route(points, roads):
    """Summarise what a route passes through.

    points: route points evenly spaced along the route, as (lat, lng).
    Returns shares (0..1) of the route by road type and lighting.
    """
    if not points:
        return None

    lat0 = sum(lat for lat, _ in points) / len(points)
    index = RoadIndex(roads, lat0)

    activity = 0.0
    lighting = 0.0
    main = isolated = lit_known = unlit_known = 0

    for lat, lng in points:
        road = index.nearest(lat, lng)

        if road is None:
            activity += UNMAPPED_ACTIVITY
            lighting += UNMAPPED_LIGHTING
            isolated += 1
            continue

        highway = road["highway"]
        activity += ROAD_ACTIVITY.get(highway, 0.3)

        light, known = _lighting_value(road)
        lighting += light
        if known:
            lit_known += light == 1.0
            unlit_known += light == 0.0

        if highway in MAIN_ROADS:
            main += 1
        elif highway in ISOLATED_ROADS:
            isolated += 1

    n = float(len(points))
    return {
        "activity": activity / n,
        "lighting": lighting / n,
        "main_road_share": main / n,
        "isolated_share": isolated / n,
        "lit_share": lit_known / n,
        "unlit_share": unlit_known / n,
    }


def is_night(hour):
    return hour is not None and (hour >= 19 or hour < 6)


def environment_score(summary, hour):
    """0..100: how busy and well lit the route is. Lighting counts for more
    after dark."""
    if summary is None:
        return None

    if is_night(hour):
        value = 0.5 * summary["activity"] + 0.5 * summary["lighting"]
    else:
        value = 0.8 * summary["activity"] + 0.2 * summary["lighting"]

    return round(100 * max(0.0, min(1.0, value)))
