# SecureShe

Women's safety app: a Flask API (`app/`) and a Flutter client (`mobile/`),
with report evidence pinned to IPFS and its fingerprint logged on the
Sepolia blockchain (`blockchain/`).

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
