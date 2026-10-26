"""
app/routes/sos.py

SOS + Trusted Circle blueprint for SecureShe.

Twilio TRIAL accounts only accept a predefined template name as the message body.
To demo the Twilio path on a trial account, set TWILIO_TRIAL_TEMPLATE in .env
(e.g. TWILIO_TRIAL_TEMPLATE=sms_internal_alerts). Remove that line after upgrading
and the real SOS text with the location link is sent instead.
"""

import os
from datetime import datetime
from flask import Blueprint, request, jsonify
from flask_jwt_extended import jwt_required, get_jwt_identity
from twilio.rest import Client
from twilio.base.exceptions import TwilioRestException

from app import db
from app.models import TrustedContact, User

sos_bp = Blueprint("sos_bp", __name__, url_prefix="/api/sos")

TWILIO_SID = os.environ.get("TWILIO_ACCOUNT_SID")
TWILIO_AUTH_TOKEN = os.environ.get("TWILIO_AUTH_TOKEN")
TWILIO_FROM_NUMBER = os.environ.get("TWILIO_FROM_NUMBER")

_twilio_client = None


def get_twilio_client():
    global _twilio_client
    if _twilio_client is None:
        if not (TWILIO_SID and TWILIO_AUTH_TOKEN and TWILIO_FROM_NUMBER):
            raise RuntimeError(
                "Twilio env vars missing. Set TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, "
                "TWILIO_FROM_NUMBER before calling this endpoint."
            )
        _twilio_client = Client(TWILIO_SID, TWILIO_AUTH_TOKEN)
    return _twilio_client


# ---------------------------------------------------------------------------
# TRUSTED CONTACTS: CRUD, max 5 per user
# ---------------------------------------------------------------------------

@sos_bp.route("/contacts", methods=["GET"])
@jwt_required()
def list_contacts():
    user_id = int(get_jwt_identity())
    contacts = TrustedContact.query.filter_by(user_id=user_id).all()
    return jsonify([
        {"id": c.id, "name": c.name, "phone_number": c.phone_number}
        for c in contacts
    ]), 200


@sos_bp.route("/contacts", methods=["POST"])
@jwt_required()
def add_contact():
    user_id = int(get_jwt_identity())
    data = request.get_json(force=True)
    name = (data.get("name") or "").strip()
    phone = (data.get("phone_number") or "").strip()

    if not name or not phone:
        return jsonify({"error": "name and phone_number are required"}), 400
    if not phone.startswith("+"):
        return jsonify({"error": "phone_number must be in E.164 format, e.g. +919876543210"}), 400

    existing_count = TrustedContact.query.filter_by(user_id=user_id).count()
    if existing_count >= 5:
        return jsonify({"error": "Maximum of 5 trusted contacts allowed"}), 400

    contact = TrustedContact(user_id=user_id, name=name, phone_number=phone)
    db.session.add(contact)
    db.session.commit()
    return jsonify({"id": contact.id, "name": contact.name, "phone_number": contact.phone_number}), 201


@sos_bp.route("/contacts/<int:contact_id>", methods=["DELETE"])
@jwt_required()
def delete_contact(contact_id):
    user_id = int(get_jwt_identity())
    contact = TrustedContact.query.filter_by(id=contact_id, user_id=user_id).first()
    if not contact:
        return jsonify({"error": "Contact not found"}), 404
    db.session.delete(contact)
    db.session.commit()
    return jsonify({"message": "Contact deleted"}), 200


# ---------------------------------------------------------------------------
# SOS TRIGGER: sends an SMS to every trusted contact via Twilio.
# Offline SMS is handled on the phone (sos_screen.dart); this is the online path.
# ---------------------------------------------------------------------------

@sos_bp.route("/trigger", methods=["POST"])
@jwt_required()
def trigger_sos():
    user_id = int(get_jwt_identity())
    data = request.get_json(force=True)

    try:
        latitude = float(data.get("latitude"))
        longitude = float(data.get("longitude"))
    except (TypeError, ValueError):
        return jsonify({"error": "latitude and longitude (numbers) are required"}), 400

    contacts = TrustedContact.query.filter_by(user_id=user_id).all()
    if not contacts:
        return jsonify({"error": "No trusted contacts set up yet"}), 400

    user = User.query.get(user_id)
    user_name = getattr(user, "name", None) or getattr(user, "username", "A SecureShe user")

    maps_link = f"https://www.google.com/maps?q={latitude},{longitude}"
    message_body = (
        f"SOS ALERT: {user_name} needs help. "
        f"Last known location: {maps_link} "
        f"(sent automatically by SecureShe)"
    )

    # Twilio TRIAL accounts only accept a predefined template name as the body.
    trial_template = os.environ.get("TWILIO_TRIAL_TEMPLATE")
    if trial_template:
        message_body = trial_template

    try:
        client = get_twilio_client()
    except RuntimeError:
        # Not configured on this server. The app treats any non-200 as
        # "server alert failed" and falls back to texting from the SIM.
        return jsonify({
            "error": "SOS texting is not configured on the server (Twilio settings missing)"
        }), 503
    results = []
    for contact in contacts:
        try:
            msg = client.messages.create(
                body=message_body,
                from_=TWILIO_FROM_NUMBER,
                to=contact.phone_number,
            )
            results.append({"contact": contact.name, "status": "sent", "sid": msg.sid})
        except TwilioRestException as e:
            # One bad number must not stop the rest.
            results.append({"contact": contact.name, "status": "failed", "error": str(e)})

    any_sent = any(r["status"] == "sent" for r in results)
    status_code = 200 if any_sent else 502
    return jsonify({
        "sos_time_utc": datetime.utcnow().isoformat(),
        "location": {"latitude": latitude, "longitude": longitude},
        "results": results,
    }), status_code