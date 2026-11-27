import 'package:cloud_firestore/cloud_firestore.dart';
import 'common.dart';

void _needReason(Object? r) {
  if (r == null || '$r'.trim().length < 5) fail('A reason is required.');
}

List<String> _stopsOf(M? route) =>
    List<String>.from((route?['stopIds'] as List?) ?? []);

Future<M> emergencyReplaceBus(M d) async {
  final actor = await need(adminRoles);
  final busId = '${d['busId'] ?? ''}',
      replId = '${d['replacementBusId'] ?? ''}',
      reason = '${d['reason'] ?? ''}'.trim();
  final hours = (d['hours'] as num?)?.toInt() ?? 8;
  _needReason(reason);
  if (busId.isEmpty || replId.isEmpty || busId == replId) {
    fail('Choose two different buses.');
  }
  final bus = (await fs.doc('buses/$busId').get()).data(),
      repl = (await fs.doc('buses/$replId').get()).data();
  if (bus == null || repl == null) fail('Bus not found.');
  if (repl['availability'] != true || repl['maintenanceStatus'] != 'ok') {
    fail('The replacement bus is not available.');
  }
  final al = await fs
      .collection('allocations')
      .where('busId', isEqualTo: busId)
      .where('status', isEqualTo: 'active')
      .get();
  final replCount = await activeCount(replId),
      cap = (repl['capacity'] as num).toInt();
  if (replCount + al.docs.length > cap) {
    fail(
      'Replacement bus has ${cap - replCount} free seats but ${al.docs.length} are needed.',
    );
  }
  final route = (await fs.doc('routes/${bus['routeId']}').get()).data();
  // A spare bus takes over the broken bus route. A bus that already has riders keeps its own route and must serve every stop.
  final keepsOwnRoute = replCount > 0;
  if (keepsOwnRoute) {
    final replStops = _stopsOf(
      (await fs.doc('routes/${repl['routeId']}').get()).data(),
    );
    if (al.docs.any((a) => !replStops.contains(a.data()['boardingPointId']))) {
      fail(
        'That bus already has riders and does not serve all these stops. Choose a spare bus.',
      );
    }
  }
  final given = '${d['replacementDriverId'] ?? ''}',
      driverId = given.isNotEmpty ? given : repl['driverId'] as String?;
  if (driverId == null) {
    fail('The replacement bus has no driver. Choose a replacement driver.');
  }
  final dr = (await fs.doc('drivers/$driverId').get()).data();
  if (dr == null || dr['status'] != 'active') fail('Driver is not active.');
  final region = bus['permittedRegionId'];
  if (region != null &&
      !((dr['permittedRegionIds'] as List?) ?? []).contains(region)) {
    fail('Driver is not authorised for this region.');
  }
  final drBus = dr['assignedBusId'];
  if (drBus != null && drBus != replId && drBus != busId) {
    fail('Driver is already on bus $drBus.');
  }

  final em = fs.collection('emergencyActions').doc();
  final previous = {
    'bus': {
      'availability': bus['availability'],
      'maintenanceStatus': bus['maintenanceStatus'],
      'driverId': bus['driverId'],
    },
    'repl': {'routeId': repl['routeId'], 'driverId': repl['driverId']},
    'driverPrevBus': drBus,
  };
  final newRouteId = keepsOwnRoute ? repl['routeId'] : bus['routeId'];
  final m = <String, Object?>{}, ops = <void Function(WriteBatch)>[];
  for (final a in al.docs) {
    ops.add(
      (b) => b.update(a.reference, {
        'busId': replId,
        'routeId': newRouteId,
        'emergencyId': em.id,
        'originalBusId': busId,
      }),
    );
    final uid = '${a.data()['authUid']}';
    m.addAll(Mirror.rider(busId, uid, false));
    m.addAll(Mirror.rider(replId, uid, true));
  }
  ops.add(
    (b) => b.update(fs.doc('buses/$replId'), {
      if (!keepsOwnRoute) 'routeId': bus['routeId'],
      'driverId': driverId,
      'driverName': dr['name'],
      'driverContact': dr['contact'],
      'version': FieldValue.increment(1),
    }),
  );
  ops.add(
    (b) => b.update(fs.doc('buses/$busId'), {
      'availability': false,
      'maintenanceStatus': 'breakdown',
      if (bus['driverId'] == driverId) ...{
        'driverId': null,
        'driverName': null,
        'driverContact': null,
      },
      'version': FieldValue.increment(1),
    }),
  );
  if (driverId != repl['driverId']) {
    final old = repl['driverId'] as String?;
    if (old != null) {
      ops.add((b) => b.update(fs.doc('drivers/$old'), {'assignedBusId': null}));
      ops.add((b) => b.update(fs.doc('users/$old'), {'busId': null}));
      m.addAll(Mirror.writer(replId, old, false));
    }
    ops.add(
      (b) => b.update(fs.doc('drivers/$driverId'), {'assignedBusId': replId}),
    );
    ops.add((b) => b.update(fs.doc('users/$driverId'), {'busId': replId}));
    if (drBus != null && drBus != replId) {
      m.addAll(Mirror.writer('$drBus', driverId, false));
    }
    m.addAll(Mirror.writer(replId, driverId, true));
  }
  if (!keepsOwnRoute) m.addAll(Mirror.busStops(replId, _stopsOf(route)));
  await writeAll(ops);
  await Mirror.apply(m);
  await em.set({
    'emergencyId': em.id,
    'affectedBusId': busId,
    'replacementBusId': replId,
    'driverId': driverId,
    'actionType': 'bus_replacement',
    'routeChanged': !keepsOwnRoute,
    'reason': reason,
    'previousValues': previous,
    'newValues': {'replacementBusId': replId, 'driverId': driverId},
    'affectedStudentIds': al.docs.map((a) => a.data()['studentId']).toList(),
    'createdBy': actor.uid,
    'createdAt': FieldValue.serverTimestamp(),
    'expiresAt': Timestamp.fromDate(DateTime.now().add(Duration(hours: hours))),
    'reviewStatus': 'active',
  });
  await recountBus(busId);
  await recountBus(replId);
  for (final a in al.docs.take(200)) {
    await notify(
      '${a.data()['authUid']}',
      'Your bus was replaced',
      'Bus ${repl['busNumber']} will serve your route. Reason: $reason',
    );
  }
  await notify(
    driverId,
    'Emergency assignment',
    'You are driving bus ${repl['busNumber']}. Tap refresh to see it.',
  );
  await raiseAlert(
    busId,
    'emergency',
    'high',
    'Bus ${bus['busNumber']} replaced by ${repl['busNumber']}: $reason',
  );
  await audit(
    actor,
    'emergencyReplaceBus',
    'emergencyActions/${em.id}',
    previous,
    {'replacementBusId': replId, 'driverId': driverId},
    reason,
  );
  return {'emergencyId': em.id, 'moved': al.docs.length};
}

