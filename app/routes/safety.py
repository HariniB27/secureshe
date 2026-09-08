import math
from datetime import datetime, timezone

from flask import Blueprint, jsonify, request

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
        return jsonify({
            "district": district,
            "state": state,
            "points": [],
            "message": "District not found"
        }), 404

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

        points.append({
            "id": complaint.id,
            "lat": lat,
            "lng": lng,
            "weight": round(weight, 3),
            "distance_km": round(distance, 3),
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
# GET /api/safety/crime-points
# Returns individual crime/complaint locations for the map.
# ============================================================

@safety_bp.route("/crime-points", methods=["GET"])
def get_crime_points():

    complaints = Complaint.query.filter(
        Complaint.latitude.isnot(None),
        Complaint.longitude.isnot(None),
    ).all()

    features = []

    for complaint in complaints:

        features.append({
            "type": "Feature",
            "geometry": {
                "type": "Point",
                "coordinates": [
                    complaint.longitude,
                    complaint.latitude,
                ],
            },
            "properties": {
                "id": complaint.id,
                "complaint_id": complaint.complaint_id,
                "description": complaint.description or "",
                "status": complaint.status or "SUBMITTED",
            },
        })

    return jsonify({
        "type": "FeatureCollection",
        "features": features,
    })
# ============================================================
# GET /api/safety/historical-crime-points
# Returns historical crime locations as GeoJSON.
# ============================================================

@safety_bp.route("/historical-crime-points", methods=["GET"])
def get_historical_crime_points():

    rows = CrimeDistrict.query.filter(
        CrimeDistrict.latitude.isnot(None),
        CrimeDistrict.longitude.isnot(None),
        CrimeDistrict.year > 0,
    ).all()

    features = []

    for row in rows:
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
                "total_crimes": row.total_crimes or 0,
                "weight": row.total_crimes or 0,
            },
        })

    return jsonify({
        "type": "FeatureCollection",
        "features": features,
    })