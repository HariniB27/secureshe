import math
from datetime import datetime, timedelta, timezone

from flask import Blueprint, jsonify, request
from flask_jwt_extended import get_jwt_identity, jwt_required

from app import db
from app.models import Complaint, CrimeDistrict


safety_bp = Blueprint("safety", __name__)


# ============================================================
# CONFIGURATION
# ============================================================

LIVE_SEARCH_RADIUS_KM = 2.0

# Historical dataset influence radius.
HISTORICAL_SEARCH_RADIUS_KM = 25.0

RECENCY_HALF_LIFE_DAYS = 14.0

LIVE_SATURATION_K = 0.6

# Historical + live weighting.
W_LIVE = 0.85
W_BASELINE = 0.15


# ============================================================
# DISTANCE
# ============================================================

def haversine_km(lat1, lng1, lat2, lng2):
    earth_radius_km = 6371.0

    lat1_rad = math.radians(lat1)
    lat2_rad = math.radians(lat2)

    delta_lat = math.radians(lat2 - lat1)
    delta_lng = math.radians(lng2 - lng1)

    a = (
        math.sin(delta_lat / 2) ** 2
        + math.cos(lat1_rad)
        * math.cos(lat2_rad)
        * math.sin(delta_lng / 2) ** 2
    )

    return (
        2
        * earth_radius_km
        * math.asin(math.sqrt(a))
    )


# ============================================================
# RECENCY
# ============================================================

def recency_weight(created_at):

    if created_at is None:
        return 1.0

    try:

        if created_at.tzinfo is None:
            created_at = created_at.replace(
                tzinfo=timezone.utc
            )

        now = datetime.now(timezone.utc)

        age_days = max(
            0.0,
            (now - created_at).total_seconds()
            / 86400.0,
        )

        return math.exp(
            -math.log(2)
            * age_days
            / RECENCY_HALF_LIFE_DAYS
        )

    except Exception:
        return 1.0


# ============================================================
# COMPLAINT DATE
# ============================================================

def get_complaint_datetime(complaint):

    for field_name in (
        "created_at",
        "created_on",
        "reported_at",
        "timestamp",
    ):

        value = getattr(
            complaint,
            field_name,
            None,
        )

        if value is not None:
            return value

    return None


# ============================================================
# SEVERITY
# ============================================================

def complaint_severity(complaint):

    value = getattr(
        complaint,
        "severity",
        None,
    )

    if value is None:
        return 1.0

    if isinstance(value, (int, float)):
        return max(
            0.1,
            float(value),
        )

    value = str(value).strip().lower()

    severity_map = {
        "low": 0.5,
        "medium": 1.0,
        "high": 1.5,
        "critical": 2.0,
        "severe": 2.0,
    }

    return severity_map.get(
        value,
        1.0,
    )


# ============================================================
# LIVE CRIME RISK
# ============================================================