Future<M> emergencyRouteChange(M d) async {
  final actor = await need(adminRoles);
  final busId = '${d['busId'] ?? ''}',
      reason = '${d['reason'] ?? ''}'.trim(),
      hours = (d['hours'] as num?)?.toInt() ?? 8;
  final stopIds = List<String>.from((d['stopIds'] as List?) ?? []);
  _needReason(reason);
  if (stopIds.isEmpty) fail('The new route needs at least one stop.');
  final bus = (await fs.doc('buses/$busId').get()).data();
  if (bus?['routeId'] == null) fail('This bus has no route.');
  final old = (await fs.doc('routes/${bus!['routeId']}').get()).data()!;
  final al = await fs
      .collection('allocations')
      .where('busId', isEqualTo: busId)
      .where('status', isEqualTo: 'active')
      .get();
  final missing = al.docs
      .map((a) => a.data()['boardingPointId'])
      .toSet()
      .where((id) => !stopIds.contains(id));
  if (missing.isNotEmpty) {
    fail(
      'Some riders board at stops you left out. Keep every stop that has riders, or move those riders first.',
    );
  }
  final stops = <M>[];
  for (final id in stopIds) {
    final p = (await fs.doc('boardingPoints/$id').get()).data();
    if (p == null || p['approvalStatus'] != 'approved') {
      fail('Every stop must be an approved boarding point.');
    }
    stops.add(p);
  }
  final c = await college();
  final road = await osrm([
    for (final s in stops)
      [(s['longitude'] as num).toDouble(), (s['latitude'] as num).toDouble()],
    [(c['lng'] as num).toDouble(), (c['lat'] as num).toDouble()],
  ]);
  final tmp = fs.collection('routes').doc(),
      em = fs.collection('emergencyActions').doc();
  await tmp.set({
    'routeId': tmp.id,
    'routeName': '${old['routeName']} (temporary)',
    'origin': stops.first['name'],
    'destination': c['name'] ?? 'College',
    'stopIds': stopIds,
    'permittedRegionId': old['permittedRegionId'],
    'routeGeometry': road.geometry,
    'routeKm': (road.km * 10).round() / 10,
    'arrivalBy': old['arrivalBy'],
    'status': 'temporary',
    'parentRouteId': bus['routeId'],
    'version': 1,
  });
  await writeAll([
    for (final a in al.docs)
      (b) => b.update(a.reference, {
        'routeId': tmp.id,
        'originalRouteId': bus['routeId'],
        'emergencyId': em.id,
      }),
  ]);
  await fs.doc('buses/$busId').update({
    'routeId': tmp.id,
    'version': FieldValue.increment(1),
  });
  await Mirror.apply(Mirror.busStops(busId, stopIds));
  await em.set({
    'emergencyId': em.id,
    'affectedBusId': busId,
    'actionType': 'route_change',
    'reason': reason,
    'previousValues': {'routeId': bus['routeId']},
    'newValues': {'routeId': tmp.id},
    'tmpRouteId': tmp.id,
    'affectedStudentIds': al.docs.map((a) => a.data()['studentId']).toList(),
    'createdBy': actor.uid,
    'createdAt': FieldValue.serverTimestamp(),
    'expiresAt': Timestamp.fromDate(DateTime.now().add(Duration(hours: hours))),
    'reviewStatus': 'active',
  });
  for (final a in al.docs.take(200)) {
    await notify(
      '${a.data()['authUid']}',
      'Route changed for now',
      'Your bus is on a temporary route. Reason: $reason',
    );
  }
  await notify(
    bus['driverId'] as String?,
    'Temporary route',
    'Your route was changed. Tap refresh to see the new stops.',
  );
  await raiseAlert(
    busId,
    'emergency',
    'high',
    'Temporary route for bus ${bus['busNumber']}: $reason',
  );
  await audit(
    actor,
    'emergencyRouteChange',
    'emergencyActions/${em.id}',
    {'routeId': bus['routeId']},
    {'routeId': tmp.id},
    reason,
  );
  return {'emergencyId': em.id, 'routeId': tmp.id, 'riders': al.docs.length};
}

