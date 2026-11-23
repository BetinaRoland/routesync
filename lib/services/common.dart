import 'dart:convert';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;
import '../core/logic.dart' as lg;

// The free plan has no Cloud Functions, so privileged work runs in the app and is limited by Firestore and
// Realtime Database security rules. Every service function takes and returns a plain map.

typedef M = Map<String, dynamic>;
final fs = FirebaseFirestore.instance;
DatabaseReference rt(String path) => FirebaseDatabase.instance.ref(path);
const adminRoles = ['superAdmin', 'routeAdmin'];

class Fail implements Exception {
  final String message;
  Fail(this.message);
  @override
  String toString() => message;
}

Never fail(String m) => throw Fail(m);

class Ctx {
  final String uid, role, name;
  final String? studentId, busId;
  const Ctx(this.uid, this.role, this.name, this.studentId, this.busId);
}

/// Loads the signed-in user's record and checks they are active and have one of [roles].
Future<Ctx> need([List<String>? roles]) async {
  final u = FirebaseAuth.instance.currentUser;
  if (u == null) fail('Sign in first.');
  final x = (await fs.doc('users/${u.uid}').get()).data();
  if (x == null || x['status'] != 'active') fail('Your account is not active.');
  if (roles != null && !roles.contains(x['role'])) fail('You are not allowed to do this.');
  return Ctx(u.uid, '${x['role']}', '${x['name'] ?? ''}', x['studentId'] as String?, x['busId'] as String?);
}

String sha256Hex(String s) => sha256.convert(utf8.encode(s)).toString();
String randomToken([int bytes = 24]) {
  final r = Random.secure();
  return base64Url.encode(List<int>.generate(bytes, (_) => r.nextInt(256))).replaceAll('=', '');
}

String safeId(String s) => s.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
List<List<T>> chunks<T>(List<T> a, int n) => [for (var i = 0; i < a.length; i += n) a.sublist(i, min(i + n, a.length))];
String two(int n) => n.toString().padLeft(2, '0');
String dateKey([DateTime? d]) {
  final x = d ?? DateTime.now();
  return '${x.year}-${two(x.month)}-${two(x.day)}';
}

String hhmm([DateTime? d]) {
  final x = d ?? DateTime.now();
  return '${two(x.hour)}:${two(x.minute)}';
}

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
String weekdayName([DateTime? d]) => _days[(d ?? DateTime.now()).weekday - 1];

/// Rules allow only about 20 access checks per batch, so bulk writes go in small batches.
Future<void> writeAll(List<void Function(WriteBatch b)> ops, {int per = 16}) async {
  for (final part in chunks(ops, per)) {
    final b = fs.batch();
    for (final o in part) { o(b); }
    await b.commit();
  }
}

Object? _safe(Object? v) {
  if (v is Timestamp) return v.toDate().toIso8601String();
  if (v is FieldValue) return null;
  if (v is Map) return {for (final e in v.entries) '${e.key}': _safe(e.value)};
  if (v is List) return v.map(_safe).toList();
  return v;
}

Future<void> audit(Ctx a, String action, String record, [Object? prev, Object? next, String? reason]) async {
  try {
    await fs.collection('auditLogs').add({
      'actorId': a.uid, 'actorRole': a.role, 'action': action, 'affectedRecord': record,
      'previousValues': _safe(prev), 'newValues': _safe(next), 'reason': reason,
      'timestamp': FieldValue.serverTimestamp(), 'requestId': randomToken(9),
    });
  } catch (_) {/* the action already happened; do not fail it over the log */}
}

Future<void> notify(String? userId, String title, String body) async {
  if (userId == null) return;
  try {
    await fs.collection('notifications').add({'userId': userId, 'title': title, 'body': body, 'read': false, 'createdAt': FieldValue.serverTimestamp()});
  } catch (_) {}
}

Future<M> cfg() async {
  final a = (await fs.doc('config/app').get()).data() ?? {};
  final o = (await fs.doc('config/operations').get()).data() ?? {};
  final c = <String, dynamic>{
    'academicYear': '2026-27', 'trackingStart': '06:00', 'trackingEnd': '20:00', 'gpsStaleSeconds': 120, 'deviationMeters': 300,
    'deviationUpdates': 3, 'historyIntervalSec': 15, 'historyRetentionDays': 30, 'delayGraceMinutes': 10, 'delayWindowMinutes': 90,
    'approachMeters': 1200, 'webBaseUrl': '', ...a,
  };
  if (o['trackingStart'] != null && '${o['trackingStart']}'.compareTo('${c['trackingStart']}') > 0) c['trackingStart'] = o['trackingStart'];
  if (o['trackingEnd'] != null && '${o['trackingEnd']}'.compareTo('${c['trackingEnd']}') < 0) c['trackingEnd'] = o['trackingEnd'];
  return c;
}

