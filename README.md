# RouteSync (free edition)

College bus management, allocation and live tracking. Flutter app on Firebase's **free Spark plan**: no Cloud Functions, no payments, no paid services. Four roles: Super Admin, Route Admin, Driver, Student. A student's own location is never collected.

## Features
- **Students:** invitation by code, link or QR; choose or request a boarding point (search or map pin); see the estimated fee (paid at the college office); bus, driver, stops, live map with road ETA; alternative bus; report problems and read replies; alerts and announcements.
- **Route Admin:** CSV import, buses, drivers, routes with due times, stops, schedules; review stop requests; automatic allocation and "free up buses" proposals with approval; suggestions screen; emergency bus, route and driver changes with expiry and revert; move or remove a student's bus; live map, bus health, alerts with history, location history, on-time report, Cost & Expenses management with receipt uploads and PDF/Excel reports.
- **Super Admin:** fee policy, college settings, staff accounts, audit log, read-only Cost & Expenses overview.
- **Driver:** bus, route, riders per stop, duty window, GPS sharing with offline catch-up, problem reports.
- **Trackers:** dedicated GPS devices register and sign in with their own account.
- Minimal light and dark interface.

## Start here
`RUN_GUIDE.md` has the step-by-step run instructions for the free plan. `CHANGES.md` is the change log. `docs/` has a privacy policy template, a release checklist and a sample student CSV.

## Not included (free plan)
Payments and refunds, AI assistant, push notifications, automatic invitation emails, server-side monitoring while nobody is logged in, two-factor sign-in, SMS, Excel import, translations, store listings.

## Cost & Expenses
Cost & Expenses records only college bus operating costs; student bus fees and payments remain outside RouteSync. Expenses use the existing Firestore `expenses` collection, with immutable edit snapshots in `expenseHistory`. Receipt files are stored under Firebase Storage `expenses/{expenseId}/` and are restricted to active admins by `storage.rules`. Enable the project's Storage bucket and deploy the configured Firestore, Storage, and index rules before using receipt uploads.

## Honest limits
- `flutter analyze` and `flutter test` can be run locally; Firebase rules still need emulator or Firebase Console verification and deployment before launch.
- Free quotas apply (about 100 simultaneous live-map viewers). See `RUN_GUIDE.md`.
