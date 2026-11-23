import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/logic.dart' as lg;
import 'common.dart';

class Invalidated extends Fail {
  Invalidated(super.message);
}

/// Ends a student's active allocation (history is kept) and removes their live-map access.
Future<void> releaseAllocation(String studentId, String reason) async {
  final sRef = fs.doc('students/$studentId'), s = (await sRef.get()).data();
  if (s?['allocationId'] == null) return;
  final aRef = fs.doc('allocations/${s!['allocationId']}'), a = (await aRef.get()).data();
  await writeAll([
    (b) => b.update(aRef, {'status': 'cancelled', 'cancelledAt': FieldValue.serverTimestamp(), 'cancelReason': reason}),
    (b) => b.update(sRef, {'allocationId': null}),
  ]);
  if (a != null) {
    final uid = s['authUid'] as String?;
    if (uid != null) await Mirror.apply({...Mirror.rider('${a['busId']}', uid, false), ...Mirror.riderStop(uid, null)});
    await recountBus('${a['busId']}');
  }
}

Future<M> proposeAllocation(M d) async {
  final actor = await need(adminRoles);
  final conf = await cfg();
  final scheds = (await fs.collection('collegeSchedules').get()).docs.map((e) => e.data()).toList();
  bool scheduleOk(M s) => scheds.isEmpty || scheds.any((x) => ('${x['academicYear'] ?? ''}'.isEmpty || '${x['academicYear']}' == '${s['academicYear']}') && ('${x['departmentId'] ?? ''}'.isEmpty || x['departmentId'] == s['departmentId']));
  final all = (await fs.collection('students').get()).docs.map((e) => e.data()).toList();
  final students = all.where((s) => s['authUid'] != null && s['approvedBoardingPointId'] != null && s['allocationId'] == null && scheduleOk(s)).toList();
  final f = await loadFleet();
  final eligible = f.all.where((b) => b.availability && b.maintenanceStatus == 'ok' && b.routeId != null && b.driverId != null && b.driverAuthorized).toList();
  final sol = lg.greedyAllocate([for (final s in students) lg.Rider('${s['studentId']}', '${s['approvedBoardingPointId']}')], [for (final b in eligible) lg.GBus(b.id, max(0, b.capacity - b.allocated), b.stops, b.allocated > 0)]);
  final byStudent = {for (final s in students) '${s['studentId']}': s}, byBus = {for (final b in eligible) b.id: b};
  final changes = [
    for (final e in sol.assignments.entries)
      {'studentId': e.key, 'studentName': byStudent[e.key]!['name'], 'busId': e.value, 'busNumber': byBus[e.value]!.number, 'routeId': byBus[e.value]!.routeId, 'boardingPointId': byStudent[e.key]!['approvedBoardingPointId']},
  ];
  final served = eligible.expand((b) => b.stops).toSet();
  final unallocated = [
    for (final id in sol.unallocated)
      {'studentId': id, 'name': byStudent[id]!['name'], 'stopId': byStudent[id]!['approvedBoardingPointId'], 'reason': served.contains(byStudent[id]!['approvedBoardingPointId']) ? 'Buses on this stop are full' : 'No available bus serves this stop'},
  ];
  final baseBuses = {for (final b in eligible) b.id: {'capacity': b.capacity, 'allocated': b.allocated, 'routeId': b.routeId, 'driverId': b.driverId, 'busNumber': b.number}};
  final newlyUsed = changes.map((c) => c['busId']).toSet().where((id) => byBus[id]!.allocated == 0).length;
  final summary = {
    'eligible': students.length, 'assigned': changes.length, 'unallocated': unallocated.length, 'busesUsed': changes.map((c) => c['busId']).toSet().length, 'idleBusesStarted': newlyUsed, 'solver': 'built-in',
    'recommendation': unallocated.isNotEmpty ? 'Existing buses cannot take every student. Check the unallocated stops: extend a route or add a bus only if needed.' : 'All eligible students fit on existing buses; no extra bus is needed.',
  };
  if (changes.length > 3000) fail('Too many students for one proposal. Allocate in smaller groups.');
  final ref = fs.collection('changeRequests').doc();
  await ref.set({'requestId': ref.id, 'type': 'allocation', 'requestedBy': actor.uid, 'requestDescription': d['description'] ?? 'Automatic allocation', 'proposedChanges': changes, 'unallocated': unallocated, 'baseBuses': baseBuses, 'summary': summary, 'status': 'pending', 'academicYear': conf['academicYear'], 'createdAt': FieldValue.serverTimestamp(), 'reviewedBy': null, 'reviewedAt': null});
  await audit(actor, 'proposeAllocation', 'changeRequests/${ref.id}', null, summary);
  return {'requestId': ref.id, 'summary': summary, 'unallocated': unallocated.take(20).toList()};
}

