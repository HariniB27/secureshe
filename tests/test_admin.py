import re
import time
from types import SimpleNamespace

import pytest

from app import chain_sync, db
from app.models import Complaint, User
from app.statuses import STATUS_FLOW

KEY = "test-admin-key-123"


@pytest.fixture
def admin_client(app, monkeypatch):
    monkeypatch.setenv("ADMIN_API_KEY", KEY)
    return app.test_client()


def _token(html):
    return re.search(r'name="csrf_token" value="([^"]+)"', html).group(1)


def _login(c, key=KEY):
    page = c.get("/admin/login")
    assert page.status_code == 200
    return c.post("/admin/login", data={"key": key, "csrf_token": _token(page.get_data(as_text=True))})


def _logged_in(c):
    r = _login(c)
    assert r.status_code == 302, r.get_data(as_text=True)
    return c


def _make_report(app, *, name="Reporter One", anonymous=False, status="SUBMITTED",
                 chain_status="confirmed", cid="AAAA1111", **extra):
    with app.app_context():
        user = User(name=name, email=f"{cid}@example.com", password="x", phone="+910000000000")
        db.session.add(user)
        db.session.flush()
        db.session.add(Complaint(
            complaint_id=cid, user_id=user.id, description="Street light out <b>bold</b>",
            category="unsafe-area", anonymous=anonymous, status=status, chain_status=chain_status,
            latitude=12.9692, longitude=79.1559, location_text="VIT Gate",
            evidence_hash="ab" * 32, ipfs_cid="bafyone,bafytwo", blockchain_tx="0x" + "1" * 64,
            chain_synced_status=status, **extra))
        db.session.commit()
    return cid


# ------------------------------------------------------------- availability

def test_503_when_admin_key_is_not_set(app, monkeypatch):
    monkeypatch.setenv("ADMIN_API_KEY", "")
    c = app.test_client()
    for path in ("/admin/", "/admin/login", "/admin/reports"):
        r = c.get(path)
        assert r.status_code == 503, path
        assert "ADMIN_API_KEY is not set" in r.get_data(as_text=True)


def test_unauthenticated_pages_redirect_to_login(admin_client):
    r = admin_client.get("/admin/")
    assert r.status_code == 302 and r.headers["Location"].endswith("/admin/login")


# -------------------------------------------------------------------- login

def test_login_success_sets_a_strict_httponly_cookie(admin_client):
    r = _login(admin_client)
    assert r.status_code == 302
    cookie = r.headers.get("Set-Cookie", "")
    assert "HttpOnly" in cookie and "SameSite=Strict" in cookie
    assert KEY not in cookie and KEY not in r.headers.get("Location", "")
    assert admin_client.get("/admin/").status_code == 200


def test_login_with_wrong_key_is_rejected(admin_client):
    r = _login(admin_client, key="not-the-key")
    assert r.status_code == 401
    assert "not correct" in r.get_data(as_text=True)
    assert admin_client.get("/admin/").status_code == 302


def test_login_is_rate_limited(app, admin_client):
    from app.limiter import limiter
    limiter.enabled = True
    limiter.reset()
    try:
        codes = [_login(admin_client, key="wrong").status_code for _ in range(7)]
    finally:
        limiter.enabled = False
    assert codes[:5] == [401] * 5
    assert 429 in codes[5:]


def test_logout_clears_the_session(admin_client):
    _logged_in(admin_client)
    page = admin_client.get("/admin/")
    r = admin_client.post("/admin/logout", data={"csrf_token": _token(page.get_data(as_text=True))})
    assert r.status_code == 302
    assert admin_client.get("/admin/").status_code == 302


def test_session_expires_after_30_minutes(admin_client, monkeypatch):
    _logged_in(admin_client)
    assert admin_client.get("/admin/").status_code == 200
    real = time.time
    monkeypatch.setattr(time, "time", lambda: real() + 31 * 60)
    assert admin_client.get("/admin/").status_code == 302


# --------------------------------------------------------------------- CSRF

def test_post_without_csrf_token_is_rejected(app, admin_client):
    cid = _make_report(app)
    _logged_in(admin_client)
    r = admin_client.post(f"/admin/report/{cid}/status", data={"status": "UNDER_REVIEW"})
    assert r.status_code == 400
    r = admin_client.post(f"/admin/report/{cid}/status", data={"status": "UNDER_REVIEW", "csrf_token": "forged"})
    assert r.status_code == 400
    with app.app_context():
        assert Complaint.query.filter_by(complaint_id=cid).one().status == "SUBMITTED"


def test_login_post_without_csrf_token_is_rejected(admin_client):
    admin_client.get("/admin/login")
    assert admin_client.post("/admin/login", data={"key": KEY}).status_code == 400


# ----------------------------------------------------------------- privacy

def test_anonymous_reporter_is_not_shown(app, admin_client):
    cid = _make_report(app, name="Secret Person", anonymous=True)
    _logged_in(admin_client)
    html = admin_client.get(f"/admin/report/{cid}").get_data(as_text=True)
    assert "Anonymous" in html
    assert "Secret Person" not in html and "@example.com" not in html


def test_named_reporter_shows_name_only(app, admin_client):
    cid = _make_report(app, name="Priya Sharma", anonymous=False, cid="BBBB2222")
    _logged_in(admin_client)
    html = admin_client.get(f"/admin/report/{cid}").get_data(as_text=True)
    assert "Priya Sharma" in html
    assert "@example.com" not in html and "BBBB2222@" not in html


