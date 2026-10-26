import hashlib
import hmac
import logging
import math
import os
import uuid
from datetime import datetime

import requests
from flask import Blueprint, jsonify, request
from flask_jwt_extended import get_jwt_identity, jwt_required

from app import chain_sync, db
from app.limiter import ADMIN_LIMIT, RETRY_CHAIN_LIMIT, limiter
from app.models import Complaint
from app.statuses import STATUS_FLOW
from app.validation import MAX_DESCRIPTION_LENGTH, MAX_LOCATION_TEXT_LENGTH

log = logging.getLogger('secureshe.complaints')

complaints_bp = Blueprint('complaints', __name__)

PINATA_API_KEY = os.getenv('PINATA_API_KEY')
PINATA_SECRET_API_KEY = os.getenv('PINATA_SECRET_API_KEY')
PINATA_PIN_URL = 'https://api.pinata.cloud/pinning/pinFileToIPFS'

COMPLAINT_CATEGORIES = ('harassment', 'unsafe-area', 'suspicious')

# 5 IPFS CIDs (46 chars each) plus commas fit the 256-char ipfs_cid column.
MAX_EVIDENCE = 5


def upload_to_pinata(file_bytes, filename):
    """Upload file bytes to Pinata IPFS. Returns CID string or raises."""
    headers = {
        'pinata_api_key': PINATA_API_KEY,
        'pinata_secret_api_key': PINATA_SECRET_API_KEY,
    }
    files = {'file': (filename, file_bytes)}
    response = requests.post(PINATA_PIN_URL, headers=headers, files=files, timeout=30)
    response.raise_for_status()
    return response.json()['IpfsHash']


def _bad(message, code=400):
    return jsonify({'error': message}), code


def _number(raw):
    """float() that also rejects nan/inf. Raises ValueError."""
    value = float(raw)
    if not math.isfinite(value):
        raise ValueError('not finite')
    return value