Future<M> proposeRebalance(M d) async {
  final actor = await need(adminRoles);
  final conf = await cfg(), f = await loadFleet();
  final eligible = f.all.where((b) => b.availability && b.maintenanceStatus == 'ok' && b.routeId != null && b.driverId != null && b.driverAuthorized).toList();
  final plan = lg.planRebalance(eligible, f.riders);
  if (plan.moves.isEmpty) return {'requestId': null, 'message': 'No bus can be freed right now. Every bus is needed for its riders, stops or seats.', 'summary': {'assigned': 0, 'busesFreed': []}};
  final byId = {for (final b in f.all) b.id: b};
  final rider = {for (final list in f.riderDocs.values) for (final r in list) '${r['studentId']}': r};
  final changes = [
    for (final m in plan.moves)
      {'studentId': m.studentId, 'studentName': rider[m.studentId]!['name'], 'authUid': rider[m.studentId]!['authUid'], 'allocationId': rider[m.studentId]!['allocationId'], 'boardingPointId': rider[m.studentId]!['boardingPointId'], 'fromBusId': m.from, 'fromBusNumber': byId[m.from]!.number, 'busId': m.to, 'busNumber': byId[m.to]!.number, 'routeId': byId[m.to]!.routeId},
  ];
  final baseBuses = {for (final id in changes.map((c) => c['busId']).toSet()) '$id': {'capacity': byId['$id']!.capacity, 'routeId': byId['$id']!.routeId, 'driverId': byId['$id']!.driverId, 'busNumber': byId['$id']!.number}};
  final summary = {'assigned': changes.length, 'busesFreed': plan.freed.map((id) => byId[id]!.number).toList(), 'recommendation': 'Riders keep their stop. Only the bus changes.'};
  final ref = fs.collection('changeRequests').doc();
  await ref.set({'requestId': ref.id, 'type': 'rebalance', 'requestedBy': actor.uid, 'requestDescription': d['description'] ?? 'Free up buses', 'proposedChanges': changes, 'unallocated': [], 'baseBuses': baseBuses, 'summary': summary, 'status': 'pending', 'academicYear': conf['academicYear'], 'createdAt': FieldValue.serverTimestamp(), 'reviewedBy': null, 'reviewedAt': null});
  await audit(actor, 'proposeRebalance', 'changeRequests/${ref.id}', null, summary);
  return {'requestId': ref.id, 'summary': summary};
}

Future<void> _checkBus(M? bus, M base) async {
  if (bus == null || bus['availability'] != true || bus['maintenanceStatus'] != 'ok' || bus['routeId'] != base['routeId'] || bus['driverId'] != base['driverId']) {
    throw Invalidated('Bus ${base['busNumber']} changed since the proposal was made.');
  }
}