Future<M> emergencyReplaceDriver(M d) async {
  final actor = await need(adminRoles);
  final busId = '${d['busId'] ?? ''}',
      driverId = '${d['driverId'] ?? ''}',
      reason = '${d['reason'] ?? ''}'.trim(),
      hours = (d['hours'] as num?)?.toInt() ?? 8;
  _needReason(reason);
  final bus = (await fs.doc('buses/$busId').get()).data();
  if (bus == null) fail('Bus not found.');
  final dr = (await fs.doc('drivers/$driverId').get()).data();
  if (dr == null || dr['status'] != 'active') {
    fail('That driver is not active.');
  }
  final region = bus['permittedRegionId'];
  if (region != null &&
      !((dr['permittedRegionIds'] as List?) ?? []).contains(region)) {
    fail('That driver is not authorised for this region.');
  }
  if (dr['assignedBusId'] != null && dr['assignedBusId'] != busId) {
    fail('That driver is already on bus ${dr['assignedBusId']}.');
  }
  if (bus['driverId'] == driverId) fail('That driver is already on this bus.');
  final em = fs.collection('emergencyActions').doc(),
      prev = bus['driverId'] as String?;
  final m = <String, Object?>{}, ops = <void Function(WriteBatch)>[];
  if (prev != null) {
    ops.add((b) => b.update(fs.doc('drivers/$prev'), {'assignedBusId': null}));
    ops.add((b) => b.update(fs.doc('users/$prev'), {'busId': null}));
    m.addAll(Mirror.writer(busId, prev, false));
  }
  ops.add(
    (b) => b.update(fs.doc('drivers/$driverId'), {'assignedBusId': busId}),
  );
  ops.add((b) => b.update(fs.doc('users/$driverId'), {'busId': busId}));
  ops.add(
    (b) => b.update(fs.doc('buses/$busId'), {
      'driverId': driverId,
      'driverName': dr['name'],
      'driverContact': dr['contact'],
      'version': FieldValue.increment(1),
    }),
  );
  m.addAll(Mirror.writer(busId, driverId, true));
  await writeAll(ops);
  await Mirror.apply(m);
  await notify(
    prev,
    'Assignment changed',
    'You were taken off bus ${bus['busNumber']}. Reason: $reason',
  );
  await notify(
    driverId,
    'Emergency assignment',
    'You are driving bus ${bus['busNumber']}. Tap refresh to see it.',
  );
  await em.set({
    'emergencyId': em.id,
    'affectedBusId': busId,
    'actionType': 'driver_change',
    'driverId': driverId,
    'reason': reason,
    'previousValues': {
      'driverId': prev,
      'newDriverPrevBus': dr['assignedBusId'],
    },
    'newValues': {'driverId': driverId},
    'affectedStudentIds': [],
    'createdBy': actor.uid,
    'createdAt': FieldValue.serverTimestamp(),
    'expiresAt': Timestamp.fromDate(DateTime.now().add(Duration(hours: hours))),
    'reviewStatus': 'active',
  });
  await audit(
    actor,
    'emergencyReplaceDriver',
    'emergencyActions/${em.id}',
    {'driverId': prev},
    {'driverId': driverId},
    reason,
  );
  return {'emergencyId': em.id};
}

