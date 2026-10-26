import io

from conftest import register_and_login


# ---------------------------------------------------------------- auth

def test_register_then_login(client):
    headers = register_and_login(client, email="a@example.com")
    me = client.get("/api/auth/me", headers=headers)
    assert me.status_code == 200
    assert me.get_json()["email"] == "a@example.com"


def test_register_rejects_duplicate_email(client):
    register_and_login(client, email="dup@example.com")
    r = client.post("/api/auth/register", json={
        "name": "Again", "email": "DUP@example.com",
        "password": "another-pass-1", "phone": "+911",
    })
    assert r.status_code == 409


def test_register_rejects_short_password(client):
    r = client.post("/api/auth/register", json={
        "name": "Short", "email": "short@example.com",
        "password": "abc", "phone": "+911",
    })
    assert r.status_code == 400


def test_login_wrong_password(client):
    register_and_login(client, email="b@example.com")
    r = client.post("/api/auth/login", json={"email": "b@example.com", "password": "wrong-password"})
    assert r.status_code == 401


# ---------------------------------------------------------- complaints

def _submit(client, headers, **fields):
    data = {
        "description": "Someone followed me",
        "lat": "12.971599",
        "lng": "77.594566",
        "location_source": "gps",
        "category": "harassment",
    }
    data.update(fields)
    return client.post("/api/complaints/submit", headers=headers, data=data,
                       content_type="multipart/form-data")


def test_submit_with_evidence_pins_to_ipfs(app, client, auth_headers):
    r = _submit(client, auth_headers, evidence=[
        (io.BytesIO(b"photo-bytes"), "photo.jpg"),
        (io.BytesIO(b"audio-bytes"), "clip.m4a"),
    ])
    assert r.status_code == 201, r.get_json()
    body = r.get_json()
    assert body["complaint_id"]
    assert len(body["evidence"]) == 2
    assert app.extensions["test_uploads"] == ["photo.jpg", "clip.m4a"]


def test_submit_without_evidence(client, auth_headers):
    r = _submit(client, auth_headers)
    assert r.status_code == 201
    body = r.get_json()
    assert body["has_evidence"] is False
    assert "evidence" not in body


def test_submit_requires_login(client):
    r = client.post("/api/complaints/submit", data={"description": "x"})
    assert r.status_code == 401


def test_status_is_owner_only(client):
    owner = register_and_login(client, email="owner@example.com")
    other = register_and_login(client, email="other@example.com")

    complaint_id = _submit(client, owner).get_json()["complaint_id"]

    assert client.get(f"/api/complaints/status/{complaint_id}", headers=owner).status_code == 200
    # Another user gets the same 404 as a complaint that doesn't exist.
    assert client.get(f"/api/complaints/status/{complaint_id}", headers=other).status_code == 404
    assert client.get("/api/complaints/status/NOPE1234", headers=owner).status_code == 404


# --------------------------------------------------------------- admin

def test_admin_key(client, auth_headers, monkeypatch):
    complaint_id = _submit(client, auth_headers).get_json()["complaint_id"]
    url = f"/api/complaints/{complaint_id}/status"
    body = {"status": "UNDER_REVIEW"}

    monkeypatch.setenv("ADMIN_API_KEY", "")
    assert client.patch(url, json=body, headers={"X-Admin-Key": "anything"}).status_code == 503

    monkeypatch.setenv("ADMIN_API_KEY", "right-key")
    assert client.patch(url, json=body, headers={"X-Admin-Key": "wrong-key"}).status_code == 403
    assert client.patch(url, json=body).status_code == 403

    r = client.patch(url, json=body, headers={"X-Admin-Key": "right-key"})
    assert r.status_code == 200, r.get_json()
    assert client.get(f"/api/complaints/status/{complaint_id}",
                      headers=auth_headers).get_json()["status"] == "UNDER_REVIEW"