def live_risk(lat, lng):

    lat_padding = LIVE_SEARCH_RADIUS_KM / 111.0

    lng_padding = (
        LIVE_SEARCH_RADIUS_KM
        / (
            111.0
            * max(
                0.2,
                math.cos(
                    math.radians(lat)
                ),
            )
        )
    )

    candidates = (
        Complaint.query
        .filter(
            Complaint.latitude.between(
                lat - lat_padding,
                lat + lat_padding,
            ),
            Complaint.longitude.between(
                lng - lng_padding,
                lng + lng_padding,
            ),
        )
        .all()
    )

    weighted_count = 0.0
    matched_reports = []

    for complaint in candidates:

        complaint_lat = getattr(
            complaint,
            "latitude",
            None,
        )

        complaint_lng = getattr(
            complaint,
            "longitude",
            None,
        )

        if (
            complaint_lat is None
            or complaint_lng is None
        ):
            continue

        try:

            complaint_lat = float(
                complaint_lat
            )

            complaint_lng = float(
                complaint_lng
            )

        except (
            TypeError,
            ValueError,
        ):
            continue

        distance = haversine_km(
            lat,
            lng,
            complaint_lat,
            complaint_lng,
        )

        if distance > LIVE_SEARCH_RADIUS_KM:
            continue

        distance_weight = max(
            0.0,
            1.0
            - (
                distance
                / LIVE_SEARCH_RADIUS_KM
            ),
        )

        date_value = get_complaint_datetime(
            complaint
        )

        recent_weight = recency_weight(
            date_value
        )

        severity_weight = complaint_severity(
            complaint
        )

        contribution = (
            distance_weight
            * recent_weight
            * severity_weight
        )

        weighted_count += contribution

        # This list is returned by the PUBLIC /score and /scores/batch, so
        # it carries no internal id and the same ~110 m rounding as
        # /live-reports. Distance is rounded to 0.1 km and weight to 2
        # places so repeated probes can't pin a report down any finer.
        matched_reports.append(
            {
                "lat": round(float(complaint_lat), PUBLIC_COORD_DECIMALS),
                "lng": round(float(complaint_lng), PUBLIC_COORD_DECIMALS),
                "distance_km": round(
                    distance,
                    1,
                ),
                "weight": round(
                    contribution,
                    2,
                ),
            }
        )

    risk = (
        1.0
        - math.exp(
            -LIVE_SATURATION_K
            * weighted_count
        )
    )

    risk = min(
        1.0,
        max(
            0.0,
            risk,
        ),
    )

    return risk, matched_reports


# ============================================================
# HISTORICAL DATASET RISK
# ============================================================

def historical_risk(lat, lng):

    """
    Calculate historical/background risk from the
    CrimeDistrict dataset.

    CrimeDistrict contains district/year totals rather
    than individual crime incidents, so these records
    are NOT returned as individual crime markers.
    """

    lat_padding = HISTORICAL_SEARCH_RADIUS_KM / 111.0

    lng_padding = (
        HISTORICAL_SEARCH_RADIUS_KM
        / (
            111.0
            * max(
                0.2,
                math.cos(
                    math.radians(lat)
                ),
            )
        )
    )

    rows = (
        CrimeDistrict.query
        .filter(
            CrimeDistrict.latitude.between(
                lat - lat_padding,
                lat + lat_padding,
            ),
            CrimeDistrict.longitude.between(
                lng - lng_padding,
                lng + lng_padding,
            ),
        )
        .all()
    )

    if not rows:
        return 0.0

    weighted_crime = 0.0
    total_weight = 0.0

    for row in rows:

        row_lat = row.latitude
        row_lng = row.longitude

        if row_lat is None or row_lng is None:
            continue

        try:

            row_lat = float(row_lat)
            row_lng = float(row_lng)

            crimes = float(
                row.total_crimes or 0
            )

        except (
            TypeError,
            ValueError,
        ):
            continue

        distance = haversine_km(
            lat,
            lng,
            row_lat,
            row_lng,
        )

        if distance > HISTORICAL_SEARCH_RADIUS_KM:
            continue

        # Nearby districts have more influence.
        distance_weight = max(
            0.0,
            1.0
            - (
                distance
                / HISTORICAL_SEARCH_RADIUS_KM
            ),
        )

        if distance_weight <= 0:
            continue

        weighted_crime += (
            crimes
            * distance_weight
        )

        total_weight += distance_weight

    if total_weight == 0:
        return 0.0

    average_crime = (
        weighted_crime
        / total_weight
    )

    # Convert historical crime volume into a
    # bounded risk value.
    #
    # This is deliberately a logarithmic scaling
    # so large district totals do not immediately
    # produce risk = 1.0.

    risk = (
        math.log1p(average_crime)
        / math.log1p(1000.0)
    )

    risk = min(
        1.0,
        max(
            0.0,
            risk,
        ),
    )

    return risk


# ============================================================
# BAND
# ============================================================

def safety_band(score):

    if score >= 70:
        return "green"

    if score >= 40:
        return "yellow"

    return "red"


