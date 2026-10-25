from flask import Blueprint, request, jsonify
from app import db
from app.models import Complaint
from flask_jwt_extended import jwt_required, get_jwt_identity
import uuid
import hashlib
import os
import requests
from app.blockchain import log_complaint_on_chain

complaints_bp = Blueprint('complaints', __name__)

PINATA_API_KEY = os.getenv('PINATA_API_KEY')
PINATA_SECRET_API_KEY = os.getenv('PINATA_SECRET_API_KEY')
PINATA_PIN_URL = 'https://api.pinata.cloud/pinning/pinFileToIPFS'

COMPLAINT_CATEGORIES = ('harassment', 'unsafe-area', 'suspicious')

# The order a report moves through. The app draws its progress timeline
# from this, so keep it in sync with STATUS_STEPS in report_status_screen.dart.
# 5 IPFS CIDs (46 chars each) plus commas fit the 256-char ipfs_cid column.
MAX_EVIDENCE = 5

STATUS_FLOW = ('SUBMITTED', 'UNDER_REVIEW', 'INVESTIGATING', 'ACTION_TAKEN', 'RESOLVED')


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


@complaints_bp.route('/submit', methods=['POST'])
@jwt_required()
def submit_complaint():
    user_id = get_jwt_identity()

    # Accepts multipart form (the app, with an evidence file) or JSON.
    # Location can be sent as lat/lng or latitude/longitude.
    if request.form or request.files:
        fields = request.form
    else:
        fields = request.get_json(silent=True, force=True) or {}

    description = fields.get('description', '') or ''

    lat_raw = fields.get('lat', fields.get('latitude'))
    lng_raw = fields.get('lng', fields.get('longitude'))
    try:
        latitude = float(lat_raw) if lat_raw not in (None, '') else None
        longitude = float(lng_raw) if lng_raw not in (None, '') else None
    except (TypeError, ValueError):
        return jsonify({'error': 'lat/lng must be valid numbers'}), 400

    if latitude is not None and not -90 <= latitude <= 90:
        return jsonify({'error': 'Invalid latitude'}), 400
    if longitude is not None and not -180 <= longitude <= 180:
        return jsonify({'error': 'Invalid longitude'}), 400

    location_source = fields.get('location_source')

    category = (fields.get('category') or '').strip() or None
    if category is not None and category not in COMPLAINT_CATEGORIES:
        return jsonify({'error': 'Unknown category'}), 400

    anonymous = str(fields.get('anonymous', '')).strip().lower() in ('1', 'true', 'yes')
    if location_source == '':
        location_source = None
    if location_source is not None and location_source not in ('gps', 'manual'):
        return jsonify({'error': "location_source must be 'gps' or 'manual'"}), 400

    complaint_id = str(uuid.uuid4())[:8].upper()
    ipfs_cid = None
    evidence_hash = None

    # Evidence: one or more files sent as "evidence" (up to MAX_EVIDENCE).
    # Each is pinned to IPFS. The hash logged on-chain covers all of them:
    # sha256 of the files' own sha256 hashes, in upload order. With a single
    # file that is simply that file's hash, as before.
    evidence_files = [f for f in request.files.getlist('evidence') if f]
    if len(evidence_files) > MAX_EVIDENCE:
        return jsonify({'error': f'At most {MAX_EVIDENCE} evidence files per report'}), 400

    cids = []
    file_hashes = []
    if evidence_files:
        if not (PINATA_API_KEY and PINATA_SECRET_API_KEY):
            return jsonify({'error': 'Pinata API keys not configured'}), 500

        for evidence_file in evidence_files:
            file_bytes = evidence_file.read()
            file_hashes.append(hashlib.sha256(file_bytes).hexdigest())
            try:
                cids.append(upload_to_pinata(file_bytes, evidence_file.filename or 'evidence'))
            except requests.HTTPError as e:
                return jsonify({'error': f'Pinata upload failed: {e.response.text}'}), 502
            except requests.RequestException as e:
                return jsonify({'error': f'Pinata connection error: {str(e)}'}), 502

        if len(file_hashes) == 1:
            evidence_hash = file_hashes[0]
        else:
            evidence_hash = hashlib.sha256(''.join(file_hashes).encode()).hexdigest()
        # Comma-separated so the existing single-CID column still works.
        ipfs_cid = ','.join(cids)
    else:
        # No file — hash the description as a placeholder
        evidence_hash = hashlib.sha256(description.encode()).hexdigest()

    blockchain_tx = None
    try:
        blockchain_tx = log_complaint_on_chain(complaint_id, evidence_hash)
    except Exception as e:
        # Don't fail the whole submission if the chain write fails — the complaint and its
        # hash are still saved in the database below. Logged so it can be retried/backfilled.
        print(f"[blockchain] failed to log complaint {complaint_id}: {e}")

    complaint = Complaint(
        complaint_id=complaint_id,
        user_id=user_id,
        description=description,
        evidence_hash=evidence_hash,
        ipfs_cid=ipfs_cid,
        blockchain_tx=blockchain_tx,
        latitude=latitude,
        longitude=longitude,
        location_source=location_source,
        category=category,
        anonymous=anonymous,
        status='SUBMITTED'
    )

    db.session.add(complaint)
    db.session.commit()

    response_data = {
        'message': 'Complaint submitted successfully',
        'complaint_id': complaint_id,
        'evidence_hash': evidence_hash,
        'status': 'SUBMITTED'
    }
    if ipfs_cid:
        response_data['ipfs_cid'] = ipfs_cid
        response_data['evidence'] = _evidence_list(ipfs_cid)
        response_data['ipfs_url'] = response_data['evidence'][0]['url']
    if blockchain_tx:
        response_data['blockchain_tx'] = blockchain_tx
        response_data['etherscan_url'] = f'https://sepolia.etherscan.io/tx/{blockchain_tx}'
    if latitude is not None or longitude is not None:
        response_data['latitude'] = latitude
        response_data['longitude'] = longitude
    if location_source is not None:
        response_data['location_source'] = location_source

    return jsonify(response_data), 201


