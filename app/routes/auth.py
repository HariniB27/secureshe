from flask import Blueprint, request, jsonify
from flask_jwt_extended import create_access_token, create_refresh_token, jwt_required, get_jwt_identity
from sqlalchemy import func

from app import db, bcrypt
from app.limiter import LOGIN_LIMIT, PASSWORD_LIMIT, REGISTER_LIMIT, limiter
from app.models import User
from app.validation import (
    MAX_NAME_LENGTH, MAX_PHONE_LENGTH, email_error, password_error,
)

auth_bp = Blueprint('auth', __name__)


def _json_body():
    body = request.get_json(silent=True)
    return body if isinstance(body, dict) else {}


def _find_by_email(email):
    return User.query.filter(func.lower(User.email) == email.lower()).first()


@auth_bp.route('/register', methods=['POST'])
@limiter.limit(REGISTER_LIMIT)
def register():
    data = _json_body()

    if not all(k in data for k in ['name', 'email', 'password', 'phone']):
        return jsonify({'error': 'Missing required fields'}), 400

    name = str(data['name']).strip()
    phone = str(data['phone']).strip()
    email = str(data['email']).strip()
    password = data['password']

    if not name or len(name) > MAX_NAME_LENGTH:
        return jsonify({'error': f'Name is required (at most {MAX_NAME_LENGTH} characters)'}), 400
    if not phone or len(phone) > MAX_PHONE_LENGTH:
        return jsonify({'error': f'Phone is required (at most {MAX_PHONE_LENGTH} characters)'}), 400

    problem = email_error(email) or password_error(password)
    if problem:
        return jsonify({'error': problem}), 400

    if _find_by_email(email):
        return jsonify({'error': 'Email already registered'}), 409

    user = User(
        name=name,
        email=email.lower(),
        password=bcrypt.generate_password_hash(password).decode('utf-8'),
        phone=phone,
    )
    db.session.add(user)
    db.session.commit()

    return jsonify({'message': 'User registered successfully'}), 201


@auth_bp.route('/login', methods=['POST'])
@limiter.limit(LOGIN_LIMIT)
def login():
    data = _json_body()

    if not all(k in data for k in ['email', 'password']):
        return jsonify({'error': 'Missing email or password'}), 400

    user = _find_by_email(str(data['email']).strip())

    password = data['password']
    if (
        not user
        or not isinstance(password, str)
        or len(password.encode('utf-8')) > 72
        or not bcrypt.check_password_hash(user.password, password)
    ):
        return jsonify({'error': 'Invalid credentials'}), 401

    access_token = create_access_token(identity=str(user.id))
    refresh_token = create_refresh_token(identity=str(user.id))

    return jsonify({
        'access_token': access_token,
        'refresh_token': refresh_token,
        'user': {
            'id': user.id,
            'name': user.name,
            'email': user.email
        }
    }), 200


@auth_bp.route('/refresh', methods=['POST'])
@jwt_required(refresh=True)
def refresh():
    """Silently mints a new access token from a still-valid refresh token, so the
    mobile app never has to show a login screen again unless the refresh token itself expires."""
    identity = get_jwt_identity()
    new_access_token = create_access_token(identity=identity)
    return jsonify({'access_token': new_access_token}), 200


def _password_matches(user, password):
    return (
        user is not None
        and isinstance(password, str)
        and len(password.encode('utf-8')) <= 72
        and bcrypt.check_password_hash(user.password, password)
    )


@auth_bp.route('/verify-password', methods=['POST'])
@limiter.limit(PASSWORD_LIMIT)
@jwt_required()
def verify_password():
    """Re-checks the user's password without issuing a new token. Used to gate the
    complaints archive screen even while the user is already signed in."""
    data = _json_body()
    if 'password' not in data:
        return jsonify({'error': 'Missing password'}), 400

    user = User.query.get(int(get_jwt_identity()))
    if not _password_matches(user, data['password']):
        return jsonify({'verified': False}), 401

    return jsonify({'verified': True}), 200


def _user_json(user):
    return {
        'id': user.id,
        'name': user.name,
        'email': user.email,
        'phone': user.phone,
        'created_at': user.created_at.isoformat() + 'Z' if user.created_at else None,
    }


@auth_bp.route('/me', methods=['GET'])
@jwt_required()
def get_me():
    """The signed-in user's profile, so the app can show it after a restart."""
    user = User.query.get(int(get_jwt_identity()))
    if not user:
        return jsonify({'error': 'User not found'}), 404
    return jsonify(_user_json(user)), 200


@auth_bp.route('/me', methods=['PUT'])
@jwt_required()
def update_me():
    """Update name and/or phone. Email changes aren't supported here."""
    user = User.query.get(int(get_jwt_identity()))
    if not user:
        return jsonify({'error': 'User not found'}), 404

    data = _json_body()

    if 'name' in data:
        name = str(data['name'] or '').strip()
        if not name:
            return jsonify({'error': 'Name cannot be empty'}), 400
        user.name = name[:MAX_NAME_LENGTH]

    if 'phone' in data:
        phone = str(data['phone'] or '').strip()
        if not phone:
            return jsonify({'error': 'Phone cannot be empty'}), 400
        user.phone = phone[:MAX_PHONE_LENGTH]

    db.session.commit()
    return jsonify(_user_json(user)), 200


@auth_bp.route('/change-password', methods=['POST'])
@limiter.limit(PASSWORD_LIMIT)
@jwt_required()
def change_password():
    data = _json_body()
    current = data.get('current_password') or ''
    new = data.get('new_password') or ''

    user = User.query.get(int(get_jwt_identity()))
    if not user:
        return jsonify({'error': 'User not found'}), 404

    if not _password_matches(user, current):
        return jsonify({'error': 'Current password is incorrect'}), 401

    problem = password_error(new)
    if problem:
        return jsonify({'error': problem}), 400

    user.password = bcrypt.generate_password_hash(new).decode('utf-8')
    db.session.commit()
    return jsonify({'message': 'Password updated'}), 200


@auth_bp.route('/me', methods=['DELETE'])
@limiter.limit(PASSWORD_LIMIT)
@jwt_required()
def delete_me():
    """Permanently deletes the account and everything linked to it in our
    database. Requires the password again, so a stolen unlocked phone can't do
    it with one tap."""
    from app.models import Complaint, TrustedContact, CommunityFlag

    data = _json_body()
    user = User.query.get(int(get_jwt_identity()))
    if not user:
        return jsonify({'error': 'User not found'}), 404

    if not _password_matches(user, data.get('password') or ''):
        return jsonify({'error': 'Password is incorrect'}), 401

    for model in (Complaint, TrustedContact, CommunityFlag):
        model.query.filter_by(user_id=user.id).delete()

    db.session.delete(user)
    db.session.commit()
    return jsonify({
        'message': (
            'Account deleted. Your profile, reports and contacts were removed from our '
            'database. Evidence fingerprints already written to the Sepolia blockchain '
            'and files already pinned to IPFS cannot be deleted.'
        )
    }), 200
