import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/logic.dart' as lg;
import 'common.dart';

/// Watches the fleet while an admin has the app open (the free plan has no background server).
/// Raises and clears alerts, keeps bus status fresh, flags expired emergency changes and trims old location history.
class MonitorService {
  static Timer? _timer;
  static StreamSubscription<QuerySnapshot<M>>? _sub;
  static final Set<String> _open = {};
  static final _last = <String, ({int ts, double lat, double lng})>{};
  static final _dev = <String, int>{};
  static final _status = <String, String>{};
  static final _sched = <String, String>{};
  static final _routes = <String, ({DateTime at, List<List<double>> geo, String? arrivalBy})>{};
  static String _preflightDay = '', _purgeDay = '';
  static final _epoch = DateTime.fromMillisecondsSinceEpoch(0);
  static DateTime _emAt = _epoch, _busesAt = _epoch, _collegeAt = _epoch, _workAt = _epoch;
  static List<M> _buses = [];
  static M? _college;
  static bool _working = true, _busy = false;

  static void start() {
    stop();
    _sub = fs.collection('alerts').snapshots().listen((s) {
      _open..clear()..addAll(s.docs.map((d) => d.id));
    }, onError: (_) {});
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
    _tick();
  }

  static void stop() {
    _timer?.cancel();
    _sub?.cancel();
    _timer = null;
    _sub = null;
  }

  static Future<void> _raise(String bus, String type, String sev, String desc) async {
    if (_open.contains('open_${bus}_$type')) return;
    await raiseAlert(bus, type, sev, desc);
    _open.add('open_${bus}_$type');
  }

  static Future<void> _clear(String bus, String type) async {
    if (!_open.contains('open_${bus}_$type')) return;
    await resolveAlert(bus, type);
    _open.remove('open_${bus}_$type');
  }

  static Future<void> _setStatus(String id, String s) async {
    if (_status[id] == s) return;
    _status[id] = s;
    await fs.doc('buses/$id').update({'trackingStatus': s});
  }

  static Future<void> _setSched(String id, String s) async {
    if (_sched[id] == s) return;
    _sched[id] = s;
    await fs.doc('buses/$id').update({'scheduleStatus': s});
  }

