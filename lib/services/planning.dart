import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/logic.dart' as lg;
import 'common.dart';

Future<M> previewAcademicRollover(M d) async {
  final actor = await need(adminRoles);
  final date = '${d['date'] ?? dateKey()}';
  final configRef = fs.doc('config/academicRollover');
  final existing = await fs
      .collection('academicRolloverHistory')
      .where('date', isEqualTo: date)
      .limit(1)
      .get();
  if (existing.docs.isNotEmpty) {
    fail('This academic rollover date has already been completed.');
  }
  final students = await fs.collection('students').get();
  final changes = <M>[];
  for (final doc in students.docs) {
    final s = doc.data();
    final status =
        '${s['studentStatus'] ?? s['registrationStatus'] ?? 'active'}'
            .toLowerCase();
    if (['graduated', 'withdrawn', 'inactive'].contains(status)) continue;
    final year = (s['academicYear'] as num?)?.toInt();
    if (year == null || year < 1) continue;
    final next = year >= 4 ? 'Graduated / inactive' : year + 1;
    changes.add({
      'studentId': doc.id,
      'name': s['name'],
      'previousAcademicYear': year,
      'nextAcademicYear': next,
    });
  }
  await configRef.set({
    'lastPreviewDate': date,
    'lastPreviewBy': actor.uid,
  }, SetOptions(merge: true));
  return {'date': date, 'changes': changes, 'count': changes.length};
}