Future<M> reviewChangeRequest(M d) async {
  final actor = await need(adminRoles);
  final ref = fs.doc('changeRequests/${d['requestId']}'), cr = (await ref.get()).data();
  if (cr == null || cr['status'] != 'pending') fail('This proposal is no longer pending.');
  if (d['approve'] != true) {
    await ref.update({'status': 'rejected', 'reviewedBy': actor.uid, 'reviewedAt': FieldValue.serverTimestamp()});
    await audit(actor, 'rejectChangeRequest', 'changeRequests/${ref.id}');
    return {'status': 'rejected'};
  }
  final applied = <M>[], skipped = <String>[];
  String? error;
  var invalid = false;
  try {
    if (cr['type'] == 'rebalance') {
      await _applyRebalance(cr, actor, applied, skipped);
    } else {
      await _applyAllocation(cr, actor, applied, skipped);
    }
  } on Invalidated catch (e) { error = e.message; invalid = true; }
  on Fail catch (e) { error = e.message; }
  final status = invalid && applied.isEmpty ? 'invalidated' : (error != null || skipped.isNotEmpty ? 'partially_applied' : 'applied');
  await ref.update({'status': status, 'reviewedBy': actor.uid, 'reviewedAt': FieldValue.serverTimestamp(), 'invalidReason': error, 'result': {'applied': applied.length, 'skipped': skipped}});
  await audit(actor, 'approveChangeRequest', 'changeRequests/${ref.id}', null, {'type': cr['type'], 'applied': applied.length, 'skipped': skipped.length});
  if (error != null) fail(applied.isEmpty ? error : 'Applied ${applied.length}, then stopped: $error');
  return {'status': status, 'applied': applied.length, 'skipped': skipped.length};
}

Future<void> _applyAllocation(M cr, Ctx actor, List<M> applied, List<String> skipped) async {
  final groups = <String, List<M>>{};
  for (final c in (cr['proposedChanges'] as List)) { final m = Map<String, dynamic>.from(c as Map); (groups['${m['busId']}'] ??= []).add(m); }
  final base = Map<String, dynamic>.from(cr['baseBuses'] as Map);
  for (final e in groups.entries) {
    final busId = e.key, bus = (await fs.doc('buses/$busId').get()).data(), bb = Map<String, dynamic>.from(base[busId] as Map);
    await _checkBus(bus, bb);
    var count = await activeCount(busId);
    for (final part in chunks(e.value, 8)) {
      final snaps = await fs.collection('students').where(FieldPath.documentId, whereIn: part.map((c) => '${c['studentId']}').toList()).get();
      final cur = {for (final s in snaps.docs) s.id: s.data()};
      final ok = part.where((c) {
        final s = cur['${c['studentId']}'];
        final good = s != null && s['authUid'] != null && s['approvedBoardingPointId'] == c['boardingPointId'] && s['allocationId'] == null;
        if (!good) skipped.add('${c['studentId']}');
        return good;
      }).toList();
      if (count + ok.length > (bus!['capacity'] as num)) fail('Bus ${bus['busNumber']} would exceed its capacity.');
      final ops = <void Function(WriteBatch)>[], m = <String, Object?>{};
      for (final c in ok) {
        final id = '${c['studentId']}_${cr['academicYear']}', uid = '${cur['${c['studentId']}']!['authUid']}';
        ops.add((b) => b.set(fs.doc('allocations/$id'), {'allocationId': id, 'studentId': c['studentId'], 'authUid': uid, 'busId': busId, 'routeId': c['routeId'], 'boardingPointId': c['boardingPointId'], 'academicYear': cr['academicYear'], 'status': 'active', 'allocatedAt': FieldValue.serverTimestamp(), 'approvedBy': actor.uid}));
        ops.add((b) => b.update(fs.doc('students/${c['studentId']}'), {'allocationId': id}));
        m.addAll(Mirror.rider(busId, uid, true));
        m.addAll(Mirror.riderStop(uid, '${c['boardingPointId']}'));
        applied.add({...c, 'authUid': uid});
      }
      await writeAll(ops);
      await Mirror.apply(m);
      count += ok.length;
    }
    await recountBus(busId);
  }
}

