from flask import Flask
from flask_sqlalchemy import SQLAlchemy
from flask_bcrypt import Bcrypt
from flask_jwt_extended import JWTManager
from flask_cors import CORS
from dotenv import load_dotenv
from datetime import timedelta
import os

load_dotenv()

db = SQLAlchemy()
bcrypt = Bcrypt()
jwt = JWTManager()

def create_app():
    app = Flask(__name__)

    app.config['SQLALCHEMY_ENGINE_OPTIONS'] = {
    'pool_pre_ping': True,
    'pool_recycle': 300,
     }
    app.config['SQLALCHEMY_DATABASE_URI'] = os.getenv('DATABASE_URL')
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
    app.config['SECRET_KEY'] = os.getenv('SECRET_KEY')
    app.config['JWT_SECRET_KEY'] = os.getenv('JWT_SECRET_KEY')
    app.config['JWT_ACCESS_TOKEN_EXPIRES'] = timedelta(minutes=30)
    app.config['JWT_REFRESH_TOKEN_EXPIRES'] = timedelta(days=30)

    db.init_app(app)
    bcrypt.init_app(app)
    jwt.init_app(app)
    # Dev-only: allows the Flutter web target to call this API across origins
    # during local testing. Tighten this before any real deployment.
    CORS(app)

    from app.routes.auth import auth_bp
    from app.routes.complaints import complaints_bp

    app.register_blueprint(auth_bp, url_prefix='/api/auth')
    app.register_blueprint(complaints_bp, url_prefix='/api/complaints')
    from app.routes.sos import sos_bp
    app.register_blueprint(sos_bp)
    with app.app_context():
        db.create_all()

    return app