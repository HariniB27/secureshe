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

    description = request.form.get('description', '') if request.form else request.get_json(silent=True, force=True).get('description', '')

    lat_raw = request.form.get('lat') if request.form else None
    lng_raw = request.form.get('lng') if request.form else None
    try:
        latitude = float(lat_raw) if lat_raw not in (None, '') else None
        longitude = float(lng_raw) if lng_raw not in (None, '') else None
    except ValueError:
        return jsonify({'error': 'lat/lng must be valid numbers'}), 400

    complaint_id = str(uuid.uuid4())[:8].upper()
    ipfs_cid = None
    evidence_hash = None

    evidence_file = request.files.get('evidence')
    if evidence_file:
        file_bytes = evidence_file.read()
        evidence_hash = hashlib.sha256(file_bytes).hexdigest()

        if PINATA_API_KEY and PINATA_SECRET_API_KEY:
            try:
                ipfs_cid = upload_to_pinata(file_bytes, evidence_file.filename or 'evidence')
            except requests.HTTPError as e:
                return jsonify({'error': f'Pinata upload failed: {e.response.text}'}), 502
            except requests.RequestException as e:
                return jsonify({'error': f'Pinata connection error: {str(e)}'}), 502
        else:
            return jsonify({'error': 'Pinata API keys not configured'}), 500
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
        response_data['ipfs_url'] = f'https://gateway.pinata.cloud/ipfs/{ipfs_cid}'
    if blockchain_tx:
        response_data['blockchain_tx'] = blockchain_tx
        response_data['etherscan_url'] = f'https://sepolia.etherscan.io/tx/{blockchain_tx}'
    if latitude is not None or longitude is not None:
        response_data['latitude'] = latitude
        response_data['longitude'] = longitude

    return jsonify(response_data), 201


@complaints_bp.route('/status/<complaint_id>', methods=['GET'])
@jwt_required()
def get_status(complaint_id):
    complaint = Complaint.query.filter_by(complaint_id=complaint_id).first()

    if not complaint:
        return jsonify({'error': 'Complaint not found'}), 404

    data = {
        'complaint_id': complaint.complaint_id,
        'status': complaint.status,
        'evidence_hash': complaint.evidence_hash,
        'created_at': complaint.created_at.isoformat()
    }
    if complaint.ipfs_cid:
        data['ipfs_cid'] = complaint.ipfs_cid
        data['ipfs_url'] = f'https://gateway.pinata.cloud/ipfs/{complaint.ipfs_cid}'
    if complaint.blockchain_tx:
        data['blockchain_tx'] = complaint.blockchain_tx
        data['etherscan_url'] = f'https://sepolia.etherscan.io/tx/{complaint.blockchain_tx}'

    return jsonify(data), 200
