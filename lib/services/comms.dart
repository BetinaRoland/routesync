import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'common.dart';

Future<M> sendAnnouncement(M d) async {
  final actor = await need(adminRoles);
  final title = '${d['title'] ?? ''}'.trim(),
      body = '${d['body'] ?? ''}'.trim(),
      audience = '${d['audience'] ?? 'all'}';
  if (title.isEmpty || body.isEmpty || title.length > 80 || body.length > 500) {
    fail('Add a title (up to 80 characters) and a message (up to 500).');
  }
  if (!['all', 'students', 'drivers', 'running_buses'].contains(audience)) {
    fail('Unknown audience.');
  }
  final ref = fs.collection('announcements').doc();
  await ref.set({
    'announcementId': ref.id,
    'title': title,
    'body': body,
    'audience': audience,
    'createdBy': actor.uid,
    'createdAt': FieldValue.serverTimestamp(),
  });
  await audit(actor, 'sendAnnouncement', 'announcements/${ref.id}', null, {
    'audience': audience,
  });
  return {'ok': true};
}

const _categories = [
  'Bus condition',
  'Driver',
  'Timing',
  'Safety',
  'Fees',
  'Other',
];

Future<M> submitFeedback(M d) async {
  final c = await need(['student']);
  final message = '${d['message'] ?? ''}'.trim(), category = '${d['category']}';
  if (!_categories.contains(category)) fail('Choose a category.');
  if (message.length < 5 || message.length > 1000) {
    fail('Write between 5 and 1000 characters.');
  }
  final s = (await fs.doc('students/${c.studentId}').get()).data();
  if (s == null) fail('Student record not found.');
  final open = await fs
      .collection('feedback')
      .where('authUid', isEqualTo: c.uid)
      .where('status', isEqualTo: 'open')
      .count()
      .get();
  if ((open.count ?? 0) >= 5) {
    fail('You have several open reports. Please wait for a reply.');
  }
  final ref = fs.collection('feedback').doc();
  await ref.set({
    'feedbackId': ref.id,
    'authUid': c.uid,
    'studentId': c.studentId,
    'studentName': s['name'],
    'category': category,
    'message': message,
    'status': 'open',
    'createdAt': FieldValue.serverTimestamp(),
    'reply': null,
  });
  return {'ok': true};
}

Future<M> replyFeedback(M d) async {
  final actor = await need(adminRoles);
  final reply = '${d['reply'] ?? ''}'.trim();
  if (reply.length < 2 || reply.length > 1000) {
    fail('Write a reply of up to 1000 characters.');
  }
  final ref = fs.doc('feedback/${d['feedbackId']}'),
      f = (await ref.get()).data();
  if (f == null || f['status'] != 'open') {
    fail('This report is already closed.');
  }
  await ref.update({
    'status': 'resolved',
    'reply': reply,
    'repliedBy': actor.uid,
    'resolvedAt': FieldValue.serverTimestamp(),
  });
  await notify('${f['authUid']}', 'Reply to your report', reply);
  await audit(actor, 'replyFeedback', 'feedback/${ref.id}', null, {
    'reply': reply,
  });
  return {'ok': true};
}

Future<List<M>> _stops(M? route) async {
  final out = <M>[];
  for (final id in ((route?['stopIds'] as List?) ?? [])) {
    final p = (await fs.doc('boardingPoints/$id').get()).data();
    if (p != null) {
      out.add({
        'id': id,
        'name': p['name'],
        'lat': p['latitude'],
        'lng': p['longitude'],
      });
    }
  }
  return out;
}

