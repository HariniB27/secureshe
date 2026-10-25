"""
app/routes/sos.py

SOS + Trusted Circle blueprint for SecureShe.

WHERE THIS FILE GOES:
    Copy this into: app/routes/sos.py
    (same folder as your existing auth.py and complaints.py)

WHAT YOU MUST CONFIRM BEFORE THIS WORKS (do these first, in order):
    1. Your existing app uses Flask-JWT-Extended for auth (this file assumes
       @jwt_required() and get_jwt_identity() work the same way auth.py already
       uses them). Open app/routes/auth.py and check the top imports — if you
       see `from flask_jwt_extended import ...` you're good. If it's something
       else (e.g. a custom token decorator), tell me and I'll adjust this file.
    2. Your database is set up with SQLAlchemy (db = SQLAlchemy(...) somewhere,
       usually app/__init__.py or app/models.py). This file assumes `from app import db`
       works — adjust the import to match your project if it's named differently.
    3. Twilio: you need a Twilio account SID, auth token, and a Twilio phone
       number. Free trial account is fine. Get these from twilio.com/console.
"""

import os
from datetime import datetime
from flask import Blueprint, request, jsonify
from flask_jwt_extended import jwt_required, get_jwt_identity
from twilio.rest import Client
from twilio.base.exceptions import TwilioRestException

from app import db  # adjust if your db object lives elsewhere

sos_bp = Blueprint("sos_bp", __name__, url_prefix="/api/sos")

# ---------------------------------------------------------------------------
# MODEL — add this class to your app/models.py (do NOT leave it in this file,
# SQLAlchemy models should live with your other models e.g. User, Complaint)
# ---------------------------------------------------------------------------
"""
Copy this into app/models.py:

class TrustedContact(db.Model):
    __tablename__ = "trusted_contacts"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    name = db.Column(db.String(100), nullable=False)
    phone_number = db.Column(db.String(20), nullable=False)  # E.164 format e.g. +919876543210
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

Then run your migration (see MIGRATION NOTE at the bottom of this file).
"""
from app.models import TrustedContact, User  # adjust import path to match your project structure


# ---------------------------------------------------------------------------
# Twilio client — reads credentials from environment variables.
# NEVER hardcode these in code that goes to GitHub.
# ---------------------------------------------------------------------------
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
# TRUSTED CONTACTS — CRUD, max 5 per user
# ---------------------------------------------------------------------------

@sos_bp.route("/contacts", methods=["GET"])
@jwt_required()
def list_contacts():
    user_id = get_jwt_identity()
    contacts = TrustedContact.query.filter_by(user_id=user_id).all()
    return jsonify([
        {"id": c.id, "name": c.name, "phone_number": c.phone_number}
        for c in contacts
    ]), 200


@sos_bp.route("/contacts", methods=["POST"])
@jwt_required()
def add_contact():
    user_id = get_jwt_identity()
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
# SOS TRIGGER — sends an SMS with live location to every trusted contact.
# This ONLY works when the phone has data/network. True offline SMS is
# handled entirely in Flutter (see sos_screen.dart) — this endpoint is the
# "online" path.
# ---------------------------------------------------------------------------

@sos_bp.route("/trigger", methods=["POST"])
@jwt_required()
def trigger_sos():
    user_id = get_jwt_identity()
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

    client = get_twilio_client()
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
            # Don't let one bad number kill the whole SOS — keep sending to the rest.
            results.append({"contact": contact.name, "status": "failed", "error": str(e)})

    any_sent = any(r["status"] == "sent" for r in results)
    status_code = 200 if any_sent else 502
    return jsonify({
        "sos_time_utc": datetime.utcnow().isoformat(),
        "location": {"latitude": latitude, "longitude": longitude},
        "results": results,
    }), status_code


"""
MIGRATION NOTE — after adding TrustedContact to app/models.py, you need to
create the actual database table. In your terminal, from the project root
(same folder that has app/), run:

    flask db migrate -m "add trusted contacts table"
    flask db upgrade

If your project doesn't use Flask-Migrate (check for a `migrations/` folder),
tell me and I'll give you the raw SQL / db.create_all() version instead.
"""

"""
REGISTRATION — add these two lines to app/__init__.py, next to where
auth_bp and complaints_bp are already registered:

    from app.routes.sos import sos_bp
    app.register_blueprint(sos_bp)
"""
