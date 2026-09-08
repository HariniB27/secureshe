"""
SecureShe Safety API.

The safety score is based primarily on ACTUAL CRIME SPOTS.

Important:
- Complaint latitude/longitude = actual reported crime location.
- Live risk is calculated from complaints near the requested point.
- District baseline is NOT used to determine the crime location.
- District information is optional metadata only.
"""

import math
from datetime import datetime, timezone

from flask import Blueprint, jsonify, request

from app import db
from app.models import Complaint


safety_bp = Blueprint("safety", __name__)


# ============================================================
# CONFIGURATION
# ============================================================

# Crimes within this distance influence the requested point.
LIVE_SEARCH_RADIUS_KM = 2.0

# Recent reports receive more weight than old reports.
RECENCY_HALF_LIFE_DAYS = 14.0

# Controls how quickly multiple nearby crimes increase risk.
LIVE_SATURATION_K = 0.6

# For a road-level safety map, live crime spots should dominate.
W_LIVE = 0.85

# Small historical/background contribution.
W_BASELINE = 0.15


# ============================================================
# DISTANCE
# ============================================================

def haversine_km(lat1, lng1, lat2, lng2):
    """
    Calculate the great-circle distance between two coordinates.
    """

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
    """
    Give newer crime reports greater importance.

    A report loses half of its weight every
    RECENCY_HALF_LIFE_DAYS days.
    """

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
    """
    Try the common timestamp fields used by the Complaint model.

    This keeps the safety calculation compatible with the
    existing project model.
    """

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
    """
    Assign a basic severity multiplier.

    If the Complaint model contains a severity field,
    use it.

    Otherwise every report gets weight 1.0.
    """

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
    """
    Calculate risk using ACTUAL crime coordinates.

    This is the important part of the road-level system.

    A crime closer to the requested point contributes more.
    A recent crime contributes more.
    A severe crime contributes more.
    """

    # Approximate bounding box for a cheap database filter.

    lat_padding = LIVE_SEARCH_RADIUS_KM / 111.0

    # Longitude degrees become smaller toward the poles.
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

        # Remove reports outside the actual radius.
        if distance > LIVE_SEARCH_RADIUS_KM:
            continue

        # Distance weighting.
        #
        # At the crime spot:
        # distance_weight = 1
        #
        # At the edge of the radius:
        # distance_weight approaches 0
        #
        distance_weight = max(
            0.0,
            1.0
            - (
                distance
                / LIVE_SEARCH_RADIUS_KM
            ),
        )

        date_value = (
            get_complaint_datetime(
                complaint
            )
        )

        recent_weight = recency_weight(
            date_value
        )

        severity_weight = (
            complaint_severity(
                complaint
            )
        )

        contribution = (
            distance_weight
            * recent_weight
            * severity_weight
        )

        weighted_count += contribution

        matched_reports.append(
            {
                "id": getattr(
                    complaint,
                    "id",
                    None,
                ),
                "lat": complaint_lat,
                "lng": complaint_lng,
                "distance_km": round(
                    distance,
                    3,
                ),
                "weight": round(
                    contribution,
                    3,
                ),
            }
        )

    # Saturating risk function.
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
    """
    Calculate safety for an EXACT coordinate.

    The location itself is never converted into a district.
    """

    live_risk_value, matched_reports = (
        live_risk(
            lat,
            lng,
        )
    )

    # --------------------------------------------------------
    # Baseline is deliberately neutral.
    #
    # We do NOT use nearest_district here because district
    # centroid/geocoding errors must not affect road-level
    # crime mapping.
    # --------------------------------------------------------

    baseline_risk = 0.0

    combined_risk = (
        W_LIVE * live_risk_value
        + W_BASELINE * baseline_risk
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
        "live_report_count": len(
            matched_reports
        ),
        "nearby_crime_spots": matched_reports,
    }


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