  static Future<({List<List<double>> geo, String? arrivalBy})?> _route(String? routeId) async {
    if (routeId == null) return null;
    final c = _routes[routeId];
    if (c != null && DateTime.now().difference(c.at).inMinutes < 10) return (geo: c.geo, arrivalBy: c.arrivalBy);
    final r = (await fs.doc('routes/$routeId').get()).data();
    if (r == null) return null;
    final geo = ((r['routeGeometry'] as List?) ?? []).map((p) => [(p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()]).toList();
    _routes[routeId] = (at: DateTime.now(), geo: geo, arrivalBy: r['arrivalBy'] as String?);
    return (geo: geo, arrivalBy: r['arrivalBy'] as String?);
  }

  static Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final c = await cfg(), now = DateTime.now(), t = hhmm(now);
      if (now.difference(_emAt).inMinutes >= 5) { _emAt = now; await _expiry(); }
      if (_purgeDay != dateKey(now)) { _purgeDay = dateKey(now); await _purge(c, now); }
      if (t.compareTo('${c['trackingStart']}') < 0 || t.compareTo('${c['trackingEnd']}') > 0) return;
      if (now.difference(_workAt).inMinutes >= 10) { _working = await isWorkingDay(now); _workAt = now; }
      if (!_working) return;
      if (now.difference(_busesAt).inMinutes >= 2) {
        final s = await fs.collection('buses').where('availability', isEqualTo: true).get();
        _buses = s.docs.map((d) => d.data()).where((b) => b['maintenanceStatus'] == 'ok' && ((b['allocated'] as num?) ?? 0) > 0).toList();
        _busesAt = now;
      }
      if (now.difference(_collegeAt).inMinutes >= 10) {
        try { _college = await college(); } catch (_) { _college = null; }
        _collegeAt = now;
      }
      final raw = (await rt('liveLocations').get()).value, live = raw is Map ? raw : <dynamic, dynamic>{};
      final first = _preflightDay != dateKey(now);
      _preflightDay = dateKey(now);
      for (final b in _buses) { await _check(b, live, c, now, t, first); }
    } catch (_) {
      // try again on the next tick
    } finally {
      _busy = false;
    }
  }

  static Future<void> _check(M b, Map live, M c, DateTime now, String t, bool preflight) async {
    final id = '${b['busId']}', busNo = '${b['busNumber']}';
    if (preflight) {
      final issues = [if (b['driverId'] == null) 'no driver assigned', if (b['routeId'] == null) 'no route assigned'];
      if (issues.isNotEmpty) await _raise(id, 'preflight', 'high', 'Bus $busNo is not ready: ${issues.join(', ')}.');
    }
    if (b['driverId'] == null && b['gpsDeviceId'] == null) return;
    final loc = live[id] as Map?, ts = (loc?['ts'] as num?)?.toInt();
    final age = ts == null ? null : (now.millisecondsSinceEpoch - ts) / 1000;
    if (loc == null || age == null || age > (c['gpsStaleSeconds'] as num)) {
      await _setStatus(id, 'offline');
      await _raise(id, 'gps_failure', 'high', loc == null || age == null ? 'This bus has not started sending its location.' : 'No location update for ${(age / 60).round()} min. Last known position is shown.');
      return;
    }
    final lat = (loc['lat'] as num).toDouble(), lng = (loc['lng'] as num).toDouble(), prev = _last[id];
    if (prev != null && ts! > prev.ts) { // reject impossible jumps (over about 200 km/h)
      final dist = lg.haversineM(prev.lat, prev.lng, lat, lng), dt = (ts - prev.ts) / 1000;
      if (dist > 200 && dist / dt > 55) {
        await _setStatus(id, 'tracking_problem');
        await _raise(id, 'tracking_problem', 'medium', 'Location jumped implausibly. The update was ignored.');
        return;
      }
    }
    _last[id] = (ts: ts!, lat: lat, lng: lng);
    await _clear(id, 'gps_failure');
    await _clear(id, 'tracking_problem');
    await _setStatus(id, 'active');

    final rd = await _route(b['routeId'] as String?);
    if (rd != null && rd.geo.isNotEmpty) { // route deviation
      final off = lg.distToPolylineM(lat, lng, rd.geo) > (c['deviationMeters'] as num), was = _dev[id] ?? 0;
      _dev[id] = off ? was + 1 : 0;
      if (_dev[id]! >= (c['deviationUpdates'] as num)) await _raise(id, 'route_deviation', 'medium', 'Bus is more than ${c['deviationMeters']} m from its approved route.');
      if (!off && was > 0) await _clear(id, 'route_deviation');
    }
    if (rd?.arrivalBy != null && _college != null) { // behind schedule
      final due = lg.minutesOf(rd!.arrivalBy!) + (c['delayGraceMinutes'] as num).toInt(), nowM = lg.minutesOf(t);
      final dc = lg.haversineM(lat, lng, (_college!['lat'] as num).toDouble(), (_college!['lng'] as num).toDouble());
      final late = nowM > due && nowM < due + (c['delayWindowMinutes'] as num).toInt() && dc > 300;
      if (late) {
        await _raise(id, 'delay', 'medium', 'Bus is behind schedule. It was due at the college by ${rd.arrivalBy}.');
        await _setSched(id, 'delayed');
      } else if (_sched[id] == 'delayed') {
        await _setSched(id, 'on_time');
        await _clear(id, 'delay');
      }
    }
  }

  static Future<void> _expiry() async {
    final q = await fs.collection('emergencyActions').where('reviewStatus', isEqualTo: 'active').where('expiresAt', isLessThan: Timestamp.now()).get();
    for (final d in q.docs) {
      await d.reference.update({'reviewStatus': 'review_required'});
      await _raise('${d.data()['affectedBusId']}', 'emergency_review', 'high', 'A temporary emergency change has expired and needs review.');
    }
  }

  static Future<void> _purge(M c, DateTime now) async {
    try {
      final keep = (c['historyRetentionDays'] as num).toInt();
      final buses = await fs.collection('buses').get();
      for (final b in buses.docs) {
        for (var k = 1; k <= 10; k++) { await rt('history/${b.id}/${dateKey(now.subtract(Duration(days: keep + k)))}').remove(); }
      }
    } catch (_) {}
  }
}