Future<M> reviewEmergency(M d) async {
  final actor = await need(adminRoles);
  final ref = fs.doc('emergencyActions/${d['emergencyId']}'),
      em = (await ref.get()).data();
  if (em == null || !['active', 'review_required'].contains(em['reviewStatus'])) {
    fail('Nothing to review.');
  }
  if (d['action'] == 'keep') {
    if (em['tmpRouteId'] != null) {
      await fs.doc('routes/${em['tmpRouteId']}').update({'status': 'active'});
    }
    await ref.update({'reviewStatus': 'confirmed', 'reviewedBy': actor.uid});
    await audit(actor, 'confirmEmergency', 'emergencyActions/${ref.id}');
    return {'ok': true};
  }
  final type = em['actionType'];
  if (type == 'route_change') {
    await _revertRoute(em);
  } else if (type == 'driver_change') {
    await _revertDriver(em);
  } else {
    await _revertReplacement(em, d['restoreBus'] == true);
  }
  await ref.update({'reviewStatus': 'reverted', 'reviewedBy': actor.uid});
  await resolveAlert('${em['affectedBusId']}', 'emergency');
  await resolveAlert('${em['affectedBusId']}', 'emergency_review');
  await audit(actor, 'revertEmergency', 'emergencyActions/${ref.id}', null, {
    'type': type,
  });
  return {'ok': true};
}

