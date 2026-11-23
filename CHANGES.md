# RouteSync change log

## Free edition (latest)
Rebuilt to run on the free Firebase Spark plan, which cannot use Cloud Functions.

**Removed:** payments, refunds, Razorpay; the AI assistant; Cloud Functions, scheduler and Cloud Run optimiser; push notifications; invitation email extension; hardware ingest function; payment and AI packages (`cloud_functions`, `firebase_messaging`, `firebase_app_check`).

**Replaced:**
- Every server function now runs in the app (`lib/services/`), behind the same action names, so screens barely changed.
- Roles moved from sign-in claims to `users/{uid}` records checked by `firestore.rules`; small access lists in the Realtime Database (`database.rules.json`) decide who can read or write live locations.
- Student registration works through a hashed invitation record and rules, creating the account in the app.
- Staff, driver and tracker accounts are created from the admin app using a second Firebase app instance.
- Monitoring, alerts, delays and expiry checks run in the admin app while it is open; history lives in the Realtime Database and old days are purged automatically.
- Fee is shown to students as an estimate; fee policy page kept.
- Suggestions screen (rule-based) replaces the AI assistant; planners ported to Dart with tests (`test/logic_test.dart`).
- Announcements are one record read by students and drivers instead of per-person messages.
- `tools/seed_users.js` creates the first admins locally (works on the free plan).

**Limits to know:** seat limits are enforced by the admin app, not a server; monitoring needs an admin online; about 100 live viewers at once. See `RUN_GUIDE.md`.

---

## Applied from your setup notes
| File | Change |
|---|---|
| `lib/main.dart` | Imports `firebase_options.dart`; initialises Firebase with `DefaultFirebaseOptions.currentPlatform`. `BusApp`, `AuthGate`, session loading and role routing are kept. If Firebase fails to start, a readable error screen replaces the white page. |
| `pubspec.yaml` | `dev_dependencies` now has `flutter_test` and `flutter_lints: ^6.0.0`. Existing package versions unchanged apart from packages added for new features (see below). |
| `analysis_options.yaml` | New. Includes `flutter_lints`. |
| `test/widget_test.dart` | Replaced with the environment check you described. |
| `test/helpers_test.dart` | New. Unit tests for CSV escaping and stale-GPS detection. |
| `lib/firebase_options.dart` | **Not included.** Generated per machine by FlutterFire for project `routesync-94a88`. The sync script never overwrites it. |

## Analyzer clean-up
- `withOpacity` replaced with `withValues(alpha:)`.
- `DropdownButtonFormField(value:)` replaced with `initialValue:` (keyed where the parent changes the value).
- `ReorderableListView.onReorder` replaced with `onReorderItem`.
- Menus in `fleet_pages.dart` and `students_page.dart` use `else if` chains so `BuildContext` is not reused after an `await`.
- Not changed: the `package:flutter/material.dart` import deprecation. Migrate only after checking APIs.
- Fixed a latent crash: choosing the same bus as broken and replacement in Emergency.

## New features
- Overview home for admins with live counts and quick actions; drawer grouped into Operations, People, Network, Money, System.
- Announcements to everyone, students, drivers or one bus (in-app plus push).
- Student problem reports with admin inbox and replies.
- Driver "Report a problem" (breakdown, late, road blocked, accident) raising alerts.
- "Bus is nearby" notifications once per stop per day, using the bus and fixed stops only.
- Minimal flat theme, light and dark, bottom navigation for students, consistent empty states.

## New or changed packages
Added: `qr_flutter`, `url_launcher`, `firebase_messaging`, `flutter_lints`, `flutter_launcher_icons` (dev).

## Files by area
Modified: `lib/main.dart`, `lib/core/*`, `lib/features/*`, `functions/*.js`, rules, indexes, `pubspec.yaml`.
Created: `lib/features/admin/overview_page.dart`, `comms_pages.dart`, `lib/features/student/feedback_page.dart`, `test/*`, `analysis_options.yaml`, `tools/sync_into_project.ps1`.

## Round 3: remaining features
**Hardware and tracking**
- GPS devices: register a tracker per bus; its key is shown once and stored hashed; `gpsIngest` rejects wrong keys, devices not linked to the bus, stale and impossible data, and raises an alert.
- Driver phone keeps positions it could not send and uploads them to history when back online.
- Arrival time by road (`getEta`), refreshed every 30 seconds. No live traffic.
- On-time recording: first arrival at the college per journey, with a report by bus (CSV and PDF).

**Allocation and AI**
- "Free up buses": proposes moving riders so lightly used buses can be released; approval re-checks seats, routes and drivers.
- AI assistant tools: route list, overlapping routes, replacement-bus options, consolidation opportunities, rebalance proposals.
- Move one student to another bus (stop and seats checked).

**Emergency**
- Temporary route change (detour or closure) and driver replacement, both with expiry, review and revert. Alternative-bus riders now count on the driver's list.

**Money and reports**
- Expenses (fuel, maintenance, salary, insurance, tolls) with fees-versus-costs summary; PDF export on Reports, Costs and On-time.
- Razorpay refunds for fee reductions and duplicate payments.

**Security and sign-up**
- Invitation functions are rate limited and can enforce App Check; sign-in age limits (admins 12 h, drivers 24 h, students 72 h).
- QR scan for invitations on phones; place search when requesting a stop.

**Project**
- `RUN_GUIDE.md`, `docs/PRIVACY_POLICY.md` (template), `docs/RELEASE_CHECKLIST.md`, CI workflow, sample student CSV.

**New packages**: `http`, `pdf`, `printing`, `mobile_scanner`, `firebase_app_check`.

## Still not done
Two-factor sign-in (needs Firebase Identity Platform), SMS, web push, live-traffic ETA, Excel import, translations, store listings and signing. See `docs/RELEASE_CHECKLIST.md`.
