from datetime import datetime, timedelta

import pytest

from app import db
from app.models import Complaint, CrimeDistrict
from app.routes.safety import safety_band

LAT, LNG = 12.9715987, 77.5945627


def _add_complaint(app, user_id=1, anonymous=False, hours_ago=1, lat=LAT, lng=LNG, cid=None):
    with app.app_context():
        c = Complaint(
            complaint_id=cid or f"T{datetime.utcnow().timestamp():.6f}"[-8:],
            user_id=user_id,
            description="private description",
            evidence_hash="0" * 64,
            latitude=lat,
            longitude=lng,
            category="harassment",
            anonymous=anonymous,
            status="SUBMITTED",
            chain_status="confirmed",
            chain_attempts=1,
            created_at=datetime.utcnow() - timedelta(hours=hours_ago),
        )
        db.session.add(c)
        db.session.commit()
        return c.id


# ---------------------------------------------------------- score bands

@pytest.mark.parametrize("score,band", [
    (100, "green"), (70, "green"),
    (69, "yellow"), (40, "yellow"),
    (39, "red"), (0, "red"),
])
def test_safety_band_edges(score, band):
    assert safety_band(score) == band


def test_score_with_no_data_is_fully_safe(client):
    r = client.get(f"/api/safety/score?lat={LAT}&lng={LNG}")
    assert r.status_code == 200
    body = r.get_json()
    assert body["safety_score"] == 100
    assert body["band"] == "green"


def test_score_rejects_bad_coordinates(client):
    assert client.get("/api/safety/score?lat=abc&lng=1").status_code == 400
    assert client.get("/api/safety/score?lat=91&lng=0").status_code == 400


def test_score_drops_near_reports_and_rounds_public_spots(app, client, auth_headers):
    for i in range(3):
        _add_complaint(app, cid=f"SCORE{i}")
    body = client.get(f"/api/safety/score?lat={LAT}&lng={LNG}").get_json()
    assert body["safety_score"] < 100
    assert body["live_report_count"] == 3
    # The caller's own coordinates come back as sent...
    assert body["lat"] == LAT and body["lng"] == LNG
    # ...but nearby report spots are rounded to 3 decimals.
    for spot in body["nearby_crime_spots"]:
        for key in ("lat", "lng"):
            if key in spot:
                assert round(spot[key], 3) == spot[key]


# --------------------------------------------------------- live reports

def test_live_reports_round_coordinates_and_hide_text(app, client, auth_headers):
    _add_complaint(app, cid="PUBLIC01")
    body = client.get("/api/safety/live-reports?hours=24").get_json()
    assert len(body["features"]) == 1
    feature = body["features"][0]
    lng, lat = feature["geometry"]["coordinates"]
    assert (lat, lng) == (round(LAT, 3), round(LNG, 3))
    assert "description" not in feature["properties"]
    assert "complaint_id" not in feature["properties"]
    assert body["server_time"]


def test_live_reports_exclude_anonymous(app, client, auth_headers):
    _add_complaint(app, anonymous=False, cid="SHOWN001")
    _add_complaint(app, anonymous=True, cid="HIDDEN01")
    features = client.get("/api/safety/live-reports?hours=24").get_json()["features"]
    assert len(features) == 1


def test_live_reports_respect_time_window(app, client, auth_headers):
    _add_complaint(app, hours_ago=0.5, cid="RECENT01")
    _add_complaint(app, hours_ago=48, cid="OLDER001")
    assert len(client.get("/api/safety/live-reports?hours=1").get_json()["features"]) == 1
    assert len(client.get("/api/safety/live-reports?hours=72").get_json()["features"]) == 2


# -------------------------------------------------------------- heatmap

def test_heatmap_unknown_district_is_empty_not_404(client):
    r = client.get("/api/safety/heatmap?district=Nowhere")
    assert r.status_code == 200
    body = r.get_json()
    assert body["matched"] is False
    assert body["points"] == []
    assert body["total_crime_spots"] == 0


def test_heatmap_requires_district(client):
    assert client.get("/api/safety/heatmap").status_code == 400


def test_heatmap_known_district(app, client, auth_headers):
    with app.app_context():
        db.session.add(CrimeDistrict(state="Karnataka", district="Bengaluru City",
                                     year=2015, latitude=LAT, longitude=LNG, total_crimes=100))
        db.session.commit()
    _add_complaint(app, cid="HEAT0001")
    body = client.get("/api/safety/heatmap?district=bengaluru city").get_json()
    assert body["matched"] is True
    assert body["total_crime_spots"] == 1


def test_historical_points_from_loaded_districts(app, client):
    with app.app_context():
        db.session.add_all([
            CrimeDistrict(state="Karnataka", district="Bengaluru City", year=2015,
                          latitude=LAT, longitude=LNG, total_crimes=200),
            CrimeDistrict(state="Kerala", district="Kochi", year=2015,
                          latitude=9.93, longitude=76.26, total_crimes=50),
        ])
        db.session.commit()
    r = client.get("/api/safety/historical-crime-points")
    assert r.status_code == 200
    body = r.get_json()
    points = body.get("points") or body.get("features") or []
    assert len(points) == 2


# ---------------------------------------------------------- route check

def test_route_check_falls_back_when_overpass_is_down(client, monkeypatch):
    from app import route_environment

    def unreachable(points):
        raise ConnectionError("overpass unreachable")

    monkeypatch.setattr(route_environment, "fetch_roads", unreachable)
    r = client.post("/api/safety/route-check", json={
        "routes": [{"points": [[LAT, LNG], [LAT + 0.01, LNG + 0.01]], "distance_m": 1500}],
        "hour": 21,
    })
    assert r.status_code == 200, r.get_json()
    body = r.get_json()
    assert body["environment_checked"] is False
    assert len(body["results"]) == 1
    # Scored on crime data alone, with no road/lighting score.
    assert body["results"][0]["environment_score"] is None
    assert body["results"][0]["band"] in ("green", "yellow", "red")


def test_route_check_gives_overpass_about_8_seconds_then_falls_back(client, monkeypatch):
    import time
    import requests
    from app import route_environment

    seen = {}

    def slow_overpass(url, data=None, headers=None, timeout=None):
        seen["timeout"] = timeout
        # A slow service: it only ever answers after the caller's patience ends.
        time.sleep(0.05)
        raise requests.exceptions.ReadTimeout("overpass too slow")

    monkeypatch.setattr(route_environment.requests, "post", slow_overpass)
    route_environment._CACHE.clear()
    started = time.time()
    r = client.post("/api/safety/route-check", json={
        "routes": [{"points": [[LAT, LNG], [LAT + 0.01, LNG + 0.01]], "distance_m": 1500}],
        "hour": 21,
    })
    assert r.status_code == 200, r.get_json()
    assert time.time() - started < 5
    body = r.get_json()
    assert body["environment_checked"] is False
    assert body["results"][0]["environment_score"] is None
    assert body["results"][0]["band"] in ("green", "yellow", "red")
    # connect + read budget is about 8 s, not the old 30 s
    connect_s, read_s = seen["timeout"]
    assert 0 < connect_s + read_s <= 8