# ============================================================
# SCORE
# ============================================================

def score_point(lat, lng):

    live_risk_value, matched_reports = (
        live_risk(
            lat,
            lng,
        )
    )

    historical_risk_value = (
        historical_risk(
            lat,
            lng,
        )
    )

    combined_risk = (
        W_LIVE * live_risk_value
        + W_BASELINE * historical_risk_value
    )

    combined_risk = min(
        1.0,
        max(
            0.0,
            combined_risk,
        ),
    )

    safety_score = round(
        100
        * (
            1.0
            - combined_risk
        )
    )

    return {
        "lat": lat,
        "lng": lng,
        "safety_score": safety_score,
        "band": safety_band(
            safety_score
        ),
        "live_risk": round(
            live_risk_value,
            3,
        ),
        "historical_risk": round(
            historical_risk_value,
            3,
        ),
        "live_report_count": len(
            matched_reports
        ),
        "nearby_crime_spots": matched_reports,
    }
# ============================================================
# GET /api/safety/heatmap
# ============================================================

@safety_bp.route("/heatmap", methods=["GET"])
def get_safety_heatmap():

    district = request.args.get("district", "").strip()
    state = request.args.get("state", "").strip()

    if not district:
        return jsonify({
            "error": "district parameter is required"
        }), 400

    # --------------------------------------------------------
    # Get the district's historical coordinate.
    # We use this only to determine the area to search.
    # --------------------------------------------------------

    district_query = CrimeDistrict.query.filter(
        CrimeDistrict.district.ilike(district),
        CrimeDistrict.latitude.isnot(None),
        CrimeDistrict.longitude.isnot(None),
    )

    if state:
        district_query = district_query.filter(
            CrimeDistrict.state.ilike(state)
        )

    district_row = (
        district_query
        .order_by(CrimeDistrict.year.asc())
        .first()
    )

    if not district_row:
        # Unknown district (or no crime data loaded yet): an empty,
        # zero-risk result rather than an error, so clients can render
        # "nothing here" without special-casing a 404.
        return jsonify({
            "district": district,
            "state": state,
            "matched": False,
            "center": None,
            "radius_km": 0,
            "points": [],
            "total_crime_spots": 0,
            "message": "No crime data for this district",
        })

    center_lat = float(district_row.latitude)
    center_lng = float(district_row.longitude)

    # --------------------------------------------------------
    # Search radius around the district.
    # --------------------------------------------------------

    radius_km = 25.0

    lat_padding = radius_km / 111.0

    lng_padding = radius_km / (
        111.0 * max(
            0.2,
            math.cos(math.radians(center_lat))
        )
    )

    # --------------------------------------------------------
    # Get actual complaints with coordinates.
    # --------------------------------------------------------

    complaints = (
        Complaint.query
        .filter(
            Complaint.latitude.isnot(None),
            Complaint.longitude.isnot(None),
            Complaint.latitude.between(
                center_lat - lat_padding,
                center_lat + lat_padding,
            ),
            Complaint.longitude.between(
                center_lng - lng_padding,
                center_lng + lng_padding,
            ),
        )
        .order_by(Complaint.created_at.desc())
        .all()
    )

    points = []

    for complaint in complaints:

        try:
            lat = float(complaint.latitude)
            lng = float(complaint.longitude)
        except (TypeError, ValueError):
            continue

        distance = haversine_km(
            center_lat,
            center_lng,
            lat,
            lng,
        )

        if distance > radius_km:
            continue

        # Recent complaints have more influence.
        recent_weight = recency_weight(
            get_complaint_datetime(complaint)
        )

        severity_weight = complaint_severity(
            complaint
        )

        weight = (
            recent_weight
            * severity_weight
        )

        # ----------------------------------------------------
        # Convert number of nearby crimes into a simple band.
        # ----------------------------------------------------

        if weight < 2:
            risk = "low"
        elif weight < 5:
            risk = "medium"
        elif weight < 10:
            risk = "high"
        else:
            risk = "very_high"

        # PUBLIC endpoint: no internal id, coordinates rounded like
        # /live-reports (~110 m), distance/weight coarsened.
        points.append({
            "lat": round(lat, PUBLIC_COORD_DECIMALS),
            "lng": round(lng, PUBLIC_COORD_DECIMALS),
            "weight": round(weight, 2),
            "distance_km": round(distance, 1),
            "risk": risk,
            "created_at": (
                get_complaint_datetime(complaint).isoformat()
                if get_complaint_datetime(complaint)
                else None
            ),
        })

    return jsonify({
        "district": district,
        "state": state,
        "matched": True,
        "center": {
            "lat": center_lat,
            "lng": center_lng,
        },
        "radius_km": radius_km,
        "points": points,
        "total_crime_spots": len(points),
    })
