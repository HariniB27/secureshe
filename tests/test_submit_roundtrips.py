"""The submit route does one commit (database round trips are slow when the
database is far away) and still returns the same response and stores the tx."""
import importlib.util
from pathlib import Path

import pytest
from sqlalchemy import event

from app import blockchain, chain_sync, db
from app.models import Complaint

TX = "0x" + "a" * 64


def _count_commits(app):
    commits = []
    with app.app_context():
        event.listen(db.engine, "commit", lambda conn: commits.append(1))
    return commits


def _real_attempt_log():
    """The real chain_sync.attempt_log (the test fixtures replace the module's)."""
    path = Path(chain_sync.__file__)
    spec = importlib.util.spec_from_file_location("chain_sync_real", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.attempt_log


def test_submit_is_one_commit_and_stores_the_tx_hash(app, client, auth_headers, monkeypatch):
    monkeypatch.setattr(blockchain, "log_complaint_on_chain", lambda cid, h: TX)
    monkeypatch.setattr(chain_sync, "attempt_log", _real_attempt_log())
    commits = _count_commits(app)

    r = client.post("/api/complaints/submit", headers=auth_headers,
                    data={"category": "unsafe-area", "description": "one commit", "lat": "12.9", "lng": "79.1"})
    assert r.status_code == 201, r.get_json()
    body = r.get_json()

    assert len(commits) == 1
    assert body["chain_status"] == "pending"
    assert body["blockchain_tx"] == TX
    assert body["etherscan_url"].endswith(TX)
    assert body["created_at"] and body["updated_at"] and body["evidence_hash"]
    with app.app_context():
        row = Complaint.query.filter_by(complaint_id=body["complaint_id"]).one()
        assert row.blockchain_tx == TX and row.chain_status == "pending" and row.chain_attempts == 1
        assert row.chain_sent_at is not None


def test_a_chain_failure_still_saves_the_report_in_one_commit(app, client, auth_headers, monkeypatch):
    def down(cid, h):
        raise ConnectionError("rpc down")

    monkeypatch.setattr(blockchain, "log_complaint_on_chain", down)
    monkeypatch.setattr(chain_sync, "attempt_log", _real_attempt_log())
    commits = _count_commits(app)

    r = client.post("/api/complaints/submit", headers=auth_headers, data={"description": "rpc down"})
    assert r.status_code == 201, r.get_json()
    body = r.get_json()
    assert len(commits) == 1
    assert body["chain_status"] == "pending" and "blockchain_tx" not in body
    with app.app_context():
        row = Complaint.query.filter_by(complaint_id=body["complaint_id"]).one()
        assert row.blockchain_tx is None and row.chain_attempts == 1 and "rpc down" in (row.chain_error or "")


def test_a_crash_inside_attempt_log_does_not_lose_the_report(app, client, auth_headers, monkeypatch):
    def boom(complaint, **kw):
        raise RuntimeError("unexpected")

    monkeypatch.setattr(chain_sync, "attempt_log", boom)
    r = client.post("/api/complaints/submit", headers=auth_headers, data={"description": "still saved"})
    assert r.status_code == 201
    with app.app_context():
        assert Complaint.query.filter_by(complaint_id=r.get_json()["complaint_id"]).count() == 1


def test_attempt_log_leaves_the_commit_to_the_caller_when_asked(app, monkeypatch):
    monkeypatch.setattr(blockchain, "log_complaint_on_chain", lambda cid, h: TX)
    real = _real_attempt_log()
    commits = _count_commits(app)
    with app.app_context():
        from app.models import User
        user = User(name="U", email="u@example.com", password="x", phone="+910000000000")
        db.session.add(user)
        db.session.commit()
        before = len(commits)
        c = Complaint(complaint_id="ZZZZ0001", user_id=user.id, description="d", evidence_hash="h", status="SUBMITTED")
        db.session.add(c)
        db.session.flush()
        real(c, commit=False)
        assert len(commits) == before          # nothing committed by attempt_log itself
        db.session.commit()
        assert len(commits) == before + 1
        assert Complaint.query.filter_by(complaint_id="ZZZZ0001").one().blockchain_tx == TX
        real_default = Complaint(complaint_id="ZZZZ0002", user_id=user.id, description="d", evidence_hash="h", status="SUBMITTED")
        db.session.add(real_default)
        db.session.flush()
        real(real_default)                      # default behaviour (the worker's retry path) still commits
        assert len(commits) == before + 2