Future<M> applyAcademicRollover(M d) async {
  final actor = await need(adminRoles);
  final date = '${d['date'] ?? ''}';
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
    fail('Use a valid YYYY-MM-DD rollover date.');
  }
  final preview = await previewAcademicRollover({'date': date});
  if (d['confirmed'] != true) {
    return preview;
  }
  final ops = <void Function(WriteBatch)>[];
  for (final change
      in ((preview['changes'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList()) {
    final ref = fs.doc('students/${change['studentId']}');
    final from = change['previousAcademicYear'];
    final next = change['nextAcademicYear'];
    ops.add(
      (b) => b.update(ref, {
        'academicYear': next is int ? next : 4,
        'studentStatus': next is int ? 'active' : 'graduated',
        'academicHistory': FieldValue.arrayUnion([
          {'date': date, 'from': from, 'to': next},
        ]),
        'academicYearUpdatedAt': FieldValue.serverTimestamp(),
      }),
    );
  }
  await writeAll(ops);
  await fs.collection('academicRolloverHistory').add({
    'date': date,
    'actorId': actor.uid,
    'actorName': actor.name,
    'studentCount': (preview['changes'] as List).length,
    'completedAt': FieldValue.serverTimestamp(),
  });
  await audit(actor, 'academicRollover', 'students', null, {
    'date': date,
    'studentCount': (preview['changes'] as List).length,
  });
  return {'completed': true, 'count': (preview['changes'] as List).length};
}

Future<M> saveTransportTemplate(M d) async {
  final actor = await need(adminRoles);
  final name = '${d['name'] ?? ''}'.trim();
  if (name.isEmpty) fail('Template name is required.');
  final weekdays =
      (d['weekdays'] as List?)?.map((e) => '$e').toList() ?? <String>[];
  final valid = const {'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'};
  if (weekdays.isEmpty || weekdays.any((e) => !valid.contains(e))) {
    fail('Select one or more valid weekdays.');
  }
  final id = '${d['templateId'] ?? ''}'.trim();
  final ref = id.isEmpty
      ? fs.collection('transportTemplates').doc()
      : fs.doc('transportTemplates/$id');
  final data = <String, dynamic>{
    'templateId': ref.id,
    'name': name,
    'weekdays': weekdays,
    'specialDates':
        (d['specialDates'] as List?)?.map((e) => '$e').toList() ?? const [],
    'studentGroups': (d['studentGroups'] as Map?) == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(d['studentGroups'] as Map),
    'placeIds': (d['placeIds'] as List?)?.map((e) => '$e').toList() ?? const [],
    'boardingPointIds':
        (d['boardingPointIds'] as List?)?.map((e) => '$e').toList() ?? const [],
    'preferredBusIds':
        (d['preferredBusIds'] as List?)?.map((e) => '$e').toList() ?? const [],
    'preferredDriverIds':
        (d['preferredDriverIds'] as List?)?.map((e) => '$e').toList() ??
        const [],
    'routeIds': (d['routeIds'] as List?)?.map((e) => '$e').toList() ?? const [],
    'allocationArrangement': (d['allocationArrangement'] as Map?) == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(d['allocationArrangement'] as Map),
    'active': d['active'] != false,
    'updatedAt': FieldValue.serverTimestamp(),
  };
  if (id.isEmpty) data['createdAt'] = FieldValue.serverTimestamp();
  await ref.set(data, SetOptions(merge: true));
  await audit(
    actor,
    'saveTransportTemplate',
    'transportTemplates/${ref.id}',
    null,
    {'name': name, 'weekdays': weekdays},
  );
  return {'templateId': ref.id};
}

Future<M> duplicateTransportTemplate(M d) async {
  final actor = await need(adminRoles);
  final sourceId = '${d['templateId'] ?? ''}';
  final source = (await fs.doc('transportTemplates/$sourceId').get()).data();
  if (source == null) fail('Template not found.');
  final copy = Map<String, dynamic>.from(source)
    ..remove('templateId')
    ..remove('createdAt');
  copy['name'] = '${source['name']} (copy)';
  copy['active'] = false;
  final ref = fs.collection('transportTemplates').doc();
  copy['templateId'] = ref.id;
  copy['createdAt'] = FieldValue.serverTimestamp();
  copy['updatedAt'] = FieldValue.serverTimestamp();
  await ref.set(copy);
  await audit(
    actor,
    'duplicateTransportTemplate',
    'transportTemplates/${ref.id}',
  );
  return {'templateId': ref.id};
}

Future<M> setTransportTemplateActive(M d) async {
  final actor = await need(adminRoles);
  final id = '${d['templateId'] ?? ''}';
  final ref = fs.doc('transportTemplates/$id');
  if (!(await ref.get()).exists) fail('Template not found.');
  await ref.update({
    'active': d['active'] == true,
    'updatedAt': FieldValue.serverTimestamp(),
  });
  await audit(
    actor,
    'setTransportTemplateActive',
    'transportTemplates/$id',
    null,
    {'active': d['active'] == true},
  );
  return {'ok': true};
}

Future<M> saveDailyTransportPlan(M d) async {
  final actor = await need(adminRoles);
  final date = '${d['date'] ?? ''}';
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
    fail('Use a valid YYYY-MM-DD date.');
  }
  final attendance = (d['attendance'] as Map?) == null
      ? <String, dynamic>{}
      : Map<String, dynamic>.from(d['attendance'] as Map);
  if (attendance.values.any(
    (v) => !['attending', 'not_attending', 'not_confirmed'].contains('$v'),
  )) {
    fail('Attendance contains an invalid status.');
  }
  final students = await fs.collection('students').get();
  final points = await fs.collection('boardingPoints').get();
  final pointData = {for (final p in points.docs) p.id: p.data()};
  final attendingIds = attendance.entries
      .where((e) => e.value == 'attending')
      .map((e) => e.key)
      .toSet();
  final demandByPlace = <String, int>{};
  final demandByPoint = <String, int>{};
  for (final studentDoc in students.docs) {
    if (!attendingIds.contains(studentDoc.id)) continue;
    final s = studentDoc.data();
    final pointId = '${s['approvedBoardingPointId'] ?? ''}';
    final point = pointData[pointId];
    final place =
        '${point?['place'] ?? point?['district'] ?? s['place'] ?? 'Unassigned'}';
    demandByPlace[place] = (demandByPlace[place] ?? 0) + 1;
    if (pointId.isNotEmpty) {
      demandByPoint[pointId] = (demandByPoint[pointId] ?? 0) + 1;
    }
  }

  final buses = await fs.collection('buses').get();
  final assigned = (d['assignments'] as Map?) == null
      ? <String, dynamic>{}
      : Map<String, dynamic>.from(d['assignments'] as Map);
  final busLoads = <String, int>{};
  for (final busId in assigned.values) {
    busLoads['$busId'] = (busLoads['$busId'] ?? 0) + 1;
  }
  final warnings = <String>[];
  for (final bus in buses.docs) {
    final busId = bus.id;
    final b = bus.data();
    if (!busLoads.containsKey(busId)) continue;
    final load = busLoads[busId]!;
    final capacity = (b['capacity'] as num?)?.toInt();
    if (capacity == null || capacity < 1) {
      warnings.add(
        'Bus ${b['busNumber'] ?? busId} has no valid seating capacity.',
      );
      continue;
    }
    final status = lg.capacityStatus(capacity: capacity, assigned: load);
    if (status['overCapacity'] == true) {
      warnings.add(
        'Bus ${b['busNumber'] ?? busId} is over capacity by ${status['unaccommodated']} students.',
      );
    }
  }
  for (final entry in assigned.entries) {
    final studentId = entry.key;
    final busId = '${entry.value}';
    final busDoc = buses.docs.where((b) => b.id == busId).toList();
    if (busDoc.isEmpty) {
      warnings.add('Student $studentId references an unknown bus.');
      continue;
    }
    final bus = busDoc.first.data();
    if (bus['availability'] != true || bus['maintenanceStatus'] != 'ok') {
      warnings.add('Bus ${bus['busNumber'] ?? busId} is unavailable.');
    }
    final studentDocs = students.docs.where((s) => s.id == studentId).toList();
    final student = studentDocs.isEmpty ? null : studentDocs.first.data();
    final point = pointData['${student?['approvedBoardingPointId']}'];
    final routeId = bus['routeId'];
    if (routeId != null) {
      final route = (await fs.doc('routes/$routeId').get()).data();
      if (point != null &&
          !((route?['stopIds'] as List?) ?? []).contains(
            '${student?['approvedBoardingPointId']}',
          )) {
        warnings.add(
          'Bus ${bus['busNumber'] ?? busId} does not serve the student boarding point.',
        );
      }
    }
  }
  final published = d['publish'] == true;
  if (published && warnings.isNotEmpty) {
    fail('Publishing blocked:\n${warnings.join('\n')}');
  }
  final snapshot = <String, dynamic>{
    'date': date,
    'templateId': d['templateId'],
    'attendance': attendance,
    'assignments': assigned,
    'demandByPlace': demandByPlace,
    'demandByPoint': demandByPoint,
    'attendingCount': attendingIds.length,
    'warnings': warnings,
    'status': published ? 'published' : 'draft',
    'publishedAt': published ? FieldValue.serverTimestamp() : null,
    'publishedBy': published ? actor.uid : null,
    'snapshotCreatedAt': FieldValue.serverTimestamp(),
  };
  final ref = fs.doc('dailyTransportSchedules/$date');
  await ref.set(snapshot, SetOptions(merge: false));
  await audit(
    actor,
    published ? 'publishDailyTransportSchedule' : 'saveDailyTransportPlan',
    'dailyTransportSchedules/$date',
    null,
    snapshot,
  );
  return snapshot;
}