# ============================================================
# GET /api/safety/score
# ============================================================

@safety_bp.route(
    "/score",
    methods=["GET"],
)
def get_safety_score():

    try:

        lat = float(
            request.args.get(
                "lat"
            )
        )

        lng = float(
            request.args.get(
                "lng"
            )
        )

    except (
        TypeError,
        ValueError,
    ):

        return jsonify(
            {
                "error": (
                    "lat and lng query "
                    "parameters are required "
                    "and must be numeric"
                )
            }
        ), 400

    if not (
        -90 <= lat <= 90
        and -180 <= lng <= 180
    ):

        return jsonify(
            {
                "error": (
                    "Invalid latitude "
                    "or longitude"
                )
            }
        ), 400

    return jsonify(
        score_point(
            lat,
            lng,
        )
    )


# ============================================================
# POST /api/safety/scores/batch
# ============================================================

@safety_bp.route(
    "/scores/batch",
    methods=["POST"],
)
def get_safety_scores_batch():

    body = request.get_json(
        silent=True
    ) or {}

    points = body.get(
        "points",
        [],
    )

    if (
        not isinstance(
            points,
            list,
        )
        or not points
    ):

        return jsonify(
            {
                "error": (
                    "points must be a "
                    "non-empty list of "
                    "{lat, lng}"
                )
            }
        ), 400

    if len(points) > 200:

        return jsonify(
            {
                "error": (
                    "Maximum 200 points "
                    "per request"
                )
            }
        ), 400

    results = []

    for point in points:

        try:

            lat = float(
                point["lat"]
            )

            lng = float(
                point["lng"]
            )

        except (
            KeyError,
            TypeError,
            ValueError,
        ):

            return jsonify(
                {
                    "error": (
                        f"Invalid point: "
                        f"{point}"
                    )
                }
            ), 400

        results.append(
            score_point(
                lat,
                lng,
            )
        )

    return jsonify(
        {
            "results": results
        }
    )

# ============================================================
# MAP FEEDS
# ============================================================
#
# These endpoints are public (no login), so they must never
# expose who reported something or what they wrote. They only
# return a rounded location and a timestamp.

# 3 decimal places is roughly 110 m, so a pin shows the area
# of a report rather than an exact doorstep.
PUBLIC_COORD_DECIMALS = 3

# How far back the live layer looks by default.
LIVE_DEFAULT_HOURS = 24 * 30

# Upper bound so one request can't pull the whole table.
LIVE_MAX_RESULTS = 2000


def _utc_iso(value):
    if value is None:
        return None

    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)

    return value.astimezone(timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )


def _parse_since(raw):
    """Parse an ISO timestamp into a naive UTC datetime.

    Complaint.created_at is stored as naive UTC
    (datetime.utcnow), so comparisons must be naive too.
    """
    if not raw:
        return None

    try:
        value = datetime.fromisoformat(
            raw.strip().replace("Z", "+00:00")
        )
    except ValueError:
        return None

    if value.tzinfo is not None:
        value = value.astimezone(timezone.utc).replace(tzinfo=None)

    return value