Future<void> _applyRebalance(M cr, Ctx actor, List<M> applied, List<String> skipped) async {
  final groups = <String, List<M>>{};
  for (final c in (cr['proposedChanges'] as List)) { final m = Map<String, dynamic>.from(c as Map); (groups['${m['busId']}'] ??= []).add(m); }
  final base = Map<String, dynamic>.from(cr['baseBuses'] as Map), fromBuses = <String>{};
  for (final e in groups.entries) {
    final busId = e.key, bus = (await fs.doc('buses/$busId').get()).data(), bb = Map<String, dynamic>.from(base[busId] as Map);
    await _checkBus(bus, bb);
    var count = await activeCount(busId);
    for (final part in chunks(e.value, 8)) {
      final snaps = await fs.collection('allocations').where(FieldPath.documentId, whereIn: part.map((c) => '${c['allocationId']}').toList()).get();
      final cur = {for (final s in snaps.docs) s.id: s.data()};
      final ok = part.where((c) {
        final x = cur['${c['allocationId']}'];
        final good = x != null && x['status'] == 'active' && x['busId'] == c['fromBusId'] && x['boardingPointId'] == c['boardingPointId'];
        if (!good) skipped.add('${c['studentId']}');
        return good;
      }).toList();
      if (count + ok.length > (bus!['capacity'] as num)) fail('Bus ${bus['busNumber']} would exceed its capacity.');
      final ops = <void Function(WriteBatch)>[], m = <String, Object?>{};
      for (final c in ok) {
        ops.add((b) => b.update(fs.doc('allocations/${c['allocationId']}'), {'busId': busId, 'routeId': bus['routeId'], 'previousBusId': c['fromBusId'], 'rebalancedAt': FieldValue.serverTimestamp()}));
        m.addAll(Mirror.rider('${c['fromBusId']}', '${c['authUid']}', false));
        m.addAll(Mirror.rider(busId, '${c['authUid']}', true));
        fromBuses.add('${c['fromBusId']}');
        applied.add(c);
      }
      await writeAll(ops);
      await Mirror.apply(m);
      count += ok.length;
    }
    await recountBus(busId);
  }
  for (final id in fromBuses) { await recountBus(id); }
  for (final c in applied) { await notify('${c['authUid']}', 'Your bus changed', 'You are now on bus ${c['busNumber']}. Same stop, same route.'); }
}

Future<M> cancelAllocation(M d) async {
  final actor = await need(adminRoles);
  final reason = '${d['reason'] ?? ''}'.trim();
  if (reason.length < 3) fail('A reason is required.');
  final s = (await fs.doc('students/${d['studentId']}').get()).data();
  if (s?['allocationId'] == null) fail('This student has no allocation.');
  await releaseAllocation('${d['studentId']}', reason);
  await notify(s!['authUid'] as String?, 'Bus allocation removed', reason);
  await audit(actor, 'cancelAllocation', 'allocations/${s['allocationId']}', null, null, reason);
  return {'ok': true};
}

Future<M> moveStudent(M d) async {
  final actor = await need(adminRoles);
  final reason = '${d['reason'] ?? ''}'.trim(), toBusId = '${d['toBusId'] ?? ''}';
  if (reason.length < 3) fail('A reason is required.');
  final sRef = fs.doc('students/${d['studentId']}'), s = (await sRef.get()).data();
  if (s?['allocationId'] == null) fail('This student has no allocation.');
  final aRef = fs.doc('allocations/${s!['allocationId']}'), a = (await aRef.get()).data(), bus = (await fs.doc('buses/$toBusId').get()).data();
  if (a == null || a['status'] != 'active') fail('The allocation is not active.');
  if (a['busId'] == toBusId) fail('The student is already on that bus.');
  if (bus == null || bus['availability'] != true || bus['maintenanceStatus'] != 'ok' || bus['driverId'] == null || bus['routeId'] == null) fail('That bus is not available for allocation.');
  final route = (await fs.doc('routes/${bus['routeId']}').get()).data();
  if (!((route?['stopIds'] as List?) ?? []).contains(a['boardingPointId'])) fail('That bus does not serve the student\'s stop.');
  if (await activeCount(toBusId) >= (bus['capacity'] as num)) fail('That bus is full.');
  await aRef.update({'busId': toBusId, 'routeId': bus['routeId'], 'previousBusId': a['busId'], 'movedAt': FieldValue.serverTimestamp()});
  final uid = s['authUid'] as String?;
  if (uid != null) await Mirror.apply({...Mirror.rider('${a['busId']}', uid, false), ...Mirror.rider(toBusId, uid, true)});
  await recountBus('${a['busId']}');
  await recountBus(toBusId);
  await notify(uid, 'Your bus changed', 'An admin moved you to another bus. Reason: $reason');
  await audit(actor, 'moveStudent', 'allocations/${aRef.id}', {'busId': a['busId']}, {'busId': toBusId}, reason);
  return {'ok': true};
}

