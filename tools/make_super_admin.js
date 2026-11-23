// One-time bootstrap: gives an existing Firebase user the superAdmin role.
// Usage (from the functions folder after `npm install`):
//   export GOOGLE_APPLICATION_CREDENTIALS=/path/to/serviceAccount.json
//   node ../tools/make_super_admin.js admin@college.edu
const admin = require('../functions/node_modules/firebase-admin');
admin.initializeApp();
const email = process.argv[2];
if (!email) { console.error('Give the user email.'); process.exit(1); }
admin.auth().getUserByEmail(email)
  .then((u) => admin.auth().setCustomUserClaims(u.uid, { role: 'superAdmin' }).then(() => console.log(`${email} is now superAdmin. Sign out and in again.`)))
  .catch((e) => { console.error(e.message); process.exit(1); });