def _public_report_feature(complaint, now):
    created = get_complaint_datetime(complaint)

    age_hours = None
    if created is not None:
        created_naive = (
            created.astimezone(timezone.utc).replace(tzinfo=None)
            if created.tzinfo is not None
            else created
        )
        age_hours = round(
            max(0.0, (now - created_naive).total_seconds() / 3600.0),
            1,
        )

    return {
        "type": "Feature",
        "geometry": {
            "type": "Point",
            "coordinates": [
                round(float(complaint.longitude), PUBLIC_COORD_DECIMALS),
                round(float(complaint.latitude), PUBLIC_COORD_DECIMALS),
            ],
        },
        "properties": {
            "id": complaint.id,
            "reported_at": _utc_iso(created),
            "age_hours": age_hours,
            "weight": round(recency_weight(created), 3),
        },
    }


# ============================================================
# GET /api/safety/live-reports
# ============================================================
#
# Recent complaint locations for the live layer of the map.
#
#   ?since=<ISO time>  only reports newer than this. The app
#                      sends back the server_time from its
#                      previous call, so each poll returns only
#                      what is new.
#   ?hours=<n>         look-back window when since is not
#                      given (default 30 days).
#
# Response: GeoJSON FeatureCollection plus server_time.

@safety_bp.route("/live-reports", methods=["GET"])
def get_live_reports():

    # Taken before the query so a report saved while this
    # request runs is picked up by the next poll, not lost.
    now = datetime.utcnow()

    since = _parse_since(request.args.get("since"))

    if since is None:
        try:
            hours = float(request.args.get("hours", LIVE_DEFAULT_HOURS))
        except (TypeError, ValueError):
            hours = LIVE_DEFAULT_HOURS

        hours = min(max(hours, 1.0), 24 * 365)
        since = now - timedelta(hours=hours)
        incremental = False
    else:
        incremental = True

    # Anonymous reports are never listed on the public map. (They still
    # count in the score math, which only publishes a coarse location.)
    complaints = (
        Complaint.query
        .filter(
            Complaint.latitude.isnot(None),
            Complaint.longitude.isnot(None),
            Complaint.created_at > since,
            Complaint.anonymous.isnot(True),
        )
        .order_by(Complaint.created_at.desc())
        .limit(LIVE_MAX_RESULTS)
        .all()
    )

    return jsonify({
        "type": "FeatureCollection",
        "features": [
            _public_report_feature(complaint, now)
            for complaint in complaints
        ],
        "server_time": _utc_iso(now),
        "incremental": incremental,
    })


# ============================================================
# GET /api/safety/crime-points
# ============================================================
#
# Kept for older app builds. Same public-safe output as
# /live-reports (no description or complaint id).

@safety_bp.route("/crime-points", methods=["GET"])
def get_crime_points():
    return get_live_reports()


# ============================================================
# GET /api/safety/historical-crime-points
# ============================================================
#
# One point per district, using that district's most recent
# year in the dataset. (Returning every year stacked the same
# district on top of itself and inflated the cluster counts.)

@safety_bp.route("/historical-crime-points", methods=["GET"])
def get_historical_crime_points():

    rows = CrimeDistrict.query.filter(
        CrimeDistrict.latitude.isnot(None),
        CrimeDistrict.longitude.isnot(None),
        CrimeDistrict.year > 0,
    ).all()

    latest = {}

    for row in rows:
        key = (row.state.strip().lower(), row.district.strip().lower())
        current = latest.get(key)

        if current is None or row.year > current.year:
            latest[key] = row

    features = []
    max_total = max(
        [(row.total_crimes or 0) for row in latest.values()] or [0]
    )

    for row in latest.values():
        total = row.total_crimes or 0

        features.append({
            "type": "Feature",
            "geometry": {
                "type": "Point",
                "coordinates": [
                    row.longitude,
                    row.latitude,
                ],
            },
            "properties": {
                "id": row.id,
                "district": row.district,
                "state": row.state,
                "year": row.year,
                "total_crimes": total,
                # 0..1, relative to the worst district, so the
                # app can colour and size points consistently.
                "intensity": round(total / max_total, 4) if max_total else 0,
            },
        })

    return jsonify({
        "type": "FeatureCollection",
        "features": features,
        "max_total_crimes": max_total,
    })


