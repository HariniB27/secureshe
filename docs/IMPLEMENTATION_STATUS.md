# SecureShe: implementation status

Written from the code on `main` at `739f74d` (merge of PR #7), read file by file;
the API table and limitations were corrected on `chore/final-cleanup`.
"Verified in use" means it was exercised in the iOS simulator or against the
real backend during review; everything else is read from code and has not been
run in this review.

Figma reference: the Figma Make export (read-only, not part of this repo).
Its router (`src/app/routes.tsx`) defines 14 screens. Status words:

* **Implemented**: the screen exists, is wired to real data or real behaviour,
  and matches the design's purpose.
* **Partial**: exists, but part of the design is missing, local-only, or labelled "Soon".
* **Not built**: nothing in the app.

## 1. Figma pages

| Figma page | Status | Flutter file(s) | Notes |
|---|---|---|---|
| Login | Implemented | `mobile/lib/screens/login_screen.dart`, `state/auth_state.dart`, `services/api_service.dart` | Real JWT login. Shows a "session expired" banner when a token is dead (`ApiService.onSessionExpired`, `main.dart`). Verified in use. |
| Register | Implemented | `screens/register_screen.dart`, `utils/validation.dart` | Name, phone, email, password with strength meter, confirm password, success step. Password minimum is `kMinPasswordLength` (same constant on the Privacy screen). |
| Home | Partial | `screens/home_screen.dart`, `services/sos_service.dart`, `state/shell_controller.dart` | Real: hold-to-SOS, quick audio and camera video capture, call-first-contact, nearby reports from `/api/safety/live-reports` (refresh every 1 min), "Start Safe Trip" sheet with place search, unread badge. Captured clips are held in memory only; "Attach it to a report" hands them to the Report tab (`ShellController.reportWith`). Nothing is uploaded from Home. The design's sample places (Hostel Block A, etc.) were mock data and are not used. |
| Report (3 steps) | Implemented | `screens/report_screen.dart`, `screens/location_picker_screen.dart`, `models/report.dart` | Categories `harassment`, `unsafe-area`, `suspicious`; location text plus GPS, or a manually chosen map pin; anonymous toggle; up to 5 evidence files (camera photo, in-app audio recorder, gallery photos and videos); clipboard paste into the description. Beyond the design: manual location override. Verified in use with photo + audio + video in one report. |
| Report status (`/report-status/:id`) | Implemented | `screens/report_status_screen.dart` | Status card, details, server-driven timeline (`status_flow`), "View Evidence" sheet that opens IPFS links in the browser, Share, blockchain card (Pending / Confirmed / Failed with Retry, Etherscan link when a tx hash is stored). Polls while the chain log is pending; pull to refresh. Verified in use. |
| Map | Implemented | `screens/map_screen.dart`, `widgets/map_widgets.dart`, `utils/map_clustering.dart`, `services/safety_api_service.dart`, `services/routing_service.dart` | OpenStreetMap tiles; heat / safe-zone / all layer modes; live reports clustered and refreshed every 10 s with 1 h / 24 h / week filters; community flags (dark street, harassment, suspicious, safe zone); district crime layer; route planner with per-route safety scoring via `/api/safety/route-check`; "unsafe area nearby" alert. Reviewed in code only in this pass. |
| Circle | Implemented | `screens/circle_screen.dart`, `state/contacts_state.dart` | Trusted contacts add, list, delete (max 5, server-enforced), call via the phone dialer, trip-share card. Contacts are cached on the device for the offline SOS fallback. |
| Profile | Partial | `screens/profile_screen.dart` | Real: profile header, stats (Safe Trips and SOS counts are local counters on this phone; Reports comes from the server), dark/light switch, log out, links to Personal Info, Privacy & Security, Notifications, My Reports, Evidence Archive, Help Center (opens an email to `support@secureshe.com`). "Rate SecureShe" only shows a "once the app is in the stores" message. |
| SOS confirm | Implemented | `screens/sos_confirm_screen.dart`, `services/sos_service.dart` | 3-second cancelable countdown, then location, then `/api/sos/trigger` (Twilio SMS). Falls back to sending SMS from the phone's SIM when offline or the server fails (Android only). Not exercised in this review (no SMS was sent). |
| Trip tracking (Figma file `StatusTracking.tsx`) | Partial | `screens/trip_tracking_screen.dart`, `state/trip_state.dart` | Follows a planned route: progress along it, midpoint check-in milestones, a local "You left your safe route" notification when you drift off it, automatic "arrived safely" near the destination, end trip, and sharing the trip by opening the phone's SMS app with a pre-filled message (`sms:` link). Nothing is sent to the circle automatically (off-route or missed check-in only notifies this phone), and there is no background tracking (see limitations). |
| Notifications | Partial | `screens/notifications_screen.dart`, `state/app_prefs.dart` | Real list with read/unread, but it is a log kept on this phone of things the app itself did (SOS sent, trip done, report submitted, flag added, nearby alert). There is no server push, so "Report Status Updated" from the design only appears if the user opens the report. |
| Personal information | Partial | `screens/personal_info_screen.dart`, `PUT /api/auth/me` | Name and phone are saved on the server. Date of birth, gender, city, blood type, allergies and medical notes are stored only on this phone (`AppPrefs.savePersonalExtras`); the server has no columns for them. Email is read-only. |
| Privacy & Security | Partial | `screens/privacy_security_screen.dart` | Implemented: change password (server), biometric lock (local, checked at app start), include-location-when-sharing toggle, anonymous-by-default toggle, privacy policy sheet, "Copy My Data" (text built on the device from `/mine`, contacts, profile), delete account (password re-check, server deletes the user's data). Shown as "Soon" and not working: Two-Factor Authentication, Stealth Mode. Design items not built: Active Sessions, Marketing Emails and Crash Reports toggles (the preferences exist in `AppPrefs` but no screen uses them). |
| Root / layout shell | Implemented | `screens/app_shell.dart`, `main.dart` | Five-tab bottom bar and route table. |

Screens that exist in the app but not in the Figma export: **Evidence Archive**
(`archive_lock_screen.dart`, a biometric/password gate via
`/api/auth/verify-password`, then `my_reports_screen.dart`) and **Location
picker** (`location_picker_screen.dart`).

## 2. Backend endpoints

All routes are under `app/routes/`. "JWT" means a valid access token is
required. Rate limits come from `app/limiter.py` and are configurable by
environment variable.

### Auth, `/api/auth` (`auth.py`)

| Method and path | Auth | What it does |
|---|---|---|
| `POST /register` | none, rate-limited | Creates a user (name, email, phone, password). Passwords are bcrypt-hashed. |
| `POST /login` | none, rate-limited | Checks email and password; returns an access and a refresh token. |
| `POST /refresh` | refresh JWT | Returns a new access token. |
| `POST /verify-password` | JWT, rate-limited | Re-checks the current user's password without issuing a token (used by the Evidence Archive gate). |
| `GET /me` | JWT | Returns the signed-in user's profile. |
| `PUT /me` | JWT | Updates name and/or phone. Email cannot be changed. |
| `POST /change-password` | JWT, rate-limited | Requires the current password; applies the password minimum. |
| `DELETE /me` | JWT, rate-limited | Requires the password; deletes the user and their complaints, contacts and flags from our database. It does not and cannot remove files already pinned to IPFS or records on-chain. |

### Complaints, `/api/complaints` (`complaints.py`, `chain_sync.py`, `blockchain.py`)

| Method and path | Auth | What it does |
|---|---|---|
| `POST /submit` | JWT | Multipart form: `description`, optional `category` (`harassment`, `unsafe-area`, `suspicious`), `lat`+`lng` (both or neither), `location_source`, `location_text`, `anonymous`, and up to 5 repeated `evidence` files. Uploads each file to Pinata (IPFS), computes the evidence hash (see below), saves the row immediately as `chain_status=pending`, and returns 201 without waiting for the blockchain. |
| `GET /status/<id>` | JWT, owner only | One of your reports: status, evidence list (CID and gateway URL), `chain_status`, Etherscan URL (only if a tx hash is stored), retry flag, `status_on_chain`, `status_flow`. |
| `GET /mine` | JWT | Your reports, newest first. |
| `POST /<id>/retry-chain` | JWT, owner only, rate-limited | Re-attempts the on-chain log for a report whose chain status is `failed`. |
| `PATCH /<id>/status` | header `X-Admin-Key` = `ADMIN_API_KEY`, rate-limited | Moves a report along the status flow (`SUBMITTED` to `RESOLVED`) and queues the on-chain status update. Returns 503 if `ADMIN_API_KEY` is unset and 403 for a wrong key. There is no admin screen; it is called by hand. |

**Evidence hash.** No files: sha256 of the description text. One file: sha256
of the file's bytes. Several files: sha256 of the per-file sha256 hex strings
joined with no separator, in upload order. The hash is written to the contract
by `logComplaint(complaintId, evidenceHash)`.

**Blockchain worker (`chain_sync.py`).** Starts with the app unless
`CHAIN_WORKER=0` or the database schema is out of date. It sends pending logs,
confirms receipts, retries up to `CHAIN_MAX_ATTEMPTS` (default 3), marks
`failed` after that, reconciles reports already on-chain, and syncs admin
status changes on-chain. Gas is the node's estimate times 1.3, capped by
`CHAIN_MAX_GAS` (3,000,000).

### Safety, `/api/safety` (`safety.py`)

| Method and path | Auth | What it does |
|---|---|---|
| `GET /score?lat=&lng=` | none | Safety score and band for a point (live reports plus historical district data). Echoes the caller's own query coordinates at full precision; the nearby report spots it lists are rounded to 3 decimals, with no ids. |
| `POST /scores/batch` | none | Same, for a list of `{lat, lng}` points. |
| `GET /heatmap?district=&state=` | none | Report points within 25 km of a district centre from the crime dataset. An unknown district (or an empty `crime_district` table) returns 200 with `matched: false` and no points, not a 404. |
| `GET /live-reports?hours=` or `?since=` | none | Recent reports as GeoJSON for the map. Public data only: coordinates rounded to 3 decimals, a timestamp (`reported_at`, `age_hours`), a recency weight and the internal numeric row id (`properties.id`, used by the app to de-duplicate; not the complaint id). No description or complaint id. Anonymous reports excluded (they still count in scoring). |
| `GET /crime-points` | none | Alias of `/live-reports`, kept for older app builds. |
| `GET /historical-crime-points` | none | District-level historical crime points (latest year per district, NCRB data loaded by `scripts/load_crime_district.py`). |
| `POST /route-check` | none | Scores up to a fixed maximum of candidate routes (live and historical risk plus a night factor). |
| `POST /flags` | JWT | Adds a community flag (`dark-street`, `harassment`, `suspicious`, `safe-zone`) at a location; limited per user per hour. |
| `GET /flags?hours=` | none | Recent flags, public data only. |

### SOS, `/api/sos` (`sos.py`)

| Method and path | Auth | What it does |
|---|---|---|
| `GET /contacts` | JWT | Your trusted contacts. |
| `POST /contacts` | JWT | Adds one (max 5). |
| `DELETE /contacts/<id>` | JWT | Removes one of yours. |
| `POST /trigger` | JWT | Texts every trusted contact through Twilio with your name and a Google Maps link to the given latitude/longitude. Returns per-contact results; 502 if none were sent. |

### Other server pieces

* `app/schema.py` and `scripts/migrate.py`: the app never alters a shared
  database; migrations are applied by hand (`--dry-run` first).
* `scripts/load_crime_*.py`, `build_district_baseline.py`: load the crime dataset.
* `blockchain/contracts/SecureSheRegistry.sol`: `logComplaint`, `updateStatus`,
  `getComplaint`, owner-only writes. Deployed on Sepolia at
  `0x49bA0B8FbBeF9Be19104f8f90E60A6CA3e5622ad`.

## 3. Known limitations

**Evidence and privacy**
1. Evidence is **not encrypted**. Files are uploaded to Pinata/IPFS as they are, and IPFS links are public to anyone who has the CID. A design for client-side encryption has been proposed but not built.
2. The blockchain stores only a hash, an id, a status and a timestamp, never the files. The hash proves the files have not changed since submission. It does not prove the files are genuine.
3. IPFS content cannot be reliably deleted. Deleting an account removes our database rows, not pinned files or on-chain records.
4. The server and Pinata can see descriptions, locations, categories, timing and file sizes. "Anonymous" hides the reporter from the public map and lists, not from the server.
5. There is no per-file or total byte limit on upload. The server enforces a 5-file cap and a 30-second timeout per file to Pinata, and it reads each file fully into memory. The app enforces the 5-file cap and re-encodes photos at quality 85. Pinata's own maximum was not tested.
6. Reports 2F15C0EA and E789F6F3 were confirmed on-chain with an empty `blockchain_tx`; they have since been backfilled. `scripts/final_check.py` checks that every complaint row has a tx hash and `chain_status = confirmed`.

**Blockchain**
7. If the chain log fails three times the report is marked `failed`; the user can retry from the status screen, but nothing alerts anyone.
8. The backend wallet needs Sepolia ETH. A drained wallet means new reports stay pending or fail while still being saved.
9. Status changes are made through `PATCH /<id>/status` with a shared admin key. There is no admin app, no per-admin identity, and no audit trail beyond the chain.

**App**
10. Notifications are a local log; there is no push notification service.
11. Personal-information extras (date of birth, gender, city, blood type, allergies, medical notes) live only on the phone and are lost on reinstall or a new device.
12. Two-Factor Authentication and Stealth Mode are shown as "Soon". Active Sessions, Marketing Emails and Crash Reports from the design are not built.
13. The Safe Trips and SOS Sent counters on Profile are local to the phone.
14. Trip tracking never alerts the circle automatically (off-route and check-in warnings stay on this phone), and it has no background location (no background-location setting in the iOS config or the code), so it only works while the app is open.
15. Direct SMS from the SIM for offline SOS works only on Android with a SIM. On iOS the offline fallback does not send anything; the app says so and tells the user to call instead.
16. SOS texts depend on Twilio credentials and, on a trial Twilio account, on verified destination numbers. Not exercised in this review.
17. The default API address is `http://127.0.0.1:5050` (`http://10.0.2.2:5050` on Android emulators). A real device needs `--dart-define=API_BASE_URL=...`, and the connection is plain HTTP.
18. Map tiles, place search and walking/driving routes use free public OpenStreetMap services (see the note in `routing_service.dart`), which are not suitable for public-launch traffic.

**Backend and operations**
19. The backend test suite (`tests/`, run with `pytest`) uses a throwaway SQLite database with Pinata, the chain and Twilio mocked, so it does not prove the live services work; `scripts/final_check.py` checks those. The Flutter tests cover the JSON/error helpers and `Report.fromJson` only.
20. Rate limiting uses in-memory storage, so it resets on restart and does not work across multiple processes unless `RATELIMIT_STORAGE_URI` points at Redis.
21. The backend log shows a library warning that the JWT signing key in the local `.env` is 25 bytes, below the recommended 32. Rotating it signs every user out.
22. `app/routes/sos.py` still contains the original pasted migration and registration notes in comments. Without the Twilio variables `POST /api/sos/trigger` returns 503 and the app falls back to SIM SMS (Android only).
23. Shared Neon database round trips take about 350 ms from a laptop, so list screens feel slower than on a local database.
24. Only the iOS simulator build was run in this review. The Android build, a physical device and the Flutter web target were not tested.
