from flask import Blueprint, request, jsonify
from app import db
from app.models import Complaint
from flask_jwt_extended import jwt_required, get_jwt_identity
import uuid
import hashlib

complaints_bp = Blueprint('complaints', __name__)

@complaints_bp.route('/submit', methods=['POST'])
@jwt_required()
def submit_complaint():
    user_id = get_jwt_identity()
    data = request.get_json()

    complaint_id = str(uuid.uuid4())[:8].upper()

    # Generate SHA-256 hash of description as placeholder
    # Later this will hash the actual evidence file
    evidence_hash = hashlib.sha256(
        data.get('description', '').encode()
    ).hexdigest()

    complaint = Complaint(
        complaint_id=complaint_id,
        user_id=user_id,
        description=data.get('description', ''),
        evidence_hash=evidence_hash,
        status='SUBMITTED'
    )

    db.session.add(complaint)
    db.session.commit()

    return jsonify({
        'message': 'Complaint submitted successfully',
        'complaint_id': complaint_id,
        'evidence_hash': evidence_hash,
        'status': 'SUBMITTED'
    }), 201


@complaints_bp.route('/status/<complaint_id>', methods=['GET'])
@jwt_required()
def get_status(complaint_id):
    complaint = Complaint.query.filter_by(complaint_id=complaint_id).first()

    if not complaint:
        return jsonify({'error': 'Complaint not found'}), 404

    return jsonify({
        'complaint_id': complaint.complaint_id,
        'status': complaint.status,
        'evidence_hash': complaint.evidence_hash,
        'created_at': complaint.created_at.isoformat()
    }), 200