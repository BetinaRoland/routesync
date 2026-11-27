# RouteSync change log

## UI/UX redesign: navy, royal blue and pastel (latest)
Visual and navigation changes only. No service, Firebase, rules, data-structure or permission changes (`lib/services/`, the three rules files, `firebase.json` and `pubspec.lock` are untouched). Everything shown is read from Firestore or the live location feed; nothing is placeholder data.

**Foundation**
- Palette (`Brand`), radii (`Rd`), soft shadows, Sora headings, pale-blue page background; light and dark themes. The light/dark choice is saved (`core/theme_controller.dart`) and a toggle is in the top bar of every role and on the login screen.
- `assets/brand/routesync_bus_outline.png`: the outline bus sketch, extracted from the supplied reference sketch as transparent line art and tinted per theme (`BusOutline`). The old `logo.png` is a filled yellow bus and was not used as the sketch.
- `core/components.dart`: `BusOutline`, `RsCard`, `PageHeader`, `SummaryCard`, `SectionCard`, `ActionTile`, `ThemeToggleButton`, `ErrorState`.

**Navigation**
- Admin desktop: top bar (logo, page buttons, More menu, page search, theme toggle, notifications, account and role). No sidebar. Phones: bottom bar plus drawer. Each admin workspace has a header with the bus sketch.

**Pages**
- Admin dashboard: summary cards, live fleet map, active alerts (empty groups hidden), recent transport activity (`emergencyActions`, `changeRequests`), quick actions; Super Admin also gets an "Awaiting approval" card.
- Announcements: audience selection, message editor, live preview, published feed with audience filter.
- Feedback: inbox cards with search, open/closed filter and inline reply.
- Schedules: horizontal weekday tabs (Monday to Saturday) built from `collegeSchedules`, with holidays and special days that fall on the chosen weekday.
- Fee policy: fee calculator using the app's own `computeFee`, and policy cards showing active, scheduled or ended.
- Audit log: searchable timeline, role and action filters, expandable event cards showing every recorded field.
- Student: bus summary card with the bus sketch, visible "Report a problem", theme toggle. Driver: theme toggle, location sharing first. Login: bus sketch and theme toggle.

**Tests**
- `tone_colors_test.dart`, `theme_controller_test.dart`, `brand_assets_test.dart`.

**Not redesigned yet** (existing screens keep working with the new colours): Emergency command centre, Reports and analytics charts, Expenses dashboard, Route Admin approvals comparison, Tracking policy previews, Payment reconciliation, Bus utilisation charts, Daily allocation workspace, boarding-point and route map layouts, and the Student and Driver sub-screens.

## UI/UX redesign: royal blue and white (latest)
Visual and navigation changes only. No service, Firebase, rules, data-structure or permission changes (`lib/services/`, `firestore.rules`, `database.rules.json`, `storage.rules`, `firebase.json`, `pubspec.*` are untouched).

- **Theme** (`core/theme.dart`): royal blue (`royal`, #2A5BE0) and white in light mode; a lighter blue on a near-black page in dark mode. Royal blue header in light mode, 48-high buttons, outlined buttons with a blue border, clear focus outline on inputs, bigger tab labels with a thick underline. `navy` is kept as an alias of `royal` so existing code compiles. Spacing scale `Sp`; status tones (`Tone`, `toneColor`, `toneFor`) with 4.5:1 contrast in both modes.
- **Shared widgets** (`core/widgets.dart`): `statusPill`; `chip()` now follows the status tones in light and dark mode; error snackbars use the theme error colour; `selectedTint` (replaces `amberTint`).
- **Admin shell** (`admin_shell.dart`): permanent side menu on screens 900 px or wider; on phones a bottom bar (Home, People, Live map, Requests, More) plus the drawer. Tab bars share the full width when there is room and scroll only on narrow phones. Fixed shortcuts to Staff accounts, Audit log and Fee policy, which used to land on Settings.
- **Admin dashboard** (`overview_page.dart`): welcome banner, tiles grouped into "Needs attention" and "At a glance", each tile a button with an icon and chevron, 2 to 4 columns depending on width, screen-reader labels.
- **Student** (`student_home.dart`): "Track My Bus" card and bus row merged into one summary card ("Live now" / "Not live", full-screen map button); "Report a problem" is a visible app bar button.
- **Driver** (`driver_home.dart`): location sharing at the top with a larger button.
- **Other screens and login:** hardcoded red, orange, green and grey replaced by theme colours. Map pins and the live-map panel keep their own colours.
- **Tests:** `test/tone_colors_test.dart` checks status-colour contrast in light and dark mode and the old-colour mapping.

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