/// What a student or driver sees about their bus, assembled from records their rules let them read.
Future<M> getMyTransport(M d) async {
  final c = await need(['student', 'driver']);
  final conf = await cfg();
  if (c.role == 'driver') {
    if (c.busId == null) return {'assigned': false};
    final bus = (await fs.doc('buses/${c.busId}').get()).data();
    if (bus == null) return {'assigned': false};
    final route = bus['routeId'] == null
        ? null
        : (await fs.doc('routes/${bus['routeId']}').get()).data();
    final al = await fs
        .collection('allocations')
        .where('busId', isEqualTo: c.busId)
        .where('status', isEqualTo: 'active')
        .get();
    final counts = <String, int>{};
    for (final a in al.docs) {
      final k = '${a.data()['boardingPointId']}';
      counts[k] = (counts[k] ?? 0) + 1;
    }
    final alt = await fs
        .collection('alternativeBoardings')
        .where('alternativeBusId', isEqualTo: c.busId)
        .where('date', isEqualTo: dateKey())
        .where('status', isEqualTo: 'reserved')
        .count()
        .get();
    final stops = (await _stops(
      route,
    )).map((s) => {...s, 'passengers': counts[s['id']] ?? 0}).toList();
    return {
      'assigned': true,
      'busId': c.busId,
      'busNumber': bus['busNumber'],
      'capacity': bus['capacity'],
      'passengers': al.docs.length,
      'alternatePassengers': alt.count ?? 0,
      'routeName': route?['routeName'],
      'arrivalBy': route?['arrivalBy'],
      'stops': stops,
      'routeGeometry': route?['routeGeometry'] ?? [],
      'trackingStatus': bus['trackingStatus'],
      'trackingStart': conf['trackingStart'],
      'trackingEnd': conf['trackingEnd'],
      'gpsStaleSeconds': conf['gpsStaleSeconds'],
      'workingToday': await isWorkingDay(),
    };
  }
  final s = (await fs.doc('students/${c.studentId}').get()).data();
  if (s == null) fail('Student record not found.');
  final selectedBp = s['approvedBoardingPointId'] == null
      ? null
      : (await fs.doc('boardingPoints/${s['approvedBoardingPointId']}').get())
            .data();
  final bp =
      selectedBp != null &&
          selectedBp['approvalStatus'] == 'approved' &&
          selectedBp['status'] != 'inactive'
      ? selectedBp
      : null;
  final fee = bp == null || bp['roadDistanceKm'] is! num
      ? null
      : await feeFor(
          '${conf['academicYear']}',
          (bp['roadDistanceKm'] as num).toDouble(),
        );
  final out = <String, dynamic>{
    'fee': fee,
    'boardingPoint': bp == null
        ? null
        : {
            'id': s['approvedBoardingPointId'],
            'name': bp['name'],
            'lat': bp['latitude'],
            'lng': bp['longitude'],
          },
    'allocated': false,
    'trackingStart': conf['trackingStart'],
    'trackingEnd': conf['trackingEnd'],
    'gpsStaleSeconds': conf['gpsStaleSeconds'],
  };
  if (s['allocationId'] != null) {
    final a = (await fs.doc('allocations/${s['allocationId']}').get()).data();
    if (a != null && a['status'] == 'active') {
      final bus = (await fs.doc('buses/${a['busId']}').get()).data()!;
      final route = (await fs.doc('routes/${a['routeId']}').get()).data();
      out.addAll({
        'allocated': true,
        'busId': a['busId'],
        'busNumber': bus['busNumber'],
        'routeName': route?['routeName'],
        'arrivalBy': route?['arrivalBy'],
        'stops': await _stops(route),
        'routeGeometry': route?['routeGeometry'] ?? [],
        'trackingStatus': bus['trackingStatus'],
        'driver': bus['driverName'] == null
            ? null
            : {'name': bus['driverName'], 'contact': bus['driverContact']},
      });
    }
  }
  final alternative =
      (await fs.doc('alternativeBoardings/${c.uid}_${dateKey()}').get()).data();
  final alternativeBusId = alternative?['alternativeBusId'];
  if (out['allocated'] == true &&
      alternative?['status'] == 'reserved' &&
      alternative?['date'] == dateKey() &&
      alternative?['originalBusId'] == out['busId'] &&
      alternativeBusId is String &&
      alternativeBusId.isNotEmpty) {
    final bus = (await fs.doc('buses/$alternativeBusId').get()).data();
    if (bus != null &&
        bus['availability'] == true &&
        bus['maintenanceStatus'] == 'ok') {
      final route = bus['routeId'] == null
          ? null
          : (await fs.doc('routes/${bus['routeId']}').get()).data();
      out['alternativeTransport'] = {
        'busId': alternativeBusId,
        'busNumber': bus['busNumber'],
        'trackingStatus': bus['trackingStatus'],
        'routeName': route?['routeName'],
        'arrivalBy': route?['arrivalBy'],
        'stops': await _stops(route),
        'routeGeometry': route?['routeGeometry'] ?? [],
        'driver': bus['driverName'] == null
            ? null
            : {'name': bus['driverName'], 'contact': bus['driverContact']},
        'boardingPoint': out['boardingPoint'],
        'trackingStart': conf['trackingStart'],
        'trackingEnd': conf['trackingEnd'],
        'gpsStaleSeconds': conf['gpsStaleSeconds'],
      };
    }
  }
  return out;
}