// ---------------- Alternative bus ----------------
Future<({M own, List<M> list})> _altCandidates(Ctx c) async {
  final s = (await fs.doc('students/${c.studentId}').get()).data();
  if (s == null || s['allocationId'] == null) fail('You need an active bus allocation first.');
  final own = (await fs.doc('allocations/${s['allocationId']}').get()).data();
  if (own == null || own['status'] != 'active') fail('You need an active bus allocation first.');
  final day = dateKey(), out = <M>[];
  final buses = await fs.collection('buses').where('availability', isEqualTo: true).get();
  for (final b in buses.docs) {
    final x = b.data();
    if (b.id == own['busId'] || x['maintenanceStatus'] != 'ok' || x['routeId'] == null || x['driverId'] == null || x['trackingStatus'] != 'active') continue;
    final route = (await fs.doc('routes/${x['routeId']}').get()).data();
    if (!((route?['stopIds'] as List?) ?? []).contains(s['approvedBoardingPointId'])) continue;
    final alt = await fs.collection('alternativeBoardings').where('alternativeBusId', isEqualTo: b.id).where('date', isEqualTo: day).where('status', isEqualTo: 'reserved').count().get();
    final left = (x['capacity'] as num).toInt() - ((x['allocated'] as num?)?.toInt() ?? 0) - (alt.count ?? 0);
    if (left > 0) out.add({'busId': b.id, 'busNumber': x['busNumber'], 'routeId': x['routeId'], 'routeName': route?['routeName'], 'seatsLeft': left, 'capacity': x['capacity'], 'stopId': s['approvedBoardingPointId']});
  }
  return (own: own, list: out);
}

Future<M> findAlternatives(M d) async {
  final c = await need(['student']);
  final r = await _altCandidates(c);
  return {'buses': [for (final b in r.list) {'busId': b['busId'], 'busNumber': b['busNumber'], 'routeName': b['routeName'], 'seatsLeft': b['seatsLeft']}]};
}

Future<M> reserveAlternative(M d) async {
  final c = await need(['student']);
  final r = await _altCandidates(c);
  final cand = r.list.where((b) => b['busId'] == d['busId']).toList();
  if (cand.isEmpty) fail('That bus cannot take you right now.');
  final bus = cand.first, day = dateKey(), ref = fs.doc('alternativeBoardings/${c.uid}_$day');
  final ex = (await ref.get()).data();
  if (ex != null && ex['status'] == 'reserved') fail('You already reserved an alternative bus today.');
  await ref.set({'authUid': c.uid, 'originalBusId': r.own['busId'], 'alternativeBusId': bus['busId'], 'boardingPointId': bus['stopId'], 'routeId': bus['routeId'], 'date': day, 'status': 'reserved', 'reservedAt': FieldValue.serverTimestamp()});
  // Last check after writing: another student may have taken the final seat at the same moment.
  final alt = await fs.collection('alternativeBoardings').where('alternativeBusId', isEqualTo: bus['busId']).where('date', isEqualTo: day).where('status', isEqualTo: 'reserved').count().get();
  final b = (await fs.doc('buses/${bus['busId']}').get()).data()!;
  if (((b['allocated'] as num?) ?? 0) + (alt.count ?? 0) > (b['capacity'] as num)) { await ref.delete(); fail('No seats left on that bus.'); }
  try {
    await rt('alt/${bus['busId']}/${c.uid}').set(DateTime.now().add(const Duration(hours: 12)).millisecondsSinceEpoch);
  } catch (_) {
    await ref.delete();
    fail('Could not turn on live tracking for that bus. Try again.');
  }
  return {'busNumber': bus['busNumber']};
}
