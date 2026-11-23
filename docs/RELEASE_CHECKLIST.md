# Release checklist

## Safety and security
- [ ] Rules tested in the Firebase emulator (students cannot read other students, drivers cannot read other buses, nobody writes protected collections).
- [ ] Service account key is not in the project folder or Git.
- [ ] Super Admin accounts use strong passwords and are few. Turn on Google 2-step verification for those Google accounts.
- [ ] Budget alert set in Google Cloud billing.
- [ ] Own routing service configured (`--dart-define=ROUTING_URL=...`) if usage is heavy; public OSRM is for light use.
- [ ] Stayed on the Spark plan; checked quotas in the Firebase console usage tab.

## Function tests with real data
- [ ] Invite, register, choose stop, pay, allocate, track, one full day with a real bus and phone.
- [ ] GPS offline test: airplane mode for several minutes, then back; alert raised and cleared, history filled.
- [ ] Emergency: replace bus, change route, replace driver, then revert each.
- [ ] Location permission "Allow all the time" works on the driver phones, with battery saver on.

## Store listing (Android / iOS)
- [ ] App name RouteSync, icon from `assets/logo.png` (`dart run flutter_launcher_icons`).
- [ ] Privacy policy URL (publish `docs/PRIVACY_POLICY.md` after review).
- [ ] Data safety form: location (bus only, driver devices), email, name, no payment data.
- [ ] Background location justification for the driver feature: shows live bus position to students during duty hours.
- [ ] iOS: APNs key uploaded to Firebase for push; Info.plist location and camera texts.
- [ ] Release signing keys created and backed up. Add release SHA-1 to Firebase.

## Operations
- [ ] CI is green (`.github/workflows/ci.yml`). Commit `lib/firebase_options.dart` (Firebase client keys are not secrets).
- [ ] An admin keeps the admin app open during the school run (alerts and status refresh only then).
- [ ] Someone owns: adding students each year, rotating device keys, reviewing audit logs, answering student reports.
