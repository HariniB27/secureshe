# SecureShe review demo

About 5 minutes, on the iOS simulator against the shared Neon database.
Use a **throwaway account** and delete it at the end (Profile → Privacy &
Security → Delete account).

## Before the review (once)

```bash
git checkout main && git pull
python3 -m pip install -r requirements-dev.txt
PYTHONPATH=. python3 scripts/final_check.py      # every line should say OK
```

If `final_check.py` reports `crime_district rows: 0`, load the data first
(see README, "Historical crime data"). If the wallet is under 0.01 ETH, top it
up from a Sepolia faucet before the demo.

In the simulator, set the location to a city with crime data:
**Features → Location → Custom Location…** (Bengaluru: 12.9716, 77.5946).

## Start

Terminal 1, backend:

```bash
python3 run.py              # serves http://127.0.0.1:5050
```

Terminal 2, app:

```bash
open -a Simulator
cd mobile
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:5050
```

## Script

| Time | Do | Point out |
|---|---|---|
| 0:00 | **Register** a throwaway account (name, phone, email, password), then log in. | Real JWT auth; password rules match the server. |
| 0:40 | **Report** tab: category Harassment, keep the GPS location, attach a **photo** (camera or gallery), add a short description, **Submit Report**. | Evidence goes to IPFS (Pinata); only its SHA-256 fingerprint goes on-chain. |
| 1:30 | The report opens its **status** screen. Wait for the blockchain card to change from Pending to **"Confirmed on the blockchain"** (usually under a minute; it polls). Tap **View on Etherscan**. | Tamper-evidence: the transaction on Sepolia holds the complaint id and evidence hash. **View Evidence** opens the IPFS file. |
| 2:30 | **Map** tab: safety score near you, live reports (your report appears, rounded to ~110 m), switch 1 Hour / 24 Hours / This Week, plan a walking route and compare the scores. | Live reports + NCRB district data; route scoring adds road type and lighting at night. |
| 3:30 | **Circle** tab: **Add Contact** with a number verified in Twilio (E.164, e.g. `+91…`). | Max 5 contacts; cached on the phone for the offline fallback. |
| 4:00 | **Home**: hold the **SOS** button 3 seconds, let the countdown finish. | The server texts the circle through Twilio with a Google Maps link. |
| 4:45 | Profile → Privacy & Security → **Delete Account**. | Removes the user, reports and contacts from the database (on-chain hashes and IPFS files stay). |

## If something is down

| Service | What you see | What to do |
|---|---|---|
| **Pinata** (IPFS) | Submit with a file fails with "Could not reach the evidence storage service". | Submit the report **without** a file; it still gets a fingerprint and goes on-chain. Show an earlier report's evidence instead. |
| **Sepolia RPC** (Alchemy) or wallet out of ETH | Report saves but stays **Pending** (or **Failed** with Retry). | Explain the background worker retries; open an **existing confirmed report** from My Reports and its Etherscan link. |
| **Twilio** (or trial number not verified) | SOS says the server alert failed; on iOS the app says SIM texting is Android-only. | Show `POST /api/sos/trigger` output from `final_check.py --sos +91…` run earlier, or an Android device for the SIM fallback. |
| **Overpass** | Route scores still appear, without the road/lighting part. | Say the route check falls back to crime data only (covered by a test). |
| **OpenStreetMap tiles** | Grey map. | Scores, live report list and route checks still work; restart later. |
| **Neon** | Login spins, then errors. | Nothing works without the database. Fallback: run locally with `DATABASE_URL=sqlite:///secureshe.db` and register a fresh account (empty data, no crime layer unless loaded). |
