from flask import Blueprint, request, jsonify
from app import db
from app.models import Complaint
from flask_jwt_extended import jwt_required, get_jwt_identity

import uuid
import hashlib
import os
import requests

from app.blockchain import log_complaint_on_chain


complaints_bp = Blueprint("complaints", __name__)


PINATA_API_KEY = os.getenv("PINATA_API_KEY")
PINATA_SECRET_API_KEY = os.getenv("PINATA_SECRET_API_KEY")
PINATA_PIN_URL = "https://api.pinata.cloud/pinning/pinFileToIPFS"


def upload_to_pinata(file_bytes, filename):
    """Upload file bytes to Pinata IPFS. Returns CID string or raises."""

    headers = {
        "pinata_api_key": PINATA_API_KEY,
        "pinata_secret_api_key": PINATA_SECRET_API_KEY,
    }

    files = {
        "file": (filename, file_bytes)
    }

    response = requests.post(
        PINATA_PIN_URL,
        headers=headers,
        files=files,
        timeout=30,
    )

    response.raise_for_status()

    return response.json()["IpfsHash"]


@complaints_bp.route("/submit", methods=["POST"])
@jwt_required()
def submit_complaint():

    user_id = get_jwt_identity()

    # ---------------------------------------------------------
    # Read request data.
    # Supports both:
    #   multipart/form-data
    #   application/json
    # ---------------------------------------------------------

    if request.is_json:
        data = request.get_json(silent=True) or {}

        description = data.get("description", "")

        latitude = data.get("latitude")
        longitude = data.get("longitude")

    else:
        description = request.form.get("description", "")

        latitude = request.form.get("latitude")
        longitude = request.form.get("longitude")

    # ---------------------------------------------------------
    # Validate crime location.
    # ---------------------------------------------------------

    if latitude is None or longitude is None:
        return jsonify({
            "error": "Crime location is required. Please provide latitude and longitude."
        }), 400

    try:
        latitude = float(latitude)
        longitude = float(longitude)

    except (TypeError, ValueError):
        return jsonify({
            "error": "Latitude and longitude must be valid numbers."
        }), 400

    # ---------------------------------------------------------
    # Validate coordinate ranges.
    # ---------------------------------------------------------

    if not -90 <= latitude <= 90:
        return jsonify({
            "error": "Invalid latitude."
        }), 400

    if not -180 <= longitude <= 180:
        return jsonify({
            "error": "Invalid longitude."
        }), 400

    # ---------------------------------------------------------
    # Generate complaint ID.
    # ---------------------------------------------------------

    complaint_id = str(uuid.uuid4())[:8].upper()

    ipfs_cid = None
    evidence_hash = None

    # ---------------------------------------------------------
    # Handle evidence file.
    # ---------------------------------------------------------

    evidence_file = request.files.get("evidence")

    if evidence_file:

        file_bytes = evidence_file.read()

        evidence_hash = hashlib.sha256(
            file_bytes
        ).hexdigest()

        if PINATA_API_KEY and PINATA_SECRET_API_KEY:

            try:

                ipfs_cid = upload_to_pinata(
                    file_bytes,
                    evidence_file.filename or "evidence",
                )

            except requests.HTTPError as e:

                return jsonify({
                    "error": f"Pinata upload failed: {e.response.text}"
                }), 502

            except requests.RequestException as e:

                return jsonify({
                    "error": f"Pinata connection error: {str(e)}"
                }), 502

        else:

            return jsonify({
                "error": "Pinata API keys not configured"
            }), 500

    else:

        # No evidence file.
        # Hash the description so the complaint still
        # has an evidence hash.

        evidence_hash = hashlib.sha256(
            description.encode()
        ).hexdigest()

    # ---------------------------------------------------------
    # Blockchain logging.
    # ---------------------------------------------------------

    blockchain_tx = None

    try:

        blockchain_tx = log_complaint_on_chain(
            complaint_id,
            evidence_hash,
        )

    except Exception as e:

        # Do not fail the complaint submission if blockchain
        # logging fails.

        print(
            f"[blockchain] failed to log complaint "
            f"{complaint_id}: {e}"
        )

    # ---------------------------------------------------------
    # Save complaint.
    #
    # IMPORTANT:
    # latitude and longitude are the ACTUAL crime location.
    # They are NOT district coordinates.
    # ---------------------------------------------------------

    complaint = Complaint(
        complaint_id=complaint_id,
        user_id=user_id,
        description=description,

        latitude=latitude,
        longitude=longitude,

        evidence_hash=evidence_hash,
        ipfs_cid=ipfs_cid,
        blockchain_tx=blockchain_tx,

        status="SUBMITTED",
    )

    db.session.add(complaint)

    db.session.commit()

    # ---------------------------------------------------------
    # Response.
    # ---------------------------------------------------------

    response_data = {
        "message": "Complaint submitted successfully",

        "complaint_id": complaint_id,

        "latitude": latitude,
        "longitude": longitude,

        "evidence_hash": evidence_hash,

        "status": "SUBMITTED",
    }

    if ipfs_cid:

        response_data["ipfs_cid"] = ipfs_cid

        response_data["ipfs_url"] = (
            f"https://gateway.pinata.cloud/ipfs/{ipfs_cid}"
        )

    if blockchain_tx:

        response_data["blockchain_tx"] = blockchain_tx

        response_data["etherscan_url"] = (
            f"https://sepolia.etherscan.io/tx/{blockchain_tx}"
        )

    return jsonify(response_data), 201


@complaints_bp.route("/status/<complaint_id>", methods=["GET"])
@jwt_required()
def get_status(complaint_id):

    complaint = Complaint.query.filter_by(
        complaint_id=complaint_id
    ).first()

    if not complaint:

        return jsonify({
            "error": "Complaint not found"
        }), 404

    data = {
        "complaint_id": complaint.complaint_id,

        "status": complaint.status,

        "evidence_hash": complaint.evidence_hash,

        "created_at": complaint.created_at.isoformat(),

        "latitude": complaint.latitude,

        "longitude": complaint.longitude,
    }

    if complaint.ipfs_cid:

        data["ipfs_cid"] = complaint.ipfs_cid

        data["ipfs_url"] = (
            f"https://gateway.pinata.cloud/ipfs/{complaint.ipfs_cid}"
        )

    if complaint.blockchain_tx:

        data["blockchain_tx"] = complaint.blockchain_tx

        data["etherscan_url"] = (
            f"https://sepolia.etherscan.io/tx/{complaint.blockchain_tx}"
        )

    return jsonify(data), 200