# ============================================================
# POST /api/safety/route-check
# ============================================================
#
# Scores whole routes, not just points. A route is judged on:
#   * crime: complaints and district data along it (score_point)
#   * environment: how much of it is on main roads vs. isolated
#     tracks, and how much is lit (OpenStreetMap). After dark,
#     lighting and isolation count for more than the crime data.
#
# Body:
#   {
#     "routes": [ {"points": [[lat, lng], ...]}, ... ],   up to 5
#     "hour": 21        local hour on the phone (0-23), optional
#   }
#
# Each route's points should be spread evenly along it (the app
# sends ~30). Response has one result per route, same order.

ROUTE_CHECK_MAX_ROUTES = 5
ROUTE_CHECK_MAX_POINTS = 60
ROUTE_CHECK_CRIME_SAMPLES = 12


def _route_warnings(summary, distance_m, night):
    warnings = []

    if summary is None:
        return warnings

    def km(share):
        return share * distance_m / 1000.0

    isolated_km = km(summary["isolated_share"])
    if isolated_km >= 0.3:
        warnings.append(
            f"About {isolated_km:.1f} km on tracks, paths or quiet back roads"
        )

    if night:
        dark_km = km(summary["unlit_share"])
        if dark_km >= 0.2:
            warnings.append(f"About {dark_km:.1f} km marked as unlit")
        elif summary["lighting"] < 0.4:
            warnings.append("Much of this route is likely poorly lit")

    return warnings


