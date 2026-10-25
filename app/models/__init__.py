import sqlalchemy as sa

from app import db
from datetime import datetime

class User(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    email = db.Column(db.String(120), unique=True, nullable=False)
    password = db.Column(db.String(200), nullable=False)
    phone = db.Column(db.String(20), nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    complaints = db.relationship('Complaint', backref='user', lazy=True)

class Complaint(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    complaint_id = db.Column(db.String(50), unique=True, nullable=False)
    user_id = db.Column(db.Integer, db.ForeignKey('user.id'), nullable=False)
    description = db.Column(db.Text, nullable=True)
    latitude = db.Column(db.Float, nullable=True)
    longitude = db.Column(db.Float, nullable=True)
    evidence_hash = db.Column(db.String(256), nullable=True)
    ipfs_cid = db.Column(db.String(256), nullable=True)
    blockchain_tx = db.Column(db.String(256), nullable=True)
    location_source = db.Column(db.String(20), nullable=True)
    # harassment | unsafe-area | suspicious (from the Report screen)
    category = db.Column(db.String(30), nullable=True)
    anonymous = db.Column(db.Boolean, nullable=True, default=False, server_default=sa.false())
    # What the reporter typed in "Where did this happen?" (separate from the pin).
    location_text = db.Column(db.String(200), nullable=True)
    status = db.Column(db.String(50), default='SUBMITTED')
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    # Time of the last STATUS change (the app shows it on the timeline).
    updated_at = db.Column(db.DateTime, default=datetime.utcnow)

    # --- Blockchain bookkeeping (see app/chain_sync.py) -----------------
    # pending | confirmed | failed  (state of the logComplaint transaction)
    chain_status = db.Column(db.String(20), nullable=True)
    chain_attempts = db.Column(db.Integer, nullable=True, default=0, server_default=sa.text('0'))
    chain_error = db.Column(db.String(300), nullable=True)  # server-side only, never sent to the app
    chain_sent_at = db.Column(db.DateTime, nullable=True)   # when the latest tx was sent
    # The status value last CONFIRMED on-chain, and the in-flight updateStatus tx.
    chain_synced_status = db.Column(db.String(50), nullable=True)
    status_tx = db.Column(db.String(256), nullable=True)
    status_tx_value = db.Column(db.String(50), nullable=True)

class CrimeDistrict(db.Model):
    __tablename__ = "crime_district"

    id = db.Column(db.Integer, primary_key=True)

    state = db.Column(db.String(100), nullable=False)
    district = db.Column(db.String(100), nullable=False)
    year = db.Column(db.Integer, nullable=False)

    latitude = db.Column(db.Float, nullable=True)
    longitude = db.Column(db.Float, nullable=True)

    total_crimes = db.Column(db.Integer, nullable=False, default=0)


class TrustedContact(db.Model):
    __tablename__ = "trusted_contacts"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False)
    name = db.Column(db.String(100), nullable=False)
    phone_number = db.Column(db.String(20), nullable=False)  # E.164 format e.g. +919876543210
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class CommunityFlag(db.Model):
    """Quick map flags from the Safety Map: dark street, harassment,
    suspicious activity, or a community-marked safe zone."""
    __tablename__ = "community_flags"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False)
    kind = db.Column(db.String(30), nullable=False)
    latitude = db.Column(db.Float, nullable=False)
    longitude = db.Column(db.Float, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
