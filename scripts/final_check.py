"""Pre-review live check against the REAL services in .env (Neon, Sepolia,
Overpass, optionally Twilio). Prints evidence, never secrets.

    PYTHONPATH=. python3 scripts/final_check.py
    PYTHONPATH=. python3 scripts/final_check.py --sos +91XXXXXXXXXX

Read-only, except with --sos: that creates a throwaway user, adds the given
number as its only trusted contact, calls POST /api/sos/trigger (a real
Twilio SMS; on a trial account the number must be verified in Twilio), and
then deletes the throwaway user again.

It never runs migrations, never touches existing complaint rows and never
sends a blockchain transaction.
"""
import os
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# No background chain worker: this script must not send transactions.
os.environ["CHAIN_WORKER"] = "0"

from app import create_app, db  # noqa: E402
from app.models import Complaint, CrimeDistrict  # noqa: E402

LOW_BALANCE_ETH = 0.01
results = []


def record(item, ok, evidence):
    results.append((item, ok, evidence))
    print(f"[{'OK' if ok else 'FAIL'}] {item}: {evidence}")


def check_database(app):
    with app.app_context():
        dialect = db.engine.dialect.name
        host = db.engine.url.host or "(local file)"
        record("database", dialect == "postgresql",
               f"{dialect} at {host}; schema current: {app.config.get('SCHEMA_OK')}")

        districts = CrimeDistrict.query.count()
        record("crime_district rows", districts > 0, f"{districts} rows")

        total = Complaint.query.count()
        confirmed = Complaint.query.filter(
            Complaint.blockchain_tx.isnot(None),
            Complaint.chain_status == "confirmed",
        ).count()
        not_confirmed = [
            f"{c.complaint_id}:{c.chain_status}"
            for c in Complaint.query.filter(
                (Complaint.blockchain_tx.is_(None)) | (Complaint.chain_status != "confirmed")
            ).all()
        ]
        record("complaints confirmed on chain", total == confirmed,
               f"{confirmed}/{total} have a tx hash and chain_status=confirmed"
               + (f"; not confirmed: {', '.join(not_confirmed)}" if not_confirmed else ""))


def check_endpoints(app):
    client = app.test_client()
    r = client.get("/api/safety/historical-crime-points")
    body = r.get_json(silent=True) or {}
    points = body.get("points") or body.get("features") or []
    record("GET /historical-crime-points", r.status_code == 200 and len(points) > 0,
           f"HTTP {r.status_code}, {len(points)} points")

    with app.app_context():
        row = CrimeDistrict.query.filter(CrimeDistrict.latitude.isnot(None)).first()
    district = row.district if row else "Bengaluru City"
    r = client.get("/api/safety/heatmap", query_string={"district": district})
    body = r.get_json(silent=True) or {}
    record("GET /heatmap (known district)", r.status_code == 200 and body.get("matched") is True,
           f"district={district!r}: HTTP {r.status_code}, matched={body.get('matched')}")

    r = client.get("/api/safety/heatmap", query_string={"district": "No Such District"})
    record("GET /heatmap (unknown district)", r.status_code == 200,
           f"HTTP {r.status_code} (should be 200 with no points)")

    r = client.get("/api/safety/score", query_string={"lat": 12.9716, "lng": 77.5946})
    body = r.get_json(silent=True) or {}
    record("GET /score", r.status_code == 200,
           f"HTTP {r.status_code}, score={body.get('safety_score')} band={body.get('band')} "
           f"historical_risk={body.get('historical_risk')}")

    route = {"routes": [{"points": [[12.9716, 77.5946], [12.9750, 77.6000]], "distance_m": 700}], "hour": 21}
    r = client.post("/api/safety/route-check", json=route)
    body = r.get_json(silent=True) or {}
    record("POST /route-check", r.status_code == 200,
           f"HTTP {r.status_code}, Overpass reachable={body.get('environment_checked')} "
           "(False means it fell back to crime data only)")


def check_wallet():
    try:
        from web3 import Web3
        from eth_account import Account

        w3 = Web3(Web3.HTTPProvider(os.getenv("WEB3_PROVIDER_URL"), request_kwargs={"timeout": 15}))
        address = Account.from_key(os.getenv("BACKEND_WALLET_PRIVATE_KEY")).address
        balance = float(Web3.from_wei(w3.eth.get_balance(address), "ether"))
        ok = balance >= LOW_BALANCE_ETH
        record("wallet Sepolia balance", ok,
               f"{address}: {balance:.4f} ETH" + ("" if ok else f" (WARNING: under {LOW_BALANCE_ETH} ETH)"))
        code = w3.eth.get_code(Web3.to_checksum_address(os.getenv("CONTRACT_ADDRESS")))
        record("contract deployed", len(code) > 0, f"{os.getenv('CONTRACT_ADDRESS')}: {len(code)} bytes of code")
    except Exception as exc:  # noqa: BLE001
        # Only the error type: the message can contain the RPC URL, and an
        # Alchemy URL carries the API key.
        record("wallet Sepolia balance", False, f"could not check ({type(exc).__name__}); is the RPC reachable?")


def check_sos(app, number):
    client = app.test_client()
    email = f"sos-check-{uuid.uuid4().hex[:8]}@example.com"
    password = uuid.uuid4().hex
    client.post("/api/auth/register", json={"name": "SOS Check", "email": email,
                                            "password": password, "phone": number})
    token = client.post("/api/auth/login", json={"email": email, "password": password}).get_json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}
    try:
        client.post("/api/sos/contacts", headers=headers, json={"name": "Verified test", "phone_number": number})
        r = client.post("/api/sos/trigger", headers=headers, json={"latitude": 12.9716, "longitude": 77.5946})
        body = r.get_json(silent=True) or {}
        sids = [x.get("sid") for x in body.get("results", []) if x.get("sid")]
        errors = [x.get("error") for x in body.get("results", []) if x.get("error")]
        record("POST /api/sos/trigger", r.status_code == 200,
               f"HTTP {r.status_code}, Twilio SID(s): {sids or 'none'}"
               + (f", errors: {errors}" if errors else "")
               + (f", error: {body.get('error')}" if body.get("error") else ""))
    finally:
        d = client.delete("/api/auth/me", headers=headers, json={"password": password})
        print(f"       throwaway user deleted: HTTP {d.status_code}")


def main():
    app = create_app()
    check_database(app)
    check_endpoints(app)
    check_wallet()

    if "--sos" in sys.argv:
        check_sos(app, sys.argv[sys.argv.index("--sos") + 1])
    else:
        twilio_set = all(os.getenv(v) for v in ("TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN", "TWILIO_FROM_NUMBER"))
        record("Twilio settings in .env", twilio_set,
               "present (run again with --sos +91<verified number> to send a real SMS)"
               if twilio_set else "missing: SOS texts will fail with HTTP 503 and the app falls back to SIM SMS")

    print("\nSUMMARY")
    for item, ok, evidence in results:
        print(f"| {item} | {'yes' if ok else 'NO'} | {evidence} |")


if __name__ == "__main__":
    main()