def _evidence_list(ipfs_cid):
    return [
        {'cid': cid, 'url': f'https://gateway.pinata.cloud/ipfs/{cid}'}
        for cid in ipfs_cid.split(',') if cid
    ]


def _iso(value):
    return value.isoformat() + 'Z' if value else None


def _complaint_json(complaint):
    data = {
        'complaint_id': complaint.complaint_id,
        'status': complaint.status,
        'category': complaint.category,
        'anonymous': bool(complaint.anonymous),
        'description': complaint.description or '',
        'evidence_hash': complaint.evidence_hash,
        'has_evidence': bool(complaint.ipfs_cid),
        'latitude': complaint.latitude,
        'longitude': complaint.longitude,
        'location_source': complaint.location_source,
        'created_at': _iso(complaint.created_at),
        'updated_at': _iso(complaint.updated_at),
    }
    if complaint.ipfs_cid:
        data['ipfs_cid'] = complaint.ipfs_cid
        data['evidence'] = _evidence_list(complaint.ipfs_cid)
        data['ipfs_url'] = data['evidence'][0]['url']
    if complaint.blockchain_tx:
        data['blockchain_tx'] = complaint.blockchain_tx
        data['etherscan_url'] = f'https://sepolia.etherscan.io/tx/{complaint.blockchain_tx}'
    return data


@complaints_bp.route('/status/<complaint_id>', methods=['GET'])
@jwt_required()
def get_status(complaint_id):
    complaint = Complaint.query.filter_by(complaint_id=complaint_id).first()

    # Only the person who filed a report can see it. Answer "not found"
    # either way, so IDs can't be probed.
    if not complaint or str(complaint.user_id) != str(get_jwt_identity()):
        return jsonify({'error': 'Complaint not found'}), 404

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