Future<void> _revertRoute(M em) async {
  final busId = '${em['affectedBusId']}',
      pv = Map<String, dynamic>.from(em['previousValues'] as Map);
  final al = await fs
      .collection('allocations')
      .where('emergencyId', isEqualTo: em['emergencyId'])
      .where('status', isEqualTo: 'active')
      .get();
  await writeAll([
    for (final a in al.docs)
      (b) => b.update(a.reference, {
        'routeId': pv['routeId'],
        'emergencyId': FieldValue.delete(),
        'originalRouteId': FieldValue.delete(),
      }),
  ]);
  await fs.doc('buses/$busId').update({
    'routeId': pv['routeId'],
    'version': FieldValue.increment(1),
  });
  final route = (await fs.doc('routes/${pv['routeId']}').get()).data();
  await Mirror.apply(Mirror.busStops(busId, _stopsOf(route)));
  try {
    await fs.doc('routes/${em['tmpRouteId']}').delete();
  } catch (_) {}
  for (final a in al.docs.take(200)) {
    await notify(
      '${a.data()['authUid']}',
      'Route restored',
      'Your bus is back on its normal route.',
    );
  }
}

Future<void> _revertDriver(M em) async {
  final busId = '${em['affectedBusId']}',
      driverId = '${em['driverId']}',
      pv = Map<String, dynamic>.from(em['previousValues'] as Map);
  final prev = pv['driverId'] as String?,
      prevDr = prev == null
          ? null
          : (await fs.doc('drivers/$prev').get()).data();
  final m = <String, Object?>{...Mirror.writer(busId, driverId, false)};
  final ops = <void Function(WriteBatch)>[
    (b) => b.update(fs.doc('buses/$busId'), {
      'driverId': prev,
      'driverName': prevDr?['name'],
      'driverContact': prevDr?['contact'],
      'version': FieldValue.increment(1),
    }),
    (b) => b.update(fs.doc('drivers/$driverId'), {
      'assignedBusId': pv['newDriverPrevBus'],
    }),
    (b) =>
        b.update(fs.doc('users/$driverId'), {'busId': pv['newDriverPrevBus']}),
    if (prev != null)
      (b) => b.update(fs.doc('drivers/$prev'), {'assignedBusId': busId}),
    if (prev != null) (b) => b.update(fs.doc('users/$prev'), {'busId': busId}),
  ];
  if (prev != null) m.addAll(Mirror.writer(busId, prev, true));
  if (pv['newDriverPrevBus'] != null) {
    m.addAll(Mirror.writer('${pv['newDriverPrevBus']}', driverId, true));
  }
  await writeAll(ops);
  await Mirror.apply(m);
  if (prev != null) {
    await notify(prev, 'Assignment restored', 'You are back on your bus.');
  }
}