Future<M> college() async {
  final c = (await fs.doc('config/college').get()).data();
  if (c == null || c['lat'] == null) fail('Set the college location in System settings first.');
  return c;
}

/// Road distance and route shape from the public OSRM server (free; for light use).
Future<({double km, List<M> geometry})> osrm(List<List<double>> lngLat) async {
  const base = String.fromEnvironment('ROUTING_URL', defaultValue: 'https://router.project-osrm.org');
  final url = Uri.parse('$base/route/v1/driving/${lngLat.map((c) => '${c[0]},${c[1]}').join(';')}?overview=full&geometries=geojson');
  Map<String, dynamic> j;
  try {
    j = jsonDecode((await http.get(url).timeout(const Duration(seconds: 25))).body) as Map<String, dynamic>;
  } catch (_) {
    fail('The routing service is unreachable. Try again in a moment.');
  }
  final routes = j['routes'] as List?;
  if (j['code'] != 'Ok' || routes == null || routes.isEmpty) fail('No road route found for these points.');
  final r = routes.first as Map;
  final coords = ((r['geometry'] as Map)['coordinates'] as List).map((c) => {'lat': (c[1] as num).toDouble(), 'lng': (c[0] as num).toDouble()}).toList();
  return (km: (r['distance'] as num) / 1000, geometry: lg.downsample<M>(coords, 400));
}

/// Fee for display. Nothing is charged by the app; payment happens at the college office.
Future<M?> feeFor(String academicYear, double km) async {
  final snap = await fs.collection('feePolicies').where('academicYear', isEqualTo: academicYear).get();
  final now = DateTime.now();
  final ok = snap.docs.map((d) => {...d.data(), 'id': d.id}).where((p) {
    final f = (p['effectiveFrom'] as Timestamp?)?.toDate(), t = (p['effectiveTo'] as Timestamp?)?.toDate();
    return (f == null || !f.isAfter(now)) && (t == null || !t.isBefore(now));
  }).toList()
    ..sort((a, b) => ((b['version'] as num?) ?? 0).compareTo((a['version'] as num?) ?? 0));
  if (ok.isEmpty) return null;
  final amount = lg.computeFee(ok.first, km);
  if (amount == null) return null;
  return {'amount': amount, 'distanceKm': (km * 100).round() / 100, 'policyId': ok.first['id']};
}

/// Realtime Database copies of access lists. Database rules cannot read Firestore, so these small nodes decide who may
/// see or write live locations. They are updated together with the Firestore records they mirror.
class Mirror {
  static Future<void> apply(Map<String, Object?> updates) => FirebaseDatabase.instance.ref().update(updates);
  static Map<String, Object?> admin(String uid, String? level) => {'admins/$uid': level};
  static Map<String, Object?> rider(String busId, String uid, bool on) => {'riders/$busId/$uid': on ? true : null};
  static Map<String, Object?> riderStop(String uid, String? stop) => {'riderStop/$uid': stop};
  static Map<String, Object?> writer(String busId, String uid, bool on) => {'busWriters/$busId/$uid': on ? true : null};
  static Map<String, Object?> busStops(String busId, List<String> stops) => {'busStops/$busId': stops.isEmpty ? null : {for (final s in stops) s: true}};
}

Future<void> recountBus(String busId) async {
  final c = await fs.collection('allocations').where('busId', isEqualTo: busId).where('status', isEqualTo: 'active').count().get();
  await fs.doc('buses/$busId').update({'allocated': c.count ?? 0});
}

Future<int> activeCount(String busId) async {
  final c = await fs.collection('allocations').where('busId', isEqualTo: busId).where('status', isEqualTo: 'active').count().get();
  return c.count ?? 0;
}

