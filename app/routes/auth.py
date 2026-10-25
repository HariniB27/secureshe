from flask import Blueprint, request, jsonify
from app import db, bcrypt
from app.models import User
from flask_jwt_extended import create_access_token, create_refresh_token, jwt_required, get_jwt_identity

auth_bp = Blueprint('auth', __name__)

@auth_bp.route('/register', methods=['POST'])
def register():
    data = request.get_json()

    if not data or not all(k in data for k in ['name', 'email', 'password', 'phone']):
        return jsonify({'error': 'Missing required fields'}), 400

    if User.query.filter_by(email=data['email']).first():
        return jsonify({'error': 'Email already registered'}), 409

    hashed_password = bcrypt.generate_password_hash(data['password']).decode('utf-8')

    user = User(
        name=data['name'],
        email=data['email'],
        password=hashed_password,
        phone=data['phone']
    )

    db.session.add(user)
    db.session.commit()

    return jsonify({'message': 'User registered successfully'}), 201


@auth_bp.route('/login', methods=['POST'])
def login():
    data = request.get_json()

    if not data or not all(k in data for k in ['email', 'password']):
        return jsonify({'error': 'Missing email or password'}), 400

    user = User.query.filter_by(email=data['email']).first()

    if not user or not bcrypt.check_password_hash(user.password, data['password']):
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


@auth_bp.route('/verify-password', methods=['POST'])
@jwt_required()
def verify_password():
    """Re-checks the user's password without issuing a new token. Used to gate the
    complaints archive screen even while the user is already signed in."""
    data = request.get_json()
    if not data or 'password' not in data:
        return jsonify({'error': 'Missing password'}), 400

    user_id = get_jwt_identity()
    user = User.query.get(int(user_id))
    if not user or not bcrypt.check_password_hash(user.password, data['password']):
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

    data = request.get_json(silent=True) or {}

    name = (data.get('name') or '').strip()
    phone = (data.get('phone') or '').strip()

    if 'name' in data:
        if not name:
            return jsonify({'error': 'Name cannot be empty'}), 400
        user.name = name[:100]

    if 'phone' in data:
        if not phone:
            return jsonify({'error': 'Phone cannot be empty'}), 400
        user.phone = phone[:20]

    db.session.commit()
    return jsonify(_user_json(user)), 200


@auth_bp.route('/change-password', methods=['POST'])
@jwt_required()
def change_password():
    data = request.get_json(silent=True) or {}
    current = data.get('current_password') or ''
    new = data.get('new_password') or ''

    user = User.query.get(int(get_jwt_identity()))
    if not user:
        return jsonify({'error': 'User not found'}), 404

    if not bcrypt.check_password_hash(user.password, current):
        return jsonify({'error': 'Current password is incorrect'}), 401

    if len(new) < 8:
        return jsonify({'error': 'New password must be at least 8 characters'}), 400

    user.password = bcrypt.generate_password_hash(new).decode('utf-8')
    db.session.commit()
    return jsonify({'message': 'Password updated'}), 200


@auth_bp.route('/me', methods=['DELETE'])
@jwt_required()
def delete_me():
    """Permanently deletes the account and everything linked to it.
    Requires the password again, so a stolen unlocked phone can't do it
    with one tap."""
    from app.models import Complaint, TrustedContact, CommunityFlag

    data = request.get_json(silent=True) or {}
    user = User.query.get(int(get_jwt_identity()))
    if not user:
        return jsonify({'error': 'User not found'}), 404

    if not bcrypt.check_password_hash(user.password, data.get('password') or ''):
        return jsonify({'error': 'Password is incorrect'}), 401

    for model in (Complaint, TrustedContact, CommunityFlag):
        model.query.filter_by(user_id=user.id).delete()

    db.session.delete(user)
    db.session.commit()
    return jsonify({'message': 'Account deleted'}), 200