Future<void> _revertReplacement(M em, bool restoreBus) async {
  final busId = '${em['affectedBusId']}',
      replId = '${em['replacementBusId']}',
      driverId = '${em['driverId']}';
  final pv = Map<String, dynamic>.from(em['previousValues'] as Map),
      pvBus = Map<String, dynamic>.from(pv['bus'] as Map),
      pvRepl = Map<String, dynamic>.from(pv['repl'] as Map);
  final bus = (await fs.doc('buses/$busId').get()).data()!;
  final al = await fs
      .collection('allocations')
      .where('emergencyId', isEqualTo: em['emergencyId'])
      .where('status', isEqualTo: 'active')
      .get();
  final m = <String, Object?>{}, ops = <void Function(WriteBatch)>[];
  for (final a in al.docs) {
    ops.add(
      (b) => b.update(a.reference, {
        'busId': busId,
        'routeId': bus['routeId'],
        'emergencyId': FieldValue.delete(),
        'originalBusId': FieldValue.delete(),
      }),
    );
    final uid = '${a.data()['authUid']}';
    m.addAll(Mirror.rider(replId, uid, false));
    m.addAll(Mirror.rider(busId, uid, true));
  }
  final oldRepl = pvRepl['driverId'] as String?,
      oldReplDr = oldRepl == null
          ? null
          : (await fs.doc('drivers/$oldRepl').get()).data();
  ops.add(
    (b) => b.update(fs.doc('buses/$replId'), {
      if (em['routeChanged'] == true) 'routeId': pvRepl['routeId'],
      'driverId': oldRepl,
      'driverName': oldReplDr?['name'],
      'driverContact': oldReplDr?['contact'],
      'version': FieldValue.increment(1),
    }),
  );
  if (driverId != oldRepl) {
    ops.add(
      (b) => b.update(fs.doc('drivers/$driverId'), {
        'assignedBusId': pv['driverPrevBus'],
      }),
    );
    ops.add(
      (b) =>
          b.update(fs.doc('users/$driverId'), {'busId': pv['driverPrevBus']}),
    );
    m.addAll(Mirror.writer(replId, driverId, false));
    if (pv['driverPrevBus'] != null) {
      m.addAll(Mirror.writer('${pv['driverPrevBus']}', driverId, true));
    }
    if (oldRepl != null) {
      ops.add(
        (b) => b.update(fs.doc('drivers/$oldRepl'), {'assignedBusId': replId}),
      );
      ops.add((b) => b.update(fs.doc('users/$oldRepl'), {'busId': replId}));
      m.addAll(Mirror.writer(replId, oldRepl, true));
    }
  }
  if (restoreBus) {
    final bd = pvBus['driverId'] as String?,
        bdr = bd == null ? null : (await fs.doc('drivers/$bd').get()).data();
    ops.add(
      (b) => b.update(fs.doc('buses/$busId'), {
        'availability': true,
        'maintenanceStatus': 'ok',
        'driverId': bd,
        'driverName': bdr?['name'],
        'driverContact': bdr?['contact'],
        'version': FieldValue.increment(1),
      }),
    );
  }
  await writeAll(ops);
  await Mirror.apply(m);
  if (em['routeChanged'] == true) {
    final route = (await fs.doc('routes/${pvRepl['routeId']}').get()).data();
    await Mirror.apply(Mirror.busStops(replId, _stopsOf(route)));
  }
  await recountBus(busId);
  await recountBus(replId);
  for (final a in al.docs.take(200)) {
    await notify(
      '${a.data()['authUid']}',
      'Bus restored',
      'Your original bus is serving your route again.',
    );
  }
}

const _reportTypes = {
  'breakdown': 'Breakdown',
  'delay': 'Running late',
  'road_blocked': 'Road blocked',
  'accident': 'Accident',
  'other': 'Other problem',
};

Future<M> driverReport(M d) async {
  final c = await need(['driver']);
  final type = '${d['type']}';
  if (!_reportTypes.containsKey(type)) fail('Choose what happened.');
  if (c.busId == null) fail('No bus is assigned to you.');
  final note = '${d['note'] ?? ''}'.trim();
  final ref = fs.doc('alerts/open_${c.busId}_driver_$type');
  try {
    await ref.set({
      'alertId': ref.id,
      'busId': c.busId,
      'alertType': 'driver_$type',
      'severity': ['breakdown', 'accident'].contains(type) ? 'high' : 'medium',
      'description':
          'Driver report: ${_reportTypes[type]}.${note.isEmpty ? '' : ' ${note.length > 300 ? note.substring(0, 300) : note}'}',
      'status': 'open',
      'createdAt': FieldValue.serverTimestamp(),
      'acknowledgedAt': null,
      'acknowledgedBy': null,
    });
  } on FirebaseException {
    fail('This problem is already reported and still open.');
  }
  return {'ok': true};
}
