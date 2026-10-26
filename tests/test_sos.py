from types import SimpleNamespace

import pytest

from app.routes import sos as sos_routes

LOCATION = {"latitude": 12.97, "longitude": 77.59}


def _add_contact(client, headers, name="Mom", phone="+919000000001"):
    r = client.post("/api/sos/contacts", headers=headers, json={"name": name, "phone_number": phone})
    assert r.status_code == 201, r.get_json()
    return r.get_json()["id"]


def test_contacts_crud_and_limit(client, auth_headers):
    ids = [_add_contact(client, auth_headers, name=f"C{i}", phone=f"+91900000000{i}") for i in range(5)]
    r = client.post("/api/sos/contacts", headers=auth_headers, json={"name": "Six", "phone_number": "+919999999999"})
    assert r.status_code == 400
    assert len(client.get("/api/sos/contacts", headers=auth_headers).get_json()) == 5
    assert client.delete(f"/api/sos/contacts/{ids[0]}", headers=auth_headers).status_code == 200
    assert len(client.get("/api/sos/contacts", headers=auth_headers).get_json()) == 4


def test_contact_needs_e164(client, auth_headers):
    r = client.post("/api/sos/contacts", headers=auth_headers, json={"name": "X", "phone_number": "9876543210"})
    assert r.status_code == 400


def test_trigger_without_contacts(client, auth_headers):
    assert client.post("/api/sos/trigger", headers=auth_headers, json=LOCATION).status_code == 400


def test_trigger_without_twilio_is_503_not_success(client, auth_headers, monkeypatch):
    monkeypatch.setattr(sos_routes, "_twilio_client", None)
    monkeypatch.setattr(sos_routes, "TWILIO_SID", None)
    _add_contact(client, auth_headers)
    r = client.post("/api/sos/trigger", headers=auth_headers, json=LOCATION)
    assert r.status_code == 503
    assert "Twilio" in r.get_json()["error"]


class _FakeMessages:
    def __init__(self, fail_numbers=()):
        self.sent = []
        self.fail_numbers = set(fail_numbers)

    def create(self, body, from_, to):
        if to in self.fail_numbers:
            from twilio.base.exceptions import TwilioRestException
            raise TwilioRestException(400, "uri", msg="unverified number")
        self.sent.append(to)
        return SimpleNamespace(sid=f"SMfake{len(self.sent)}")


@pytest.mark.parametrize("fail,expected", [((), 200), (("+919000000001",), 502)])
def test_trigger_with_twilio(client, auth_headers, monkeypatch, fail, expected):
    messages = _FakeMessages(fail)
    monkeypatch.setattr(sos_routes, "_twilio_client", SimpleNamespace(messages=messages))
    _add_contact(client, auth_headers)
    r = client.post("/api/sos/trigger", headers=auth_headers, json=LOCATION)
    assert r.status_code == expected
    result = r.get_json()["results"][0]
    if expected == 200:
        assert result["sid"].startswith("SM")
    else:
        assert result["status"] == "failed"


def test_trial_template_replaces_body(client, auth_headers, monkeypatch):
    sent = []

    class Messages:
        def create(self, body, from_, to):
            sent.append(body)
            return SimpleNamespace(sid="SMtrial")

    monkeypatch.setattr(sos_routes, "_twilio_client", SimpleNamespace(messages=Messages()))
    monkeypatch.setenv("TWILIO_TRIAL_TEMPLATE", "sms_internal_alerts")
    _add_contact(client, auth_headers)
    r = client.post("/api/sos/trigger", headers=auth_headers, json=LOCATION)
    assert r.status_code == 200
    assert sent == ["sms_internal_alerts"]
    assert r.get_json()["template_mode"] is True


def test_template_mode_is_false_when_variable_unset(client, auth_headers, monkeypatch):
    sent = []

    class Messages:
        def create(self, body, from_, to):
            sent.append(body)
            return SimpleNamespace(sid="SMreal")

    monkeypatch.setattr(sos_routes, "_twilio_client", SimpleNamespace(messages=Messages()))
    monkeypatch.delenv("TWILIO_TRIAL_TEMPLATE", raising=False)
    _add_contact(client, auth_headers)
    r = client.post("/api/sos/trigger", headers=auth_headers, json=LOCATION)
    assert r.status_code == 200
    assert r.get_json()["template_mode"] is False
    assert "google.com/maps" in sent[0]  # the real message with the location link