@safety_bp.route("/route-check", methods=["POST"])
def route_check():
    from app import route_environment as env

    body = request.get_json(silent=True) or {}
    raw_routes = body.get("routes")

    if not isinstance(raw_routes, list) or not raw_routes:
        return jsonify({"error": "routes must be a non-empty list"}), 400

    if len(raw_routes) > ROUTE_CHECK_MAX_ROUTES:
        return jsonify({
            "error": f"At most {ROUTE_CHECK_MAX_ROUTES} routes per request"
        }), 400

    hour = body.get("hour")
    try:
        hour = None if hour is None else int(hour) % 24
    except (TypeError, ValueError):
        hour = None

    night = env.is_night(hour)

    routes = []
    for raw in raw_routes:
        try:
            pts = [
                (float(p[0]), float(p[1]))
                for p in (raw.get("points") or [])
            ][:ROUTE_CHECK_MAX_POINTS]
            distance_m = float(raw.get("distance_m") or 0)
        except (TypeError, ValueError, IndexError, AttributeError):
            return jsonify({"error": "Each point must be [lat, lng]"}), 400

        if len(pts) < 2:
            return jsonify({"error": "Each route needs at least 2 points"}), 400

        routes.append((pts, distance_m))

    # One Overpass request for all routes together.
    environment_checked = True
    try:
        all_points = [p for pts, _ in routes for p in pts]
        roads = env.fetch_roads(all_points)
    except Exception as exc:  # network, rate limit, bad response
        print(f"route-check: road data unavailable: {exc}")
        roads = None
        environment_checked = False

    results = []
    for pts, distance_m in routes:
        # Crime: evenly spaced subset of the points.
        step = max(1, len(pts) // ROUTE_CHECK_CRIME_SAMPLES)
        crime_scores = [
            score_point(lat, lng)["safety_score"] for lat, lng in pts[::step]
        ]
        crime = round(sum(crime_scores) / len(crime_scores))
        crime_low = min(crime_scores)

        summary = env.describe_route(pts, roads) if roads is not None else None
        environment = env.environment_score(summary, hour)

        if environment is None:
            overall = crime
        elif night:
            overall = round(0.45 * crime + 0.55 * environment)
        else:
            overall = round(0.6 * crime + 0.4 * environment)

        # One very bad stretch shouldn't be averaged away, and no amount of
        # "no reports" can make an empty, dark track look safe.
        overall = min(overall, crime_low + 30)
        if environment is not None:
            overall = min(overall, environment + (25 if night else 40))

        result = {
            "score": overall,
            "band": safety_band(overall),
            "crime_score": crime,
            "lowest_crime_score": crime_low,
            "environment_score": environment,
            "warnings": _route_warnings(summary, distance_m, night),
        }

        if summary is not None:
            result.update({
                "main_road_pct": round(100 * summary["main_road_share"]),
                "isolated_pct": round(100 * summary["isolated_share"]),
                "lit_pct": round(100 * summary["lit_share"]),
                "unlit_pct": round(100 * summary["unlit_share"]),
            })

        results.append(result)

    return jsonify({
        "results": results,
        "night": night,
        "environment_checked": environment_checked,
    })


# ============================================================
# Community flags  (POST/GET /api/safety/flags)
# ============================================================
#
# Quick map markers from the Safety Map's "Add Community Flag" sheet.
# Posting needs a login; reading is public and, like live reports,
# returns only a rounded position, kind and time (never who posted).

FLAG_KINDS = ("dark-street", "harassment", "suspicious", "safe-zone")
FLAG_DEFAULT_HOURS = 24 * 7

# One person can't carpet an area with flags.
FLAG_LIMIT_PER_HOUR = 10


@safety_bp.route("/flags", methods=["POST"])
@jwt_required()
def add_flag():
    from app.models import CommunityFlag

    body = request.get_json(silent=True) or {}
    kind = (body.get("kind") or "").strip()

    if kind not in FLAG_KINDS:
        return jsonify({"error": f"kind must be one of {', '.join(FLAG_KINDS)}"}), 400

    try:
        lat = float(body.get("lat"))
        lng = float(body.get("lng"))
    except (TypeError, ValueError):
        return jsonify({"error": "lat and lng are required numbers"}), 400

    if not (-90 <= lat <= 90 and -180 <= lng <= 180):
        return jsonify({"error": "Invalid latitude or longitude"}), 400

    user_id = int(get_jwt_identity())
    recent = CommunityFlag.query.filter(
        CommunityFlag.user_id == user_id,
        CommunityFlag.created_at > datetime.utcnow() - timedelta(hours=1),
    ).count()

    if recent >= FLAG_LIMIT_PER_HOUR:
        return jsonify({"error": "Too many flags in the last hour. Try again later."}), 429

    flag = CommunityFlag(user_id=user_id, kind=kind, latitude=lat, longitude=lng)
    db.session.add(flag)
    db.session.commit()

    return jsonify(_flag_feature(flag)), 201


@safety_bp.route("/flags", methods=["GET"])
def list_flags():
    from app.models import CommunityFlag

    try:
        hours = float(request.args.get("hours", FLAG_DEFAULT_HOURS))
    except (TypeError, ValueError):
        hours = FLAG_DEFAULT_HOURS
    hours = min(max(hours, 1.0), 24 * 90)

    flags = (
        CommunityFlag.query
        .filter(CommunityFlag.created_at > datetime.utcnow() - timedelta(hours=hours))
        .order_by(CommunityFlag.created_at.desc())
        .limit(LIVE_MAX_RESULTS)
        .all()
    )

    return jsonify({
        "type": "FeatureCollection",
        "features": [_flag_feature(f) for f in flags],
    })


def _flag_feature(flag):
    return {
        "type": "Feature",
        "geometry": {
            "type": "Point",
            "coordinates": [
                round(flag.longitude, PUBLIC_COORD_DECIMALS),
                round(flag.latitude, PUBLIC_COORD_DECIMALS),
            ],
        },
        "properties": {
            "id": flag.id,
            "kind": flag.kind,
            "reported_at": _utc_iso(flag.created_at),
        },
    }
