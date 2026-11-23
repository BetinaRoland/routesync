// Creates (or finds) the starter accounts and gives them their roles. Safe to run more than once.
// Runs on your computer with a service account key. This works on the free Firebase plan.
//
//   cd tools
//   npm install
//   $env:GOOGLE_APPLICATION_CREDENTIALS = "C:\keys\routesync-key.json"
//   $env:DATABASE_URL = "https://<your-project>-default-rtdb.firebaseio.com"   (shown at the top of Realtime Database)
//   node seed_users.js
//
// Fix any email marked CHECK first: it must be a complete address. Incomplete ones are skipped.
const admin = require('firebase-admin');
admin.initializeApp({ databaseURL: process.env.DATABASE_URL });

const USERS = [
  { email: 'betiebird@gmail.com', role: 'superAdmin', name: 'Super Admin' },
  { email: '25104003@nec.edu.in', role: 'routeAdmin', name: 'Route Admin' },
  { email: 'betinaroland07@gmail.com', role: 'student', name: 'Betina Roland' },
  { email: 'bellokyo50@gmail.com', role: 'driver', name: 'Bello Kyo' },
];

const valid = (e) => /^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i.test(e) && !e.includes('CHECK');
const db = admin.firestore();
const now = admin.firestore.FieldValue.serverTimestamp();

async function main() {
  if (!process.env.DATABASE_URL) console.log('WARNING: DATABASE_URL is not set. Admin accounts will not get live-map access until it is.\n');
  for (const u of USERS) {
    if (!valid(u.email)) { console.log(`SKIPPED  ${u.role.padEnd(10)} ${u.email}  (incomplete email, edit tools/seed_users.js)`); continue; }
    const email = u.email.toLowerCase();
    let user;
    try { user = await admin.auth().getUserByEmail(email); }
    catch (e) {
      if (e.code !== 'auth/user-not-found') throw e;
      user = await admin.auth().createUser({ email, displayName: u.name, password: require('crypto').randomBytes(18).toString('base64url') });
    }
    const rec = { role: u.role, name: u.name, email, status: 'active', createdAt: now };
    if (u.role === 'driver') Object.assign(rec, { busId: null });
    if (u.role === 'student') Object.assign(rec, { studentId: email.split('@')[0].replace(/[^A-Za-z0-9_-]/g, '_') });
    await db.doc(`users/${user.uid}`).set(rec, { merge: true });

    if (u.role === 'superAdmin' || u.role === 'routeAdmin') {
      if (process.env.DATABASE_URL) await admin.database().ref(`admins/${user.uid}`).set(u.role === 'superAdmin' ? 'super' : 'route');
    }
    if (u.role === 'driver') {
      await db.doc(`drivers/${user.uid}`).set({ driverId: user.uid, authUid: user.uid, name: u.name, email, contact: '', permittedRegionIds: [], assignedBusId: null, status: 'active', createdAt: now }, { merge: true });
    }
    if (u.role === 'student') {
      const id = rec.studentId;
      await db.doc(`students/${id}`).set({ studentId: id, registerNumber: id, name: u.name, departmentId: 'TBD', academicYear: 1, email, mobile: '', authUid: user.uid, approvedBoardingPointId: null, registrationStatus: 'registered', allocationId: null, createdAt: now }, { merge: true });
    }
    const link = await admin.auth().generatePasswordResetLink(email);
    console.log(`READY    ${u.role.padEnd(10)} ${email}\n         set password: ${link}\n`);
  }
  console.log('Done. Each person opens their link to set a password, then signs in.');
}
main().catch((e) => { console.error(e.message); process.exit(1); });
