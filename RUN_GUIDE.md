# RouteSync (free edition): how to run it

Everything runs on Firebase's **free Spark plan**. There are no Cloud Functions, no payments, no paid APIs. Windows and PowerShell steps. About 30 minutes the first time.

## What changed to make it free
| Removed | Replaced by |
|---|---|
| Online payments, refunds | Fee is calculated and shown; the student pays at the college office |
| AI assistant (paid API) | Suggestions screen: rule-based tips and proposals |
| Cloud Functions (need a paid plan) | The app does the work; Firestore and Realtime Database rules enforce who may do what |
| Server monitoring and scheduler | Monitoring runs while an admin has the app open |
| Push notifications, invitation emails | In-app alerts and announcements; Email button opens your mail app |
| Cloud Run optimiser | Built-in allocator |
| Hardware ingest function | Each GPS tracker signs in with its own account and writes directly |

## 0. Install once
Flutter (stable) with Chrome, Node.js 20 (only for the account script and Firebase CLI), then `npm install -g firebase-tools` and `dart pub global activate flutterfire_cli`.

## 1. Put the package in your project
```powershell
cd C:\Temp\routesync
powershell -ExecutionPolicy Bypass -File .\tools\sync_into_project.ps1 -Target C:\Projects\RouteSync
```
It backs up first and keeps your `lib\firebase_options.dart`, `android\`, `ios\`, `web\`. Delete the old `functions\` and `allocator\` folders in your project if they exist.

## 2. Firebase configuration file
```powershell
cd C:\Projects\RouteSync
dart pub global run flutterfire_cli:flutterfire configure --project=routesync-94a88 --platforms=web,android
```
Run it again after creating Realtime Database so the database address is included.

## 3. Firebase console (stay on Spark, never click Upgrade)
1. Authentication: Email/Password and Google on.
2. Firestore Database: create, production mode.
3. Realtime Database: create, locked mode. Copy the URL shown at the top (for the account script).

## 4. Deploy the rules and indexes
```powershell
firebase login
firebase use routesync-94a88
firebase deploy --only firestore,database
```
Only these two. If anything says "requires Blaze" you tried to deploy functions: that no longer exists. Indexes take a few minutes to build.

## 5. Create the starter accounts
1. Firebase console, Project settings, Service accounts, Generate new private key. Save it outside the project, e.g. `C:\keys\routesync-key.json`.
2. Put the two missing full emails in `tools\seed_users.js` (incomplete ones are skipped).
3. Run:
```powershell
cd C:\Projects\RouteSync\tools
npm install
$env:GOOGLE_APPLICATION_CREDENTIALS="C:\keys\routesync-key.json"
$env:DATABASE_URL="https://YOUR-PROJECT-default-rtdb.firebaseio.com"
node seed_users.js
```
Open each printed link to set a password. Admin accounts only reach the live map if `DATABASE_URL` was set.

## 6. Run the app
```powershell
cd C:\Projects\RouteSync
flutter pub get
flutter analyze
flutter test
flutter run -d chrome
```
Expect the RouteSync login with your logo. A "could not connect to Firebase" screen means step 2.

## 7. First setup (Super Admin), in order
System settings (college name and location, session, tracking hours, app web address), Fee policy, Boarding points, Routes (add a "must reach college by" time), Buses, Drivers then Assign driver, Schedules, then Import students with `docs\students_sample.csv`. Tap a student for the invitation code, QR and Email button.

## 8. Try each role
- Student: "I have an invitation code" (or scan the QR on a phone), set a password, choose a stop on the Stop tab. The fee shown is an estimate, paid at the college office.
- Route Admin: Allocation, Allocate, review, Approve. Try Suggestions and "Free up buses".
- Student: tap refresh. The bus, driver, stops and live map appear.
- Driver on a real Android phone (`flutter run -d <device>`, "Allow all the time" for location): Start sharing location. Turn data off for a minute and on again to see saved positions upload.
- Emergency: four tabs (replace bus, change route, replace driver, recent actions).

## 9. Free quotas and what to watch
| Limit (Spark) | Meaning for RouteSync |
|---|---|
| Realtime Database: **100 connections at once** | About 100 people can watch live maps at the same moment. Plenty for one college at peak, tight for thousands. |
| Realtime Database: 1 GB stored | Location history is sampled every 15 s and kept 30 days; old days are deleted automatically when an admin opens the app. |
| Firestore: 50,000 reads and 20,000 writes per day | Fine for hundreds of students. A big import or allocation of 2,000 students uses a few thousand writes; do not run them many times a day. |
| Hosting 10 GB per month, Auth email sign-in | Free. |
| Map tiles, place search, road routing (OpenStreetMap, Nominatim, public OSRM) | Free for light use. Heavy use may be throttled. |

If you outgrow these later, the Blaze plan raises them; the app keeps working unchanged.

## 10. Free extras
- **Web hosting**: `flutter build web` then `firebase deploy --only hosting`. Put the `https://routesync-94a88.web.app` address in System settings so invitation links and QR codes work.
- **Hardware GPS trackers**: GPS devices page, Register. It shows a sign-in email and password once. The tracker signs in (HTTPS POST to Firebase Auth) and PUTs its position to the Realtime Database; the dialog gives both URLs and bodies. Quick test in PowerShell:
```powershell
$k="<apiKey>"; $t=(Invoke-RestMethod -Method Post -Uri "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=$k" -ContentType 'application/json' -Body '{"email":"<email>","password":"<password>","returnSecureToken":true}').idToken
Invoke-RestMethod -Method Put -Uri "<databaseUrl>/liveLocations/<busId>.json?auth=$t" -ContentType 'application/json' -Body ('{"lat":13.08,"lng":80.27,"ts":' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + '}')
```
- **Your own routing server**: build with `--dart-define=ROUTING_URL=https://your-osrm`.

## 11. Honest limits of the free design
- **Monitoring needs an admin online.** GPS-offline, route-deviation and delay alerts, and bus status refresh only while someone has the admin app open. Keep it open on a PC during the school run.
- **Seat limits are enforced by the admin app**, not a server. Students and drivers cannot change allocations (the rules block them), but two admins allocating at the same instant could overfill a bus. Use one admin at a time for allocation.
- **Alternative-bus seats** are checked just after reserving; in a rare tie the later student is told there is no seat.
- No push notifications: students see changes under the Alerts tab when they open the app.
- Roles are stored in each person's `users` record. Disabling an account stops access immediately.

## 12. Troubleshooting
| You see | Do this |
|---|---|
| White page / could not connect | Step 2. |
| "Access pending" | The account has no `users` record. Run the account script (admins) or finish registration with the invitation. |
| "Not allowed" on a list or button | Wrong role, or rules not deployed (step 4), or the account is disabled. |
| "This screen is still being prepared" | Indexes are still building. Wait a few minutes. |
| Live map empty for admins | `DATABASE_URL` was missing in step 5. Run the script again. |
| Student sees no bus after approval | Student taps refresh. |
| Google sign-in fails on Android | Add your debug SHA-1 in Firebase project settings and rerun `flutterfire configure`. |
| Package conflict on `flutter pub get` | Send me the message; likeliest are `mobile_scanner` or `printing`. |

## 13. Before real students use it
Read `docs\RELEASE_CHECKLIST.md`, publish a reviewed privacy policy (`docs\PRIVACY_POLICY.md` is a template), and try the rules in the Firebase emulator.
