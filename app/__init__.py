from flask import Flask, jsonify

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

    # ---------------------------------------------------------
    # CONFIGURATION
    # ---------------------------------------------------------

    app.config["SQLALCHEMY_DATABASE_URI"] = os.getenv("DATABASE_URL")
    app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False

    # Hosted Postgres drops idle connections; check and recycle them so a
    # stale connection doesn't fail the next request.
    app.config["SQLALCHEMY_ENGINE_OPTIONS"] = {
        "pool_pre_ping": True,
        "pool_recycle": 300,
    }

    app.config["SECRET_KEY"] = os.getenv("SECRET_KEY")
    app.config["JWT_SECRET_KEY"] = os.getenv("JWT_SECRET_KEY")
    # Token lifetimes in minutes (defaults: 30 minutes / 30 days). Only
    # shortened to test what the app does when a session really ends.
    app.config["JWT_ACCESS_TOKEN_EXPIRES"] = timedelta(
        minutes=float(os.getenv("JWT_ACCESS_MINUTES", "30"))
    )
    app.config["JWT_REFRESH_TOKEN_EXPIRES"] = timedelta(
        minutes=float(os.getenv("JWT_REFRESH_MINUTES", str(30 * 24 * 60)))
    )

    # ---------------------------------------------------------
    # INITIALIZE EXTENSIONS
    # ---------------------------------------------------------

    db.init_app(app)

    bcrypt.init_app(app)

    jwt.init_app(app)

    from app.limiter import limiter

    limiter.init_app(app)

    # CORS only matters for browser clients (Flutter web); the phone app
    # doesn't use it. Off unless CORS_ORIGINS lists the origins to allow,
    # e.g. CORS_ORIGINS=http://localhost:5173,http://127.0.0.1:8080
    # ("*" allows everything: local experiments only).
    origins = [o.strip() for o in os.getenv("CORS_ORIGINS", "").split(",") if o.strip()]
    if origins:
        CORS(app, origins="*" if origins == ["*"] else origins)

    @app.errorhandler(429)
    def too_many_requests(_error):
        return jsonify({
            "error": "Too many requests. Please wait a moment and try again."
        }), 429

    # ---------------------------------------------------------
    # REGISTER ROUTES
    # ---------------------------------------------------------

    from app.routes.auth import auth_bp

    from app.routes.complaints import complaints_bp

    from app.routes.safety import safety_bp
    from app.routes.sos import sos_bp

    app.register_blueprint(auth_bp, url_prefix="/api/auth")
    app.register_blueprint(complaints_bp, url_prefix="/api/complaints")
    app.register_blueprint(safety_bp, url_prefix="/api/safety")
    # sos routes carry their own /api/... paths.
    app.register_blueprint(sos_bp)

    # ---------------------------------------------------------
    # DATABASE + BACKGROUND WORKER
    # ---------------------------------------------------------

    with app.app_context():
        _prepare_database(app)

    return app


def _prepare_database(app):
    """Never changes a shared database. A throwaway local SQLite file gets
    its tables created for convenience; anything else must be brought up to
    date with `python scripts/migrate.py` (and we say so if it isn't)."""
    from app.schema import find_schema_gaps

    if db.engine.dialect.name == "sqlite":
        db.create_all()

    missing_tables, missing_columns = find_schema_gaps(db.engine)
    app.config["SCHEMA_OK"] = not (missing_tables or missing_columns)

    if not app.config["SCHEMA_OK"]:
        print("[db] WARNING: the database schema is out of date, so some requests will fail.")
        for table in missing_tables:
            print(f"[db]   missing table : {table.name}")
        for table, columns in missing_columns.items():
            print(f"[db]   missing columns on {table}: {', '.join(c.name for c in columns)}")
        print("[db] Run:  python scripts/migrate.py --dry-run   (then without --dry-run)")
        print("[db] The blockchain worker is not started until the schema is current.")
        return

    # One process only. Under Flask's debug reloader the parent process also
    # imports the app, so skip it there and let the serving child start it.
    reloader_parent = app.debug and os.environ.get("WERKZEUG_RUN_MAIN") != "true"
    if os.getenv("CHAIN_WORKER", "1") != "0" and not reloader_parent:
        from app.chain_sync import start_worker

        start_worker(app)