@complaints_bp.route('/submit', methods=['POST'])
@jwt_required()
def submit_complaint():
    user_id = get_jwt_identity()

    # Accepts multipart form (the app, with evidence files) or JSON.
    if request.form or request.files:
        fields = request.form
    else:
        body = request.get_json(silent=True, force=True)
        fields = body if isinstance(body, dict) else {}

    description = str(fields.get('description', '') or '')
    if len(description) > MAX_DESCRIPTION_LENGTH:
        return _bad(f'Description must be at most {MAX_DESCRIPTION_LENGTH} characters')

    # Location: a pin (lat + lng, both or neither) and/or typed text.
    lat_raw = fields.get('lat', fields.get('latitude'))
    lng_raw = fields.get('lng', fields.get('longitude'))
    has_lat = lat_raw not in (None, '')
    has_lng = lng_raw not in (None, '')

    if has_lat != has_lng:
        return _bad('lat and lng must be provided together')

    latitude = longitude = None
    if has_lat:
        try:
            latitude = _number(lat_raw)
            longitude = _number(lng_raw)
        except (TypeError, ValueError):
            return _bad('lat/lng must be valid numbers')
        if not -90 <= latitude <= 90:
            return _bad('Invalid latitude')
        if not -180 <= longitude <= 180:
            return _bad('Invalid longitude')

    location_source = fields.get('location_source') or None
    if location_source is not None and location_source not in ('gps', 'manual'):
        return _bad("location_source must be 'gps' or 'manual'")
    if latitude is None:
        location_source = None

    location_text = str(fields.get('location_text') or '').strip() or None
    if location_text and len(location_text) > MAX_LOCATION_TEXT_LENGTH:
        return _bad(f'location_text must be at most {MAX_LOCATION_TEXT_LENGTH} characters')

    category = str(fields.get('category') or '').strip() or None
    if category is not None and category not in COMPLAINT_CATEGORIES:
        return _bad('Unknown category')

    anonymous = str(fields.get('anonymous', '')).strip().lower() in ('1', 'true', 'yes')

    complaint_id = str(uuid.uuid4())[:8].upper()
    ipfs_cid = None

    # Evidence: one or more files sent as "evidence" (up to MAX_EVIDENCE).
    # Each is pinned to IPFS. The hash logged on-chain covers all of them:
    # sha256 of the files' own sha256 hashes, in upload order. With a single
    # file that is simply that file's hash.
    evidence_files = [f for f in request.files.getlist('evidence') if f]
    if len(evidence_files) > MAX_EVIDENCE:
        return _bad(f'At most {MAX_EVIDENCE} evidence files per report')

    cids = []
    file_hashes = []
    if evidence_files:
        if not (PINATA_API_KEY and PINATA_SECRET_API_KEY):
            return _bad('Pinata API keys not configured', 500)

        for evidence_file in evidence_files:
            file_bytes = evidence_file.read()
            file_hashes.append(hashlib.sha256(file_bytes).hexdigest())
            try:
                cids.append(upload_to_pinata(file_bytes, evidence_file.filename or 'evidence'))
            except requests.HTTPError as e:
                return _bad(f'Pinata upload failed: {e.response.text}', 502)
            except requests.RequestException:
                return _bad('Could not reach the evidence storage service. Try again.', 502)

        if len(file_hashes) == 1:
            evidence_hash = file_hashes[0]
        else:
            evidence_hash = hashlib.sha256(''.join(file_hashes).encode()).hexdigest()
        # Comma-separated so the existing single-CID column still works.
        ipfs_cid = ','.join(cids)
    else:
        # No file: hash the description as a placeholder.
        evidence_hash = hashlib.sha256(description.encode()).hexdigest()

    complaint = Complaint(
        complaint_id=complaint_id,
        user_id=user_id,
        description=description,
        evidence_hash=evidence_hash,
        ipfs_cid=ipfs_cid,
        latitude=latitude,
        longitude=longitude,
        location_source=location_source,
        location_text=location_text,
        category=category,
        anonymous=anonymous,
        status='SUBMITTED',
        chain_status='pending',
        chain_attempts=0,
        # Marks the row as "this request is sending it right now", so the
        # background worker doesn't send a duplicate in the gap before
        # attempt_log() below stores the tx hash.
        chain_sent_at=datetime.utcnow(),
    )
    db.session.add(complaint)
    db.session.commit()

    # Broadcast the log transaction and return straight away; the worker
    # confirms it (and retries if needed). A chain problem never fails the report.
    try:
        chain_sync.attempt_log(complaint)
    except Exception:
        db.session.rollback()
        log.exception('[chain] could not start logging %s', complaint_id)

    return jsonify({'message': 'Complaint submitted successfully', **_complaint_json(complaint)}), 201


def _evidence_list(ipfs_cid):
    return [
        {'cid': cid, 'url': f'https://gateway.pinata.cloud/ipfs/{cid}'}
        for cid in ipfs_cid.split(',') if cid
    ]


def _iso(value):
    return value.isoformat() + 'Z' if value else None


def _complaint_json(complaint):
    chain_status = complaint.chain_status or 'pending'
    data = {
        'complaint_id': complaint.complaint_id,
        'status': complaint.status,
        # The steps a report moves through, so the app draws the same list.
        'status_flow': list(STATUS_FLOW),
        'category': complaint.category,
        'anonymous': bool(complaint.anonymous),
        'description': complaint.description or '',
        'evidence_hash': complaint.evidence_hash,
        'has_evidence': bool(complaint.ipfs_cid),
        'latitude': complaint.latitude,
        'longitude': complaint.longitude,
        'location_source': complaint.location_source,
        'location_text': complaint.location_text,
        'created_at': _iso(complaint.created_at),
        'updated_at': _iso(complaint.updated_at),
        # pending | confirmed | failed (the raw error stays server-side).
        'chain_status': chain_status,
        'chain_can_retry': chain_status == 'failed',
        'status_on_chain': complaint.chain_synced_status,
    }
    if complaint.ipfs_cid:
        data['ipfs_cid'] = complaint.ipfs_cid
        data['evidence'] = _evidence_list(complaint.ipfs_cid)
        data['ipfs_url'] = data['evidence'][0]['url']
    if complaint.blockchain_tx:
        data['blockchain_tx'] = complaint.blockchain_tx
        data['etherscan_url'] = f'https://sepolia.etherscan.io/tx/{complaint.blockchain_tx}'
    return data