/// Creates a sign-in account without signing the admin out, using a second app instance.
Future<String> createAuthAccount(String email, String password) async {
  FirebaseApp app;
  try {
    app = Firebase.app('creator');
  } catch (_) {
    app = await Firebase.initializeApp(name: 'creator', options: Firebase.app().options);
  }
  final auth = FirebaseAuth.instanceFor(app: app);
  try {
    return (await auth.createUserWithEmailAndPassword(email: email, password: password)).user!.uid;
  } on FirebaseAuthException catch (e) {
    if (e.code == 'email-already-in-use') fail('That email already has an account.');
    if (e.code == 'weak-password') fail('Choose a stronger password (8 or more characters).');
    fail('Could not create the account. ${e.message ?? ''}');
  } finally {
    try { await auth.signOut(); } catch (_) {}
  }
}

/// Active allocations grouped by bus plus student names, used by the planners.
Future<({List<lg.FleetBus> all, Map<String, List<lg.Rider>> riders, Map<String, List<M>> riderDocs, Map<String, M> routes})> loadFleet() async {
  final r = await Future.wait([
    fs.collection('buses').get(), fs.collection('routes').get(), fs.collection('drivers').get(),
    fs.collection('allocations').where('status', isEqualTo: 'active').get(), fs.collection('students').get(),
  ]);
  final routes = {for (final d in r[1].docs) d.id: d.data()};
  final drivers = {for (final d in r[2].docs) d.id: d.data()};
  final names = {for (final d in r[4].docs) d.id: '${d.data()['name']}'};
  final riders = <String, List<lg.Rider>>{}, docs = <String, List<M>>{};
  for (final d in r[3].docs) {
    final a = d.data(), bus = '${a['busId']}';
    (riders[bus] ??= []).add(lg.Rider('${a['studentId']}', '${a['boardingPointId']}'));
    (docs[bus] ??= []).add({...a, 'name': names['${a['studentId']}'] ?? '${a['studentId']}'});
  }
  final all = r[0].docs.map((d) {
    final b = d.data(), dr = drivers['${b['driverId']}'], route = routes['${b['routeId']}'];
    final region = b['permittedRegionId'] as String?;
    return lg.FleetBus(
      id: '${b['busId']}', number: '${b['busNumber']}', capacity: (b['capacity'] as num).toInt(), allocated: (riders['${b['busId']}'] ?? []).length,
      stops: List<String>.from((route?['stopIds'] as List?) ?? []), routeId: b['routeId'] as String?, driverId: b['driverId'] as String?, permittedRegionId: region,
      availability: b['availability'] == true, maintenanceStatus: '${b['maintenanceStatus']}',
      driverAuthorized: dr != null && dr['status'] == 'active' && (region == null || ((dr['permittedRegionIds'] as List?) ?? []).contains(region)),
    );
  }).toList();
  return (all: all, riders: riders, riderDocs: docs, routes: routes);
}

// ---------------- Alerts (open alerts live in `alerts`; resolved ones move to `alertHistory`) ----------------
Future<bool> raiseAlert(String busId, String type, String severity, String description) async {
  final ref = fs.doc('alerts/open_${busId}_$type');
  if ((await ref.get()).exists) return false; // no repeats for an unresolved incident
  await ref.set({'alertId': ref.id, 'busId': busId, 'alertType': type, 'severity': severity, 'description': description, 'status': 'open', 'createdAt': FieldValue.serverTimestamp(), 'acknowledgedAt': null, 'acknowledgedBy': null});
  return true;
}

Future<void> resolveAlert(String busId, String type) async {
  final ref = fs.doc('alerts/open_${busId}_$type'), x = (await ref.get()).data();
  if (x == null) return;
  await writeAll([(b) => b.set(fs.collection('alertHistory').doc(), {...x, 'status': 'resolved', 'resolvedAt': FieldValue.serverTimestamp()}), (b) => b.delete(ref)]);
}

Future<bool> isWorkingDay([DateTime? now]) async {
  final snap = await fs.collection('collegeSchedules').get();
  if (snap.docs.isEmpty) return true;
  final n = now ?? DateTime.now(), day = weekdayName(n), key = dateKey(n);
  var working = false;
  for (final d in snap.docs) {
    final s = d.data();
    if (((s['specialWorkingDates'] as List?) ?? []).contains(key)) return true;
    if (((s['holidayDates'] as List?) ?? []).contains(key)) continue;
    if (((s['workingDays'] as List?) ?? []).contains(day)) working = true;
  }
  return working;
}
