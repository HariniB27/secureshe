# SecureShe

Women's safety app: a Flask API (`app/`) and a Flutter client (`mobile/`),
with report evidence pinned to IPFS and its fingerprint logged on the
Sepolia blockchain (`blockchain/`).

**Stack:** Flask, SQLAlchemy and PostgreSQL (Neon; SQLite for local tests),
JWT auth, Pinata (IPFS), web3.py with the `SecureSheRegistry` contract on
Sepolia, Twilio for SOS texts. Flutter app with `flutter_map` on
**OpenStreetMap** tiles (no Mapbox), OSRM routing, Nominatim place search and
Overpass road/lighting data for route safety. NCRB district crime data
(`data/raw/crime_by_district.csv`) for the historical risk layer.

See `docs/IMPLEMENTATION_STATUS.md` for what is built and
`docs/DEMO.md` for the review demo.

## Backend

```bash
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env            # then fill it in; never commit .env
python scripts/migrate.py --dry-run   # see what would change in the database
python scripts/migrate.py             # apply it (asks you to confirm)
python run.py                   # serves http://127.0.0.1:5050
```

* The app **never changes a shared database by itself**. If the schema is
  behind it prints a warning at startup and tells you to run
  `scripts/migrate.py`. (A throwaway `sqlite:///...` file is created
  automatically.)
* Run **one** server process: the blockchain worker is a thread in it.
* `CORS_ORIGINS` is empty by default (the phone app doesn't need CORS). Set it
  only for Flutter web, e.g. `CORS_ORIGINS=http://localhost:5173`.
* Admin status updates need `ADMIN_API_KEY` in `.env`:
  `curl -X PATCH http://127.0.0.1:5050/api/complaints/<ID>/status -H "X-Admin-Key: $ADMIN_API_KEY" -H "Content-Type: application/json" -d '{"status":"UNDER_REVIEW"}'`
  Statuses, in order: `SUBMITTED, UNDER_REVIEW, INVESTIGATING, ACTION_TAKEN, RESOLVED`.

### Admin portal

A small server-rendered portal for reviewing reports: open
`http://127.0.0.1:5050/admin` and sign in with the shared `ADMIN_API_KEY`
(sessions last 30 minutes; 5 sign-in attempts per minute per IP). It shows
counts by status and chain state, the latest reports, a filtered list, and a
report page where you can move the status forward one step (written to the
database and on-chain, the same code as the `PATCH` above) or retry a failed
blockchain log. Reports marked anonymous never show a reporter.

* Without `ADMIN_API_KEY` every `/admin` page answers 503.
* **Do not expose it through a public tunnel or any internet-facing address.**
  Keep `HOST=127.0.0.1`, and if you must share your backend with a phone or
  teammate, share only the `/api` paths (for example a reverse proxy that
  blocks `/admin`). It sets an HttpOnly, SameSite=Strict cookie and security
  headers, but one shared key is not enough protection for the open internet.
* Limitations: one shared key (no per-admin identity), no audit log beyond what
  is written on-chain, no user management, no way to edit or delete reports.

### Historical crime data

The `crime_district` table must be loaded once (needs `pandas` and `geopy`):

```bash
pip install -r requirements-dev.txt
PYTHONPATH=. python3 scripts/load_crime_district.py --dry-run   # reports, writes nothing
PYTHONPATH=. python3 scripts/load_crime_district.py             # replaces crime_district
```

### Tests and live check

```bash
pip install -r requirements-dev.txt
pytest                                         # backend tests: throwaway SQLite, Pinata/chain/Twilio mocked
PYTHONPATH=. python3 scripts/final_check.py    # read-only check of the real Neon, Sepolia, Overpass, Twilio
cd mobile && flutter analyze && flutter test
```

`pytest` never uses your `.env` database. `final_check.py` does (read-only,
apart from `--sos +91...`, which creates and then deletes a throwaway user to
send one real SOS text).

### How a report reaches the blockchain

`POST /api/complaints/submit` saves the report, sends the `logComplaint`
transaction and **returns immediately** with its hash. A background worker
confirms the receipt and retries failures; the app shows the state
(`pending`, `confirmed`, `failed`) and a Retry button for failed ones
(`POST /api/complaints/<id>/retry-chain`).

## Flutter app

```bash
cd mobile
flutter pub get
flutter run
```

The app talks to `http://127.0.0.1:5050` by default (iOS simulator, desktop,
web) and to `http://10.0.2.2:5050` on the **Android emulator** (that is the
emulator's name for your computer). Override it with `--dart-define`:

| Where you run it | Command |
|---|---|
| iOS simulator / desktop / web | `flutter run` |
| Android emulator | `flutter run` (uses `10.0.2.2:5050` automatically) |
| A real phone on the same Wi-Fi | `HOST=0.0.0.0 python run.py`, then `flutter run --dart-define=API_BASE_URL=http://<your-computer-ip>:5050` |
| A hosted backend | `flutter run --dart-define=API_BASE_URL=https://api.example.com` |

On a real phone, plain `http://` to a LAN address needs an iOS
App Transport Security exception / Android cleartext permission in debug
builds; prefer `https` for anything beyond local testing.

Checks: `flutter analyze` and `flutter test`.

## Known limitations

* No encryption of evidence: files on IPFS are public to anyone with the CID.
* No push notifications; the Notifications screen is a log kept on the phone.
* Admin: a minimal local-only web portal at `/admin` (see above) or `PATCH /api/complaints/<id>/status`, both behind the one shared `ADMIN_API_KEY`: no per-admin identity, no audit log, no user management.
* The offline SOS fallback (texting from the SIM) works only on Android with a SIM.
* Twilio trial account: SOS texts reach only numbers verified in the Twilio console.
* `TWILIO_TRIAL_TEMPLATE` (trial accounts only): the SMS contains only the template name, **not** the location message, and the app tells the user so. Keep it unset for real use.
* Plain HTTP to a local backend by default (`http://127.0.0.1:5050`); use HTTPS for anything hosted.
* Rate limiting is in memory: it resets on restart and isn't shared across processes unless `RATELIMIT_STORAGE_URI` points at Redis.
* Free public OpenStreetMap services (tiles, OSRM, Nominatim, Overpass) are fine for a demo but not for launch traffic; if Overpass is down, route checks fall back to crime data only.

Full list: `docs/IMPLEMENTATION_STATUS.md`.