def _owned(complaint_id):
    """The complaint if it exists AND belongs to the caller, else None.
    The same answer for both cases, so IDs can't be probed."""
    complaint = Complaint.query.filter_by(complaint_id=complaint_id).first()
    if not complaint or str(complaint.user_id) != str(get_jwt_identity()):
        return None
    return complaint


@complaints_bp.route('/status/<complaint_id>', methods=['GET'])
@jwt_required()
def get_status(complaint_id):
    complaint = _owned(complaint_id)
    if not complaint:
        return _bad('Complaint not found', 404)
    return jsonify(_complaint_json(complaint)), 200


@complaints_bp.route('/mine', methods=['GET'])
@jwt_required()
def my_complaints():
    """The signed-in user's own reports, newest first."""
    complaints = (
        Complaint.query
        .filter_by(user_id=int(get_jwt_identity()))
        .order_by(Complaint.created_at.desc())
        .limit(200)
        .all()
    )
    return jsonify({'complaints': [_complaint_json(c) for c in complaints]}), 200


@complaints_bp.route('/<complaint_id>/retry-chain', methods=['POST'])
@limiter.limit(RETRY_CHAIN_LIMIT)
@jwt_required()
def retry_chain(complaint_id):
    """Owner-only: try the blockchain log again after it failed."""
    complaint = _owned(complaint_id)
    if not complaint:
        return _bad('Complaint not found', 404)

    if complaint.chain_status == 'confirmed':
        return jsonify({'error': 'Already confirmed on the blockchain',
                        **_complaint_json(complaint)}), 409
    if complaint.chain_status == 'pending' and complaint.blockchain_tx:
        return jsonify({'error': 'A blockchain transaction is already waiting to be confirmed',
                        **_complaint_json(complaint)}), 409

    chain_sync.retry_log(complaint)
    return jsonify(_complaint_json(complaint)), 202


def apply_status_change(complaint, new_status):
    """Write a new status to the database and push it on-chain without
    waiting for the transaction to be mined. Returns the previous status.
    Shared by the admin API (PATCH below) and the admin web portal."""
    previous = complaint.status
    if new_status != previous:
        complaint.status = new_status
        complaint.updated_at = datetime.utcnow()
        db.session.commit()

    # Idempotent: re-sending the same status retries the on-chain update.
    try:
        chain_sync.kick_status_sync(complaint)
    except Exception:
        db.session.rollback()
        log.exception('[chain] could not start status sync for %s', complaint.complaint_id)
    return previous


def _admin_key_state():
    """'disabled' when no key is configured (fail closed), else True/False."""
    expected = os.getenv('ADMIN_API_KEY', '')
    if not expected:
        return 'disabled'
    given = request.headers.get('X-Admin-Key', '')
    return hmac.compare_digest(given.encode('utf-8'), expected.encode('utf-8'))


@complaints_bp.route('/<complaint_id>/status', methods=['PATCH'])
@limiter.limit(ADMIN_LIMIT)
def admin_set_status(complaint_id):
    """Admin-only (X-Admin-Key). Updates the status in the database and
    pushes it on-chain without waiting for the transaction to be mined."""
    key = _admin_key_state()
    if key == 'disabled':
        return _bad('Admin status updates are disabled (ADMIN_API_KEY is not set)', 503)
    if not key:
        return _bad('Forbidden', 403)

    body = request.get_json(silent=True)
    new_status = str((body or {}).get('status', '')).strip().upper()
    if new_status not in STATUS_FLOW:
        return _bad(f"status must be one of: {', '.join(STATUS_FLOW)}")

    complaint = Complaint.query.filter_by(complaint_id=complaint_id).first()
    if not complaint:
        return _bad('Complaint not found', 404)

    previous = apply_status_change(complaint, new_status)

    result = {
        'complaint_id': complaint.complaint_id,
        'status': complaint.status,
        'previous_status': previous,
        'chain_status': complaint.chain_status or 'pending',
        'status_on_chain': complaint.chain_synced_status,
    }
    if complaint.status_tx:
        result['status_tx'] = complaint.status_tx
        result['etherscan_status_url'] = f'https://sepolia.etherscan.io/tx/{complaint.status_tx}'
    return jsonify(result), 200