def test_user_text_is_escaped(app, admin_client):
    cid = _make_report(app)
    _logged_in(admin_client)
    html = admin_client.get(f"/admin/report/{cid}").get_data(as_text=True)
    assert "<b>bold</b>" not in html
    assert "&lt;b&gt;bold&lt;/b&gt;" in html


def test_security_headers_on_admin_responses(app, admin_client):
    _logged_in(admin_client)
    r = admin_client.get("/admin/")
    assert r.headers["Cache-Control"] == "no-store"
    assert r.headers["X-Frame-Options"] == "DENY"
    csp = r.headers["Content-Security-Policy"]
    assert "default-src 'none'" in csp and "frame-ancestors 'none'" in csp and "script-src" not in csp
    nonce = re.search(r"nonce-([\w-]+)", csp).group(1)
    assert f'nonce="{nonce}"' in r.get_data(as_text=True)


def test_admin_routes_are_not_in_public_responses(app, client):
    for rule in app.url_map.iter_rules():
        assert rule.endpoint.startswith("admin.") == rule.rule.startswith("/admin"), rule
    for rule in app.url_map.iter_rules():
        if rule.rule.startswith("/api/safety"):
            assert not rule.endpoint.startswith("admin.")
    assert "/admin" not in client.get("/api/safety/live-reports").get_data(as_text=True)


# ------------------------------------------------------------ status change

def test_status_moves_forward_one_step_and_calls_chain_once(app, admin_client, monkeypatch):
    calls = []
    monkeypatch.setattr(chain_sync, "kick_status_sync", lambda complaint: calls.append(complaint.status))
    cid = _make_report(app)
    _logged_in(admin_client)
    page = admin_client.get(f"/admin/report/{cid}")
    assert "Move to UNDER_REVIEW" in page.get_data(as_text=True)
    r = admin_client.post(f"/admin/report/{cid}/status",
                          data={"status": "UNDER_REVIEW", "csrf_token": _token(page.get_data(as_text=True))},
                          follow_redirects=True)
    assert r.status_code == 200
    assert "SUBMITTED to UNDER_REVIEW" in r.get_data(as_text=True)
    assert calls == ["UNDER_REVIEW"]
    with app.app_context():
        assert Complaint.query.filter_by(complaint_id=cid).one().status == "UNDER_REVIEW"


def test_status_flow_order_is_enforced(app, admin_client, monkeypatch):
    calls = []
    monkeypatch.setattr(chain_sync, "kick_status_sync", lambda complaint: calls.append(1))
    cid = _make_report(app, status="UNDER_REVIEW")
    _logged_in(admin_client)
    token = _token(admin_client.get(f"/admin/report/{cid}").get_data(as_text=True))
    for bad in ("SUBMITTED", "RESOLVED", "ACTION_TAKEN", "UNDER_REVIEW", "NONSENSE"):
        r = admin_client.post(f"/admin/report/{cid}/status", data={"status": bad, "csrf_token": token},
                              follow_redirects=True)
        assert "one step at a time" in r.get_data(as_text=True), bad
    assert calls == []
    with app.app_context():
        assert Complaint.query.filter_by(complaint_id=cid).one().status == "UNDER_REVIEW"


def test_resolved_report_has_no_forward_step(app, admin_client):
    cid = _make_report(app, status=STATUS_FLOW[-1])
    _logged_in(admin_client)
    html = admin_client.get(f"/admin/report/{cid}").get_data(as_text=True)
    assert "Move to" not in html and "resolved" in html


# -------------------------------------------------------------------- retry

def test_retry_button_only_for_failed_rows_and_reuses_retry_log(app, admin_client, monkeypatch):
    retried = []
    monkeypatch.setattr(chain_sync, "retry_log", lambda complaint: retried.append(complaint.complaint_id))
    ok = _make_report(app, cid="OKOK0001", chain_status="confirmed")
    bad = _make_report(app, cid="FAIL0001", chain_status="failed", chain_error="out of gas")
    _logged_in(admin_client)
    ok_html = admin_client.get(f"/admin/report/{ok}").get_data(as_text=True)
    bad_html = admin_client.get(f"/admin/report/{bad}").get_data(as_text=True)
    assert "Retry blockchain log" not in ok_html
    assert "Retry blockchain log" in bad_html and "out of gas" in bad_html
    token = _token(bad_html)
    admin_client.post(f"/admin/report/{ok}/retry", data={"csrf_token": token})
    assert retried == []
    admin_client.post(f"/admin/report/{bad}/retry", data={"csrf_token": token})
    assert retried == ["FAIL0001"]


# -------------------------------------------------------------------- lists

def test_dashboard_counts_and_list_filter_and_pagination(app, admin_client):
    for i in range(30):
        _make_report(app, cid=f"LIST{i:04d}", status="SUBMITTED" if i % 2 else "RESOLVED")
    _logged_in(admin_client)
    dash = admin_client.get("/admin/").get_data(as_text=True)
    assert "30 reports" in dash
    resolved = admin_client.get("/admin/reports?status=RESOLVED").get_data(as_text=True)
    assert "(15, RESOLVED)" in resolved and "LIST0001" not in resolved
    page1 = admin_client.get("/admin/reports").get_data(as_text=True)
    assert "Page 1 of 2" in page1
    page2 = admin_client.get("/admin/reports?page=2").get_data(as_text=True)
    assert "Page 2 of 2" in page2
    assert admin_client.get("/admin/report/NOPE0000").status_code == 404
