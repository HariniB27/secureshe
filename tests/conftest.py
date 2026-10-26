"""Test setup: a throwaway SQLite database per test, no network.

The environment is set BEFORE the app is imported, because app/__init__.py
calls load_dotenv() and load_dotenv never overrides variables that are
already set. So a developer's real .env (Neon, Pinata, wallet key) is never
used by the tests.
"""
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

os.environ["DATABASE_URL"] = "sqlite://"  # replaced per test below
os.environ["SECRET_KEY"] = "test-secret-key"
os.environ["JWT_SECRET_KEY"] = "test-jwt-secret-key-that-is-at-least-32-bytes"
os.environ["CHAIN_WORKER"] = "0"
os.environ["PINATA_API_KEY"] = "test-pinata-key"
os.environ["PINATA_SECRET_API_KEY"] = "test-pinata-secret"
os.environ["WEB3_PROVIDER_URL"] = ""
os.environ["CONTRACT_ADDRESS"] = ""
os.environ["BACKEND_WALLET_PRIVATE_KEY"] = ""
os.environ["ADMIN_API_KEY"] = ""
for var in ("TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN", "TWILIO_FROM_NUMBER"):
    os.environ[var] = ""

import pytest  # noqa: E402


@pytest.fixture
def app(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite:///{tmp_path / 'test.db'}")

    from app import create_app
    from app.limiter import limiter

    application = create_app()
    application.config["TESTING"] = True
    limiter.enabled = False

    # No real IPFS uploads or blockchain transactions in tests.
    from app.routes import complaints as complaints_routes
    from app import chain_sync

    uploads = []

    def fake_upload(file_bytes, filename):
        uploads.append(filename)
        return f"bafytestcid{len(uploads)}"

    monkeypatch.setattr(complaints_routes, "upload_to_pinata", fake_upload)
    monkeypatch.setattr(complaints_routes, "PINATA_API_KEY", "test-pinata-key")
    monkeypatch.setattr(complaints_routes, "PINATA_SECRET_API_KEY", "test-pinata-secret")
    monkeypatch.setattr(chain_sync, "attempt_log", lambda complaint, **kw: None)
    monkeypatch.setattr(chain_sync, "kick_status_sync", lambda complaint: None)

    application.extensions["test_uploads"] = uploads
    yield application

    from app import db

    with application.app_context():
        db.session.remove()
        db.engine.dispose()


@pytest.fixture
def client(app):
    return app.test_client()


def register_and_login(client, email="tester@example.com", password="correct-horse-1"):
    r = client.post("/api/auth/register", json={
        "name": "Test User",
        "email": email,
        "password": password,
        "phone": "+919000000000",
    })
    assert r.status_code == 201, r.get_json()
    r = client.post("/api/auth/login", json={"email": email, "password": password})
    assert r.status_code == 200, r.get_json()
    return {"Authorization": f"Bearer {r.get_json()['access_token']}"}


@pytest.fixture
def auth_headers(client):
    return register_and_login(client)