final _etaCache = <String, ({int at, int ts, M out})>{};

/// Road time from the bus to the student's stop using the free OSRM server (no live traffic).
Future<M> getEta(M d) async {
  final c = await need(['student']);
  final s = (await fs.doc('students/${c.studentId}').get()).data();
  if (s == null) fail('Student record not found.');
  String? busId;
  if (s['allocationId'] != null) {
    final a = (await fs.doc('allocations/${s['allocationId']}').get()).data();
    if (a != null && a['status'] == 'active') busId = '${a['busId']}';
  }
  final wanted = d['busId'] == null ? null : '${d['busId']}';
  if (wanted != null && wanted != busId) {
    final until = (await rt('alt/$wanted/${c.uid}').get()).value;
    if (until is num && until > DateTime.now().millisecondsSinceEpoch) {
      busId = wanted;
    } else {
      fail('That is not your bus.');
    }
  }
  if (busId == null || s['approvedBoardingPointId'] == null) {
    return {'available': false, 'reason': 'No bus or stop assigned yet.'};
  }
  final live = (await rt('liveLocations/$busId').get()).value;
  if (live is! Map ||
      DateTime.now().millisecondsSinceEpoch - (live['ts'] as num) > 120000) {
    return {'available': false, 'reason': 'The bus has not reported recently.'};
  }
  final key = '$busId:${s['approvedBoardingPointId']}',
      hit = _etaCache[key],
      nowMs = DateTime.now().millisecondsSinceEpoch;
  if (hit != null &&
      nowMs - hit.at < 20000 &&
      hit.ts == (live['ts'] as num).toInt()) {
    return hit.out;
  }
  final stop =
      (await fs.doc('boardingPoints/${s['approvedBoardingPointId']}').get())
          .data()!;
  const base = String.fromEnvironment(
    'ROUTING_URL',
    defaultValue: 'https://router.project-osrm.org',
  );
  Map<String, dynamic> j;
  try {
    j =
        jsonDecode(
              (await http
                      .get(
                        Uri.parse(
                          '$base/route/v1/driving/${live['lng']},${live['lat']};${stop['longitude']},${stop['latitude']}?overview=false',
                        ),
                      )
                      .timeout(const Duration(seconds: 15)))
                  .body,
            )
            as Map<String, dynamic>;
  } catch (_) {
    return {
      'available': false,
      'reason': 'Road routing is unreachable right now.',
    };
  }
  final routes = j['routes'] as List?;
  if (j['code'] != 'Ok' || routes == null || routes.isEmpty) {
    return {'available': false, 'reason': 'No road route to your stop.'};
  }
  final r = routes.first as Map;
  final out = {
    'available': true,
    'minutes': ((r['duration'] as num) / 60).round(),
    'km': ((r['distance'] as num) / 100).round() / 10,
    'traffic': false,
  };
  _etaCache[key] = (at: nowMs, ts: (live['ts'] as num).toInt(), out: out);
  return out;
}
