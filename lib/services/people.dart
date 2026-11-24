import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'common.dart';
import 'college_import_validation.dart';

Future<M> importCollegeData(M d) async {
  final actor = await need(adminRoles);
  final duplicatePolicy = '${d['duplicatePolicy'] ?? 'skip'}'.trim();
  if (!['skip', 'update'].contains(duplicatePolicy)) {
    fail('Duplicate policy must be skip or update.');
  }
  final busRows = (d['busRows'] as List? ?? const [])
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList();
  final studentRows = (d['studentRows'] as List? ?? const [])
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList();
  if (busRows.isEmpty && studentRows.isEmpty) {
    fail('Choose at least one buses.csv or students.csv file.');
  }
  if (busRows.length > 5000 || studentRows.length > 5000) {
    fail('Each CSV must contain no more than 5000 rows.');
  }

  final busDocs = await fs.collection('buses').get();
  final studentDocs = await fs.collection('students').get();
  final routeDocs = await fs.collection('routes').get();
  final pointDocs = await fs.collection('boardingPoints').get();
  final driverDocs = await fs.collection('drivers').get();
  final existingStudentData = {
    for (final doc in studentDocs.docs) doc.id: doc.data(),
  };
  final authUids = <String>{};
  for (final row in studentRows) {
    final id = stableImportId('${row['registerNumber'] ?? ''}');
    final existing = existingStudentData[id];
    final authUid = existing == null ? null : existing['authUid'];
    if (authUid is String && authUid.isNotEmpty) authUids.add(authUid);
  }
  final authenticatedUsers = <String, M>{};
  for (final part in chunks(authUids.toList(), 30)) {
    final users = await fs
        .collection('users')
        .where(FieldPath.documentId, whereIn: part)
        .get();
    for (final user in users.docs) {
      authenticatedUsers[user.id] = user.data();
    }
  }
  final allocationDocs = await fs
      .collection('allocations')
      .where('status', isEqualTo: 'active')
      .get();
  final today = dateKey();
  final alternativeDocs = await fs
      .collection('alternativeBoardings')
      .where('date', isEqualTo: today)
      .where('status', isEqualTo: 'reserved')
      .get();
  Map<String, M> documents(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) => {for (final doc in docs) doc.id: doc.data()};
  final activeCounts = <String, int>{};
  for (final doc in allocationDocs.docs) {
    final busId = '${doc.data()['busId'] ?? ''}';
    if (busId.isNotEmpty) activeCounts[busId] = (activeCounts[busId] ?? 0) + 1;
  }
  for (final doc in alternativeDocs.docs) {
    final busId = '${doc.data()['alternativeBusId'] ?? ''}';
    if (busId.isNotEmpty) activeCounts[busId] = (activeCounts[busId] ?? 0) + 1;
  }
  final preview = validateCollegeImport(
    busRows: busRows,
    studentRows: studentRows,
    existingBuses: documents(busDocs.docs),
    existingStudents: existingStudentData,
    authenticatedUsers: authenticatedUsers,
    routes: documents(routeDocs.docs),
    boardingPoints: documents(pointDocs.docs),
    drivers: documents(driverDocs.docs),
    activeAllocationCounts: activeCounts,
    duplicatePolicy: duplicatePolicy,
  );
  final result = <String, dynamic>{
    'validBuses': preview.busesToWrite.length,
    'validStudents': preview.studentsToWrite.length,
    'allocations': preview.allocationsToCreate.length,
    'notAllocated': preview.notAllocated.length,
    'dryRun': true,
    'errors': preview.errors,
    'notAllocatedRows': preview.notAllocated,
  };
  if (d['dryRun'] != false) return result;
  if (duplicatePolicy == 'update' && d['confirmedUpdates'] != true) {
    fail('Confirm explicitly before updating existing records.');
  }

  final existingBuses = documents(busDocs.docs);
  final existingStudents = documents(studentDocs.docs);
  final routesById = documents(routeDocs.docs);
  final driverOps = <void Function(WriteBatch)>[];
  final busMirrorUpdates = <String, Object?>{};
  final assignedDriverIds = <String>[];
  final assignedDriverBusNumbers = <String, String>{};
  for (final item in preview.busesToWrite) {
    final id = '${item['id']}';
    final data = Map<String, dynamic>.from(item['data'] as Map);
    data['version'] = item['existing'] == true ? FieldValue.increment(1) : 1;
    if (!item['existing']) {
      data.addAll({
        'driverName': null,
        'driverContact': null,
        'trackingStatus': 'offline',
      });
    }
    if (data.containsKey('driverId')) {
      final oldDriverId = '${existingBuses[id]?['driverId'] ?? ''}';
      final newDriverId = '${data['driverId'] ?? ''}';
      if (oldDriverId.isNotEmpty && oldDriverId != newDriverId) {
        driverOps.add(
          (batch) => batch.update(fs.doc('drivers/$oldDriverId'), {
            'assignedBusId': null,
            'updatedAt': FieldValue.serverTimestamp(),
          }),
        );
        driverOps.add(
          (batch) =>
              batch.update(fs.doc('users/$oldDriverId'), {'busId': null}),
        );
        busMirrorUpdates.addAll(Mirror.writer(id, oldDriverId, false));
      }
      if (newDriverId.isNotEmpty && oldDriverId != newDriverId) {
        final driver = driverDocs.docs
            .where((doc) => doc.id == newDriverId)
            .first
            .data();
        driverOps.add(
          (batch) => batch.update(fs.doc('drivers/$newDriverId'), {
            'assignedBusId': id,
            'updatedAt': FieldValue.serverTimestamp(),
          }),
        );
        driverOps.add(
          (batch) => batch.update(fs.doc('users/$newDriverId'), {'busId': id}),
        );
        busMirrorUpdates.addAll(Mirror.writer(id, newDriverId, true));
        assignedDriverIds.add(newDriverId);
        assignedDriverBusNumbers[newDriverId] = '${data['busNumber']}';
        data['driverName'] = driver['name'];
        data['driverContact'] = driver['contact'];
      }
      if (newDriverId.isEmpty) {
        data['driverName'] = null;
        data['driverContact'] = null;
      }
    }
    final routeId = data.containsKey('routeId')
        ? data['routeId']
        : existingBuses[id]?['routeId'];
    busMirrorUpdates.addAll(
      Mirror.busStops(
        id,
        ((routeId == null ? null : routesById['$routeId']?['stopIds']) as List?)
                ?.map((stop) => '$stop')
                .toList() ??
            const <String>[],
      ),
    );
    item['data'] = data;
  }
  final busOps = <void Function(WriteBatch)>[];
  for (final item in preview.busesToWrite) {
    final id = '${item['id']}';
    final data = Map<String, dynamic>.from(item['data'] as Map);
    final ref = fs.doc('buses/$id');
    if (item['existing'] == true) {
      busOps.add(
        (batch) => batch.update(ref, {
          ...data,
          'updatedAt': FieldValue.serverTimestamp(),
        }),
      );
    } else {
      busOps.add(
        (batch) => batch.set(ref, {
          ...data,
          'createdAt': FieldValue.serverTimestamp(),
        }),
      );
    }
  }
  busOps.addAll(driverOps);
  await writeAll(busOps, per: 400);
  if (busMirrorUpdates.isNotEmpty) await Mirror.apply(busMirrorUpdates);
  for (final driverId in assignedDriverIds) {
    await notify(
      driverId,
      'Bus assigned',
      'You are assigned to bus ${assignedDriverBusNumbers[driverId]}. Tap refresh to see it.',
    );
  }

  final outcomesByStudent = <String, M>{
    for (final row in preview.notAllocated) '${row['studentId']}': row,
  };
  final allocationsByStudent = <String, M>{
    for (final row in preview.allocationsToCreate) '${row['studentId']}': row,
  };
  final studentOps = <void Function(WriteBatch)>[];
  final invites = <M>[];
  final base = '${(await cfg())['webBaseUrl']}'.replaceAll(RegExp(r'/$'), '');
  for (final item in preview.studentsToWrite) {
    final id = '${item['id']}';
    final data = Map<String, dynamic>.from(item['data'] as Map);
    final ref = fs.doc('students/$id');
    final existing = item['existing'] == true;
    final outcome = outcomesByStudent[id];
    final allocation = allocationsByStudent[id];
    final currentAllocationId = existingStudents[id]?['allocationId'];
    final patch = <String, dynamic>{
      ...data,
      if (allocation == null && currentAllocationId == null)
        'allocationStatus': 'notAllocated',
      if (allocation == null && currentAllocationId == null)
        'allocationReason': outcome?['reason'],
      if (allocation != null)
        'approvedBoardingPointId': allocation['boardingPointId'],
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (existing) {
      studentOps.add((batch) => batch.update(ref, patch));
    } else {
      final token = randomToken(), hash = sha256Hex(token);
      studentOps.add(
        (batch) => batch.set(ref, {
          ...data,
          'authUid': null,
          'allocationId': null,
          'allocationStatus': 'notAllocated',
          'allocationReason':
              outcome?['reason'] ??
              'Student has no existing authenticated account.',
          'importBusNumber': data['importBusNumber'] ?? '',
          'importBoardingPointId': data['importBoardingPointId'] ?? '',
          'availableBoardingPointIds': <String>[],
          'registrationStatus': 'invited',
          'createdAt': FieldValue.serverTimestamp(),
        }),
      );
      studentOps.add(
        (batch) => batch.set(fs.doc('invites/$hash'), {
          'inviteId': hash,
          'studentId': id,
          'email': data['email'],
          'name': data['name'],
          'registerNumber': data['registerNumber'],
          'departmentId': data['departmentId'],
          'academicYear': data['academicYear'],
          'status': 'pending',
          'expiresAt': Timestamp.fromDate(
            DateTime.now().add(const Duration(days: 14)),
          ),
          'createdAt': FieldValue.serverTimestamp(),
        }),
      );
      invites.add({
        'registerNumber': data['registerNumber'],
        'name': data['name'],
        'email': data['email'],
        'code': token,
        'link': base.isEmpty ? null : '$base/register?code=$token',
      });
    }
  }

  await writeAll(studentOps, per: 400);
  final mirrorUpdates = <String, Object?>{};
  final touchedBusIds = <String>{};
  final liveAllocationCounts = <String, int>{};
  final currentAllocations = await fs
      .collection('allocations')
      .where('status', isEqualTo: 'active')
      .get();
  for (final doc in currentAllocations.docs) {
    final busId = '${doc.data()['busId'] ?? ''}';
    if (busId.isNotEmpty) {
      liveAllocationCounts[busId] = (liveAllocationCounts[busId] ?? 0) + 1;
    }
  }
  final currentAlternatives = await fs
      .collection('alternativeBoardings')
      .where('date', isEqualTo: dateKey())
      .where('status', isEqualTo: 'reserved')
      .get();
  final alternativeCounts = <String, int>{};
  for (final doc in currentAlternatives.docs) {
    final busId = '${doc.data()['alternativeBusId'] ?? ''}';
    if (busId.isNotEmpty) {
      alternativeCounts[busId] = (alternativeCounts[busId] ?? 0) + 1;
    }
  }
  final allocationErrors = <M>[];
  var createdAllocationCount = 0;
  for (final allocation in preview.allocationsToCreate) {
    final studentId = '${allocation['studentId']}';
    final busId = '${allocation['busId']}';
    final allocationRef = fs.collection('allocations').doc();
    final allocationId = allocationRef.id;
    final busRef = fs.doc('buses/$busId');
    final studentRef = fs.doc('students/$studentId');
    final routeId = '${allocation['routeId']}';
    final boardingPointId = '${allocation['boardingPointId']}';
    final driverId = '${allocation['driverId'] ?? ''}';
    try {
      await fs.runTransaction((transaction) async {
        final busSnapshot = await transaction.get(busRef);
        final studentSnapshot = await transaction.get(studentRef);
        final routeSnapshot = await transaction.get(fs.doc('routes/$routeId'));
        final pointSnapshot = await transaction.get(
          fs.doc('boardingPoints/$boardingPointId'),
        );
        final driverSnapshot = await transaction.get(
          fs.doc('drivers/$driverId'),
        );
        final userSnapshot = await transaction.get(
          fs.doc('users/${allocation['authUid']}'),
        );
        final bus = busSnapshot.data();
        final student = studentSnapshot.data();
        final route = routeSnapshot.data();
        final point = pointSnapshot.data();
        final driver = driverSnapshot.data();
        final user = userSnapshot.data();
        if (bus == null ||
            student == null ||
            route == null ||
            point == null ||
            driver == null ||
            user == null) {
          fail(
            'A required bus, student, route, boarding point, or driver no longer exists.',
          );
        }
        if (user['status'] != 'active' ||
            user['role'] != 'student' ||
            user['studentId'] != studentId) {
          fail(
            'Student account is no longer active or linked to this student.',
          );
        }
        if (student['authUid'] != allocation['authUid'] ||
            student['allocationId'] != null ||
            student['approvedBoardingPointId'] != boardingPointId) {
          fail(
            'Student account or boarding-point linkage changed after preview.',
          );
        }
        final busRegion = bus['permittedRegionId'];
        final permittedRegions =
            ((driver['permittedRegionIds'] as List?) ?? const [])
                .map((region) => '$region')
                .toList();
        if (bus['routeId'] != routeId ||
            bus['driverId'] != driverId ||
            bus['availability'] == false ||
            (bus['status'] != null && bus['status'] != 'active') ||
            (bus['maintenanceStatus'] != null &&
                bus['maintenanceStatus'] != 'ok') ||
            route['status'] != null && route['status'] != 'active' ||
            !((route['stopIds'] as List?) ?? const []).contains(
              boardingPointId,
            ) ||
            point['approvalStatus'] != 'approved' ||
            point['status'] == 'inactive' ||
            driver['status'] != 'active' ||
            driver['assignedBusId'] != busId ||
            (busRegion != null &&
                !permittedRegions.contains('$busRegion'))) {
          fail('A required transport relationship changed after preview.');
        }
        final capacity = (bus['capacity'] as num?)?.toInt();
        if (capacity == null || capacity < 1) {
          fail('Bus no longer has valid seating capacity.');
        }
        final storedCount = (bus['allocated'] as num?)?.toInt() ?? 0;
        final observedCount = liveAllocationCounts[busId] ?? 0;
        final occupied = storedCount > observedCount
            ? storedCount
            : observedCount;
        final reservedAlternatives = alternativeCounts[busId] ?? 0;
        if (occupied + reservedAlternatives + 1 > capacity) {
          fail('Bus ${bus['busNumber'] ?? busId} no longer has enough seats.');
        }
        transaction.set(allocationRef, {
          'allocationId': allocationId,
          'studentId': studentId,
          'authUid': allocation['authUid'],
          'busId': busId,
          'routeId': routeId,
          'boardingPointId': boardingPointId,
          'academicYear': allocation['academicYear'],
          'status': 'active',
          'allocatedAt': FieldValue.serverTimestamp(),
          'approvedBy': actor.uid,
        });
        transaction.update(studentRef, {
          'allocationId': allocationId,
          'allocationStatus': 'allocated',
          'allocationReason': FieldValue.delete(),
          'approvedBoardingPointId': boardingPointId,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        transaction.update(busRef, {
          'allocated': occupied + 1,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
      createdAllocationCount++;
      liveAllocationCounts[busId] = (liveAllocationCounts[busId] ?? 0) + 1;
    } on Fail catch (error) {
      allocationErrors.add({
        'category': 'allocation',
        'line': allocation['line'],
        'id': studentId,
        'registerNumber': allocation['registerNumber'],
        'error': error.message,
      });
      await studentRef.update({
        'allocationStatus': 'notAllocated',
        'allocationReason': error.message,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      continue;
    }
    mirrorUpdates.addAll(Mirror.rider(busId, '${allocation['authUid']}', true));
    mirrorUpdates.addAll(
      Mirror.riderStop(
        '${allocation['authUid']}',
        '${allocation['boardingPointId']}',
      ),
    );
    touchedBusIds.add(busId);
  }
  if (mirrorUpdates.isNotEmpty) await Mirror.apply(mirrorUpdates);
  for (final busId in touchedBusIds) {
    await recountBus(busId);
  }
  result
    ..['importedBuses'] = preview.busesToWrite.length
    ..['importedStudents'] = preview.studentsToWrite.length
    ..['createdAllocations'] = createdAllocationCount
    ..['notAllocated'] = preview.notAllocated.length + allocationErrors.length
    ..['errors'] = [...preview.errors, ...allocationErrors]
    ..['notAllocatedRows'] = [
      ...preview.notAllocated,
      ...allocationErrors.map(
        (error) => {
          'studentId': error['id'],
          'registerNumber': error['registerNumber'],
          'line': error['line'],
          'reason': error['error'],
        },
      ),
    ]
    ..['invites'] = invites
    ..['dryRun'] = false;
  await fs.collection('importHistory').add({
    'category': 'collegeTransport',
    'duplicatePolicy': duplicatePolicy,
    'importedBuses': preview.busesToWrite.length,
    'importedStudents': preview.studentsToWrite.length,
    'createdAllocations': preview.allocationsToCreate.length,
    'notAllocated': preview.notAllocated.length,
    'rejected': preview.errors.length + allocationErrors.length,
    'administratorId': actor.uid,
    'administratorName': actor.name,
    'importedAt': FieldValue.serverTimestamp(),
  });
  await audit(actor, 'importCollegeData', 'buses,students', null, {
    'importedBuses': preview.busesToWrite.length,
    'importedStudents': preview.studentsToWrite.length,
    'createdAllocations': preview.allocationsToCreate.length,
    'notAllocated': preview.notAllocated.length,
    'rejected': preview.errors.length + allocationErrors.length,
  });
  return result;
}

Future<M> importBusesData(M d) {
  if ('${d['category'] ?? ''}' != 'buses') {
    fail('Only buses.csv can be imported with this action.');
  }
  return importCollegeData({
    'busRows': d['rows'] ?? const [],
    'studentRows': const [],
    'dryRun': d['dryRun'],
    'duplicatePolicy': d['duplicatePolicy'],
    'confirmedUpdates': d['confirmedUpdates'],
  });
}

Future<M> importTransportData(M d) async {
  final actor = await need(adminRoles);
  final category = '${d['category'] ?? ''}'.trim();
  final duplicatePolicy = '${d['duplicatePolicy'] ?? 'skip'}'.trim();
  final rows = (d['rows'] as List?) ?? const [];
  if (category != 'buses') {
    fail('Only buses.csv can be imported with this action.');
  }
  if (!['skip', 'update'].contains(duplicatePolicy)) {
    fail('Duplicate policy must be skip or update.');
  }
  if (rows.isEmpty || rows.length > 5000) {
    fail('Provide between 1 and 5000 rows.');
  }
  final collectionName = category;
  final idKey = category == 'buses'
      ? 'busId'
      : category == 'drivers'
      ? 'driverId'
      : category == 'boardingPoints'
      ? 'boardingPointId'
      : category == 'routes'
      ? 'routeId'
      : 'studentId';
  final valid = <M>[];
  final errors = <M>[];
  final seenIds = <String>{};

  for (var i = 0; i < rows.length; i++) {
    final r = Map<String, dynamic>.from(rows[i] as Map);
    final line = i + 2;
    var id = '${r[idKey] ?? r['id'] ?? ''}'.trim();
    if (category == 'incompleteStudents' && id.isEmpty) {
      final registerNumber = '${r['registerNumber'] ?? r['rollNumber'] ?? ''}'
          .trim();
      if (registerNumber.isNotEmpty) id = safeId(registerNumber);
      if (id.isEmpty) id = 'incomplete_${i + 2}_$line';
    }
    String text(String key) => '${r[key] ?? ''}'.trim();
    if (id.isEmpty) {
      errors.add({'line': line, 'error': 'Missing $idKey.'});
      continue;
    }
    if (!seenIds.add(id)) {
      errors.add({'line': line, 'id': id, 'error': 'Duplicate ID in file.'});
      continue;
    }
    M data;
    if (category == 'buses') {
      final capacity = int.tryParse(text('capacity'));
      if (text('busNumber').isEmpty || capacity == null || capacity < 1) {
        errors.add({
          'line': line,
          'id': id,
          'error': 'Bus number and valid seating capacity are required.',
        });
        continue;
      }
      data = {
        idKey: id,
        'busNumber': text('busNumber'),
        'registrationNumber': text('registrationNumber'),
        'capacity': capacity,
        'permittedRegionId': text('permittedRegionId').isEmpty
            ? null
            : text('permittedRegionId'),
        'routeId': text('routeId').isEmpty ? null : text('routeId'),
        'status': text('status').isEmpty ? 'active' : text('status'),
        'availability': text('status').toLowerCase() != 'inactive',
        'maintenanceStatus': 'ok',
      };
    } else if (category == 'drivers') {
      if (text('driverName').isEmpty) {
        errors.add({
          'line': line,
          'id': id,
          'error': 'Driver name is required.',
        });
        continue;
      }
      final regions = text(
        'permittedRegionIds',
      ).split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      data = {
        idKey: id,
        'name': text('driverName'),
        'contact': text('contactNumber'),
        'permittedRegionIds': regions,
        'status': text('status').isEmpty ? 'active' : text('status'),
        'assignedBusId': null,
      };
    } else if (category == 'routes') {
      final name = text('routeName');
      final stopIds = text('stopIds')
          .split(RegExp(r'[;,|]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (name.isEmpty || stopIds.isEmpty) {
        errors.add({
          'line': line,
          'id': id,
          'error': 'Route name and at least one stop ID are required.',
        });
        continue;
      }
      data = {
        idKey: id,
        'routeName': name,
        'stopIds': stopIds,
        'permittedRegionId': text('permittedRegionId').isEmpty
            ? null
            : text('permittedRegionId'),
        'arrivalBy': text('arrivalBy'),
        'status': text('status').isEmpty ? 'active' : text('status'),
      };
    } else if (category == 'incompleteStudents') {
      if (text('studentName').isEmpty &&
          text('registerNumber').isEmpty &&
          text('email').isEmpty) {
        errors.add({
          'line': line,
          'id': id,
          'error': 'Student name, register number or email is required.',
        });
        continue;
      }
      final registerNumber = text('registerNumber');
      data = {
        idKey: id.isEmpty
            ? (registerNumber.isNotEmpty
                  ? safeId(registerNumber)
                  : 'incomplete_${line}_$i')
            : id,
        'studentId': id.isEmpty
            ? (registerNumber.isNotEmpty
                  ? safeId(registerNumber)
                  : 'incomplete_${line}_$i')
            : id,
        'registerNumber': registerNumber,
        'name': text('studentName'),
        'departmentId': text('departmentId'),
        'academicYear': int.tryParse(text('academicYear')),
        'place': text('place'),
        'boardingPointId': text('boardingPointId'),
        'busId': text('busId'),
        'busNumber': text('busNumber'),
        'driverId': text('driverId'),
        'email': text('email').toLowerCase(),
        'status': text('status').isEmpty ? 'incomplete' : text('status'),
        'reason': text('reason').isEmpty
            ? 'CSV import validation'
            : text('reason'),
        'sourceLine': line,
      };
    } else {
      final lat = double.tryParse(text('latitude'));
      final lng = double.tryParse(text('longitude'));
      if (text('boardingPointName').isEmpty ||
          lat == null ||
          lng == null ||
          lat < -90 ||
          lat > 90 ||
          lng < -180 ||
          lng > 180) {
        errors.add({
          'line': line,
          'id': id,
          'error': 'Name and valid latitude/longitude are required.',
        });
        continue;
      }
      data = {
        idKey: id,
        'name': text('boardingPointName'),
        'place': text('place'),
        'district': text('place'),
        'latitude': lat,
        'longitude': lng,
        'status': text('status').isEmpty ? 'active' : text('status'),
      };
    }
    valid.add(data);
  }

  if (category == 'routes') {
    final points = await fs.collection('boardingPoints').get();
    final pointIds = {for (final e in points.docs) e.id};
    final filtered = <M>[];
    for (final route in valid) {
      final missing = ((route['stopIds'] as List?) ?? [])
          .map((e) => '$e')
          .where((id) => !pointIds.contains(id))
          .toList();
      if (missing.isNotEmpty) {
        errors.add({
          'line': '',
          'id': route['routeId'],
          'error': 'Unknown boarding point IDs: ${missing.join(', ')}.',
        });
      } else {
        filtered.add(route);
      }
    }
    valid
      ..clear()
      ..addAll(filtered);
  } else if (category == 'buses') {
    final routes = await fs.collection('routes').get();
    final routeIds = {for (final e in routes.docs) e.id};
    final filtered = <M>[];
    for (final bus in valid) {
      final routeId = bus['routeId'] as String?;
      if (routeId != null && !routeIds.contains(routeId)) {
        errors.add({
          'line': '',
          'id': bus['busId'],
          'error': 'Unknown route ID: $routeId.',
        });
      } else {
        final existingBus = (await fs.doc('buses/${bus['busId']}').get())
            .data();
        final capacity = bus['capacity'] as int;
        final allocated = existingBus == null
            ? 0
            : ((existingBus['allocated'] as num?)?.toInt() ?? 0);
        if (allocated > capacity) {
          errors.add({
            'line': '',
            'id': bus['busId'],
            'error':
                'Capacity $capacity is below $allocated existing allocations.',
          });
        } else {
          filtered.add(bus);
        }
      }
    }
    valid
      ..clear()
      ..addAll(filtered);
  } else if (category == 'incompleteStudents') {
    final points = await fs.collection('boardingPoints').get();
    final buses = await fs.collection('buses').get();
    final drivers = await fs.collection('drivers').get();
    final pointIds = {for (final e in points.docs) e.id};
    final busIds = <String>{for (final e in buses.docs) e.id};
    final busNumbers = {
      for (final e in buses.docs) '${e.data()['busNumber']}': e.id,
    };
    final driverIds = {for (final e in drivers.docs) e.id};
    final filtered = <M>[];
    for (final student in valid) {
      final problems = <String>[];
      final pointId = '${student['boardingPointId'] ?? ''}'.trim();
      final busId = '${student['busId'] ?? ''}'.trim();
      final busNumber = '${student['busNumber'] ?? ''}'.trim();
      final resolvedBusId = busId.isNotEmpty
          ? busId
          : (busNumbers[busNumber] ?? '');
      final driverId = '${student['driverId'] ?? ''}'.trim();
      if (pointId.isNotEmpty && !pointIds.contains(pointId)) {
        problems.add('unknown boarding point ID');
      }
      if (resolvedBusId.isNotEmpty && !busIds.contains(resolvedBusId)) {
        problems.add('unknown bus');
      }
      if (driverId.isNotEmpty && !driverIds.contains(driverId)) {
        problems.add('unknown driver ID');
      }
      if (problems.isEmpty) {
        student['resolvedBusId'] = resolvedBusId.isEmpty ? null : resolvedBusId;
        filtered.add(student);
      } else {
        errors.add({
          'line': student['sourceLine'],
          'id': student['studentId'],
          'error': 'Incomplete reference problems: ${problems.join(', ')}.',
        });
      }
    }
    valid
      ..clear()
      ..addAll(filtered);
  }

  final existing = await fs.collection(collectionName).get();
  final existingIds = {for (final e in existing.docs) e.id};
  final toWrite = <M>[];
  for (final data in valid) {
    final id = '${data[idKey]}';
    if (existingIds.contains(id) && duplicatePolicy == 'skip') {
      errors.add({
        'id': id,
        'error': 'Existing $idKey skipped. Choose update to change it.',
      });
    } else {
      toWrite.add(data);
    }
  }

  if (d['dryRun'] != false) {
    return {'valid': toWrite.length, 'errors': errors};
  }
  final ops = <void Function(WriteBatch)>[];
  for (final data in toWrite) {
    final id = '${data[idKey]}';
    final ref = fs.doc('$collectionName/$id');
    final current = existing.docs.where((e) => e.id == id).toList();
    ops.add((b) {
      if (duplicatePolicy == 'update' && current.isNotEmpty) {
        b.update(ref, {...data, 'updatedAt': FieldValue.serverTimestamp()});
      } else {
        b.set(ref, {...data, 'createdAt': FieldValue.serverTimestamp()});
      }
    });
  }
  await writeAll(ops);
  await fs.collection('importHistory').add({
    'category': category,
    'duplicatePolicy': duplicatePolicy,
    'imported': toWrite.length,
    'rejected': errors.length,
    'administratorId': actor.uid,
    'administratorName': actor.name,
    'importedAt': FieldValue.serverTimestamp(),
  });
  await audit(actor, 'importTransportData', collectionName, null, {
    'category': category,
    'imported': toWrite.length,
    'rejected': errors.length,
  });
  return {'imported': toWrite.length, 'errors': errors};
}

Future<M> importStudents(M d) async {
  final actor = await need(adminRoles);
  final rows = (d['rows'] as List?) ?? [];
  final dry = d['dryRun'] != false;
  final duplicatePolicy = '${d['duplicatePolicy'] ?? 'skip'}';
  if (!['skip', 'update'].contains(duplicatePolicy)) {
    fail('Duplicate policy must be skip or update.');
  }
  if (rows.isEmpty || rows.length > 5000) {
    fail('Provide between 1 and 5000 rows.');
  }
  final emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$'),
      mobileRe = RegExp(r'^\+?[0-9]{8,15}$');
  final errors = <M>[], valid = <M>[];
  final seenReg = <String>{}, seenMail = <String>{};
  for (var i = 0; i < rows.length; i++) {
    final r = Map<String, dynamic>.from(rows[i] as Map), line = i + 2;
    String t(String k) => '${r[k] ?? ''}'.trim();
    final x = {
      'registerNumber': t('registerNumber'),
      'name': t('name'),
      'departmentId': t('departmentId'),
      'email': t('email').toLowerCase(),
      'mobile': t('mobile'),
      'place': t('place'),
      'boardingPointId': t('boardingPointId'),
      'busId': t('busId'),
      'busNumber': t('busNumber'),
      'routeId': t('routeId'),
      'driverId': t('driverId'),
      'studentStatus': t('studentStatus').isEmpty
          ? (t('status').isEmpty ? 'active' : t('status'))
          : t('studentStatus'),
    };
    void bad(String m) => errors.add({
      'line': line,
      'registerNumber': x['registerNumber'],
      'error': m,
    });
    final year = int.tryParse(t('academicYear'));
    if (x.values.take(4).any((v) => v.isEmpty) || t('academicYear').isEmpty) {
      bad('Missing a required field.');
      continue;
    }
    if (!emailRe.hasMatch(x['email']!)) {
      bad('Invalid email format.');
      continue;
    }
    if (year == null || year < 1 || year > 6) {
      bad('Academic year must be 1 to 6.');
      continue;
    }
    if (x['mobile']!.isNotEmpty && !mobileRe.hasMatch(x['mobile']!)) {
      bad('Invalid mobile number.');
      continue;
    }
    if (!seenReg.add(x['registerNumber']!)) {
      bad('Duplicate register number in file.');
      continue;
    }
    if (!seenMail.add(x['email']!)) {
      bad('Duplicate email in file.');
      continue;
    }
    valid.add({
      ...x,
      'academicYear': year,
      'studentId': safeId(x['registerNumber']!),
      'line': line,
    });
  }

  final points = await fs.collection('boardingPoints').get();
  final buses = await fs.collection('buses').get();
  final routes = await fs.collection('routes').get();
  final drivers = await fs.collection('drivers').get();
  final pointIds = {for (final e in points.docs) e.id};
  final busById = {for (final e in buses.docs) e.id: e.data()};
  final busByNumber = {
    for (final e in buses.docs) '${e.data()['busNumber']}': e.id,
  };
  final routeIds = {for (final e in routes.docs) e.id};
  final driverIds = {for (final e in drivers.docs) e.id};
  final busAssignments = <String, int>{};
  final referenced = <M>[];
  for (final student in valid) {
    final problems = <String>[];
    final pointId = '${student['boardingPointId'] ?? ''}'.trim();
    final busId = '${student['busId'] ?? ''}'.trim();
    final busNumber = '${student['busNumber'] ?? ''}'.trim();
    final resolvedBusId = busId.isNotEmpty
        ? busId
        : (busByNumber[busNumber] ?? '');
    final routeId = '${student['routeId'] ?? ''}'.trim();
    final driverId = '${student['driverId'] ?? ''}'.trim();
    if (pointId.isNotEmpty && !pointIds.contains(pointId)) {
      problems.add('unknown boarding point ID');
    }
    if (resolvedBusId.isNotEmpty && !busById.containsKey(resolvedBusId)) {
      problems.add('unknown bus');
    }
    if (routeId.isNotEmpty && !routeIds.contains(routeId)) {
      problems.add('unknown route ID');
    }
    if (driverId.isNotEmpty && !driverIds.contains(driverId)) {
      problems.add('unknown driver ID');
    }
    if (resolvedBusId.isNotEmpty) {
      final bus = busById[resolvedBusId];
      if (bus != null) {
        final region = bus['permittedRegionId'] as String?;
        if (driverId.isNotEmpty && region != null) {
          final matches = drivers.docs.where((e) => e.id == driverId).toList();
          final driver = matches.isEmpty ? null : matches.first.data();
          if (driver != null &&
              !((driver['permittedRegionIds'] as List?) ?? [])
                  .map((e) => '$e')
                  .contains(region)) {
            problems.add('driver is not eligible for bus region');
          }
        }
        busAssignments[resolvedBusId] =
            (busAssignments[resolvedBusId] ?? 0) + 1;
        student['resolvedBusId'] = resolvedBusId;
      }
    }
    if (problems.isEmpty) {
      referenced.add(student);
    } else {
      errors.add({
        'line': student['line'] ?? '',
        'registerNumber': student['registerNumber'],
        'error': 'Invalid allocation: ${problems.join(', ')}.',
      });
    }
  }

  final capacityFiltered = <M>[];
  for (final student in referenced) {
    final busId = '${student['resolvedBusId'] ?? ''}'.trim();
    if (busId.isEmpty) {
      capacityFiltered.add(student);
      continue;
    }
    final bus = busById[busId];
    final capacity = (bus?['capacity'] as num?)?.toInt();
    final existingAllocated = (bus?['allocated'] as num?)?.toInt() ?? 0;
    final proposed = busAssignments[busId] ?? 0;
    if (capacity == null || capacity < 1) {
      errors.add({
        'registerNumber': student['registerNumber'],
        'error': 'Bus $busId has no valid seating capacity.',
      });
    } else if (existingAllocated + proposed > capacity) {
      errors.add({
        'registerNumber': student['registerNumber'],
        'error':
            'Bus $busId would be over capacity: ${existingAllocated + proposed} assigned for $capacity seats.',
      });
    } else {
      capacityFiltered.add(student);
    }
  }
  valid
    ..clear()
    ..addAll(capacityFiltered);
  final existing = await fs.collection('students').get();
  final ids = {for (final e in existing.docs) e.id},
      mails = {for (final e in existing.docs) '${e.data()['email']}'};
  final fresh = <M>[];
  final updates = <M>[];
  for (final v in valid) {
    if (ids.contains(v['studentId'])) {
      if (duplicatePolicy == 'update') {
        updates.add(v);
      } else {
        errors.add({
          'registerNumber': v['registerNumber'],
          'error': 'Student already registered. Skipped.',
        });
      }
      continue;
    }
    if (mails.contains(v['email'])) {
      if (duplicatePolicy == 'update') {
        errors.add({
          'registerNumber': v['registerNumber'],
          'error': 'Email already used by another student.',
        });
      } else {
        errors.add({
          'registerNumber': v['registerNumber'],
          'error': 'Email already used by another student. Skipped.',
        });
      }
      continue;
    }
    fresh.add(v);
  }
  if (dry) return {'valid': fresh.length + updates.length, 'errors': errors};

  final base = '${(await cfg())['webBaseUrl']}'.replaceAll(RegExp(r'/$'), '');
  final invites = <M>[], ops = <void Function(WriteBatch)>[];
  for (final v in updates) {
    ops.add(
      (b) => b.update(fs.doc('students/${v['studentId']}'), {
        'registerNumber': v['registerNumber'],
        'name': v['name'],
        'departmentId': v['departmentId'],
        'academicYear': v['academicYear'],
        'email': v['email'],
        'mobile': v['mobile'],
        'place': v['place'],
        'boardingPointId': v['boardingPointId'],
        'importBusId': v['resolvedBusId'],
        'importRouteId': v['routeId'],
        'importDriverId': v['driverId'],
        'studentStatus': v['studentStatus'],
        'updatedAt': FieldValue.serverTimestamp(),
      }),
    );
  }
  for (final v in fresh) {
    final token = randomToken(), hash = sha256Hex(token);
    ops.add(
      (b) => b.set(fs.doc('students/${v['studentId']}'), {
        'studentId': v['studentId'],
        'registerNumber': v['registerNumber'],
        'name': v['name'],
        'departmentId': v['departmentId'],
        'academicYear': v['academicYear'],
        'email': v['email'],
        'mobile': v['mobile'],
        'place': v['place'],
        'boardingPointId': v['boardingPointId'],
        'importBusId': v['resolvedBusId'],
        'importRouteId': v['routeId'],
        'importDriverId': v['driverId'],
        'studentStatus': v['studentStatus'],
        'authUid': null,
        'approvedBoardingPointId': null,
        'availableBoardingPointIds': <String>[],
        'registrationStatus': 'invited',
        'allocationId': null,
        'createdAt': FieldValue.serverTimestamp(),
      }),
    );
    ops.add(
      (b) => b.set(fs.doc('invites/$hash'), {
        'inviteId': hash,
        'studentId': v['studentId'],
        'email': v['email'],
        'name': v['name'],
        'registerNumber': v['registerNumber'],
        'departmentId': v['departmentId'],
        'academicYear': v['academicYear'],
        'status': 'pending',
        'expiresAt': Timestamp.fromDate(
          DateTime.now().add(const Duration(days: 14)),
        ),
        'createdAt': FieldValue.serverTimestamp(),
      }),
    );
    invites.add({
      'registerNumber': v['registerNumber'],
      'name': v['name'],
      'email': v['email'],
      'code': token,
      'link': base.isEmpty ? null : '$base/?code=$token',
    });
  }
  await writeAll(ops);
  await fs.collection('importHistory').add({
    'category': 'students',
    'duplicatePolicy': duplicatePolicy,
    'imported': fresh.length + updates.length,
    'rejected': errors.length,
    'administratorId': actor.uid,
    'administratorName': actor.name,
    'importedAt': FieldValue.serverTimestamp(),
  });
  await audit(actor, 'importStudents', 'students', null, {
    'imported': fresh.length,
    'rejected': errors.length,
  });
  return {'imported': fresh.length, 'errors': errors, 'invites': invites};
}

Future<M> reissueInvite(M d) async {
  final actor = await need(adminRoles);
  final sRef = fs.doc('students/${d['studentId']}'),
      s = (await sRef.get()).data();
  if (s == null) fail('Student not found.');
  if (s['authUid'] != null) fail('This student has already registered.');
  final old = await fs
      .collection('invites')
      .where('studentId', isEqualTo: sRef.id)
      .where('status', isEqualTo: 'pending')
      .get();
  final token = randomToken(), hash = sha256Hex(token);
  final ops = <void Function(WriteBatch)>[
    for (final o in old.docs)
      (b) => b.update(o.reference, {'status': 'revoked'}),
    (b) => b.set(fs.doc('invites/$hash'), {
      'inviteId': hash,
      'studentId': sRef.id,
      'email': s['email'],
      'name': s['name'],
      'registerNumber': s['registerNumber'],
      'departmentId': s['departmentId'],
      'academicYear': s['academicYear'],
      'status': 'pending',
      'expiresAt': Timestamp.fromDate(
        DateTime.now().add(const Duration(days: 14)),
      ),
      'createdAt': FieldValue.serverTimestamp(),
    }),
  ];
  await writeAll(ops);
  final base = '${(await cfg())['webBaseUrl']}'.replaceAll(RegExp(r'/$'), '');
  await audit(actor, 'reissueInvite', 'students/${sRef.id}');
  return {
    'code': token,
    'email': s['email'],
    'link': base.isEmpty ? null : '$base/?code=$token',
  };
}

/// Anyone holding the token can read its invite (the document id is a hash of the token, so it cannot be guessed).
Future<M> _readInvite(String token) async {
  if (token.length < 20) fail('Invalid or expired invitation.');
  final i = (await fs.doc('invites/${sha256Hex(token)}').get()).data();
  final exp = (i?['expiresAt'] as Timestamp?)?.toDate();
  if (i == null ||
      i['status'] != 'pending' ||
      exp == null ||
      exp.isBefore(DateTime.now())) {
    fail('Invalid or expired invitation.');
  }
  return i;
}

Future<M> previewInvite(M d) async {
  final i = await _readInvite('${d['token'] ?? ''}');
  return {
    'name': i['name'],
    'registerNumber': i['registerNumber'],
    'departmentId': i['departmentId'],
    'academicYear': i['academicYear'],
    'email': i['email'],
  };
}

Future<M> redeemInvite(M d) async {
  final token = '${d['token'] ?? ''}', password = '${d['password'] ?? ''}';
  if (password.length < 8) fail('Password must be at least 8 characters.');
  final i = await _readInvite(token), hash = sha256Hex(token);
  UserCredential cred;
  try {
    cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
      email: '${i['email']}',
      password: password,
    );
  } on FirebaseAuthException catch (e) {
    fail(
      e.code == 'email-already-in-use'
          ? 'An account with this email already exists. Sign in, or use Forgot password.'
          : (e.message ?? 'Could not create your account.'),
    );
  }
  final uid = cred.user!.uid;
  try {
    final studentRef = fs.doc('students/${i['studentId']}');
    final student = (await studentRef.get()).data();
    final b = fs.batch();
    b.set(fs.doc('users/$uid'), {
      'role': 'student',
      'name': i['name'],
      'email': i['email'],
      'status': 'active',
      'studentId': i['studentId'],
      'inviteId': hash,
      'createdAt': FieldValue.serverTimestamp(),
    });
    b.update(fs.doc('invites/$hash'), {
      'status': 'used',
      'usedAt': FieldValue.serverTimestamp(),
      'usedBy': uid,
    });
    final studentPatch = <String, dynamic>{
      'authUid': uid,
      'registrationStatus': 'registered',
      'registeredAt': FieldValue.serverTimestamp(),
    };
    if (student == null || !student.containsKey('availableBoardingPointIds')) {
      studentPatch['availableBoardingPointIds'] = <String>[];
    }
    b.update(studentRef, studentPatch);
    await b.commit();
  } catch (_) {
    await cred.user?.delete(); // do not leave a half-made account behind
    fail(
      'Could not finish registration. The invitation may already have been used.',
    );
  }
  return {'email': i['email']};
}

Future<M> updateStudent(M d) async {
  final actor = await need(adminRoles);
  final ref = fs.doc('students/${d['studentId']}'),
      old = (await ref.get()).data();
  if (old == null) fail('Student not found.');
  final patch = <String, dynamic>{};
  if (d['name'] != null) {
    final n = '${d['name']}'.trim();
    if (n.isEmpty) fail('Name is required.');
    patch['name'] = n;
  }
  if (d['departmentId'] != null) {
    final n = '${d['departmentId']}'.trim();
    if (n.isEmpty) fail('Department is required.');
    patch['departmentId'] = n;
  }
  if (d['academicYear'] != null) {
    final y = int.tryParse('${d['academicYear']}');
    if (y == null || y < 1 || y > 6) fail('Academic year must be 1 to 6.');
    patch['academicYear'] = y;
  }
  if (d['mobile'] != null) {
    final m = '${d['mobile']}'.trim();
    if (m.isNotEmpty && !RegExp(r'^\+?[0-9]{8,15}$').hasMatch(m)) {
      fail('Invalid mobile number.');
    }
    patch['mobile'] = m;
  }
  if (patch.isEmpty) fail('Nothing to change.');
  await ref.update(patch);
  await audit(actor, 'updateStudent', 'students/${ref.id}', {
    for (final k in patch.keys) k: old[k],
  }, patch);
  return {'ok': true};
}

Future<M> removeStudent(M d) async {
  final actor = await need(adminRoles);
  final ref = fs.doc('students/${d['studentId']}'),
      s = (await ref.get()).data();
  if (s == null) fail('Student not found.');
  if (s['authUid'] != null) {
    fail('Only students who have not registered yet can be removed.');
  }
  final inv = await fs
      .collection('invites')
      .where('studentId', isEqualTo: ref.id)
      .get();
  await writeAll([
    for (final i in inv.docs) (b) => b.delete(i.reference),
    (b) => b.delete(ref),
  ]);
  await audit(actor, 'removeStudent', 'students/${ref.id}', {
    'name': s['name'],
    'registerNumber': s['registerNumber'],
  });
  return {'ok': true};
}

Future<M> createDriver(M d) async {
  final actor = await need(adminRoles);
  final email = '${d['email'] ?? ''}'.trim().toLowerCase(),
      name = '${d['name'] ?? ''}'.trim(),
      password = '${d['password'] ?? ''}';
  if (email.isEmpty || name.isEmpty || password.length < 8) {
    fail('Name, email and a password of at least 8 characters are required.');
  }
  final uid = await createAuthAccount(email, password);
  await writeAll([
    (b) => b.set(fs.doc('users/$uid'), {
      'role': 'driver',
      'name': name,
      'email': email,
      'status': 'active',
      'busId': null,
      'createdAt': FieldValue.serverTimestamp(),
    }),
    (b) => b.set(fs.doc('drivers/$uid'), {
      'driverId': uid,
      'authUid': uid,
      'name': name,
      'email': email,
      'contact': '${d['contact'] ?? ''}',
      'permittedRegionIds': d['permittedRegionIds'] ?? [],
      'assignedBusId': null,
      'status': 'active',
      'createdAt': FieldValue.serverTimestamp(),
    }),
  ]);
  await audit(actor, 'createDriver', 'drivers/$uid', null, {
    'name': name,
    'email': email,
  });
  return {'driverId': uid};
}

Future<M> createStaff(M d) async {
  final actor = await need(['superAdmin']);
  final email = '${d['email'] ?? ''}'.trim().toLowerCase(),
      name = '${d['name'] ?? ''}'.trim(),
      role = '${d['role']}';
  if (!['superAdmin', 'routeAdmin'].contains(role) ||
      email.isEmpty ||
      name.isEmpty) {
    fail('Name, email and role are required.');
  }
  final uid = await createAuthAccount(email, randomToken(18));
  await fs.doc('users/$uid').set({
    'role': role,
    'name': name,
    'email': email,
    'status': 'active',
    'createdAt': FieldValue.serverTimestamp(),
  });
  await Mirror.apply(
    Mirror.admin(uid, role == 'superAdmin' ? 'super' : 'route'),
  );
  await FirebaseAuth.instance.sendPasswordResetEmail(
    email: email,
  ); // they choose their own password
  await audit(actor, 'createStaff', 'users/$uid', null, {
    'email': email,
    'role': role,
  });
  return {'uid': uid, 'emailSent': true};
}

Future<M> setAccountDisabled(M d) async {
  final actor = await need(['superAdmin']);
  final uid = '${d['uid']}', disabled = d['disabled'] == true;
  if (uid == actor.uid) fail('You cannot disable your own account.');
  final ref = fs.doc('users/$uid'), u = (await ref.get()).data();
  if (u == null) fail('Account not found.');
  await ref.update({'status': disabled ? 'disabled' : 'active'});
  final role = '${u['role']}', m = <String, Object?>{};
  if (role == 'superAdmin' || role == 'routeAdmin') {
    m.addAll(
      Mirror.admin(
        uid,
        disabled ? null : (role == 'superAdmin' ? 'super' : 'route'),
      ),
    );
  }
  if ((role == 'driver' || role == 'device') && u['busId'] != null) {
    m.addAll(Mirror.writer('${u['busId']}', uid, !disabled));
  }
  if (role == 'student' && u['studentId'] != null) {
    final s = (await fs.doc('students/${u['studentId']}').get()).data();
    final a = s?['allocationId'] == null
        ? null
        : (await fs.doc('allocations/${s!['allocationId']}').get()).data();
    if (a != null && a['status'] == 'active') {
      m.addAll(Mirror.rider('${a['busId']}', uid, !disabled));
    }
  }
  if (m.isNotEmpty) await Mirror.apply(m);
  if (role == 'driver') {
    final dr = fs.doc('drivers/$uid');
    if ((await dr.get()).exists) {
      await dr.update({'status': disabled ? 'disabled' : 'active'});
    }
  }
  await audit(
    actor,
    disabled ? 'disableAccount' : 'enableAccount',
    'users/$uid',
  );
  return {'ok': true};
}

// ---------------- Student boarding-point permissions ----------------
Future<M> assignStudentBoardingPoints(M d) async {
  final actor = await need(adminRoles);

  final studentId = '${d['studentId'] ?? ''}'.trim();
  final pointIds =
      (d['boardingPointIds'] as List?)?.map((e) => '$e').toSet().toList() ?? [];

  if (studentId.isEmpty) fail('Student ID is required.');

  final sRef = fs.doc('students/$studentId');
  final s = (await sRef.get()).data();

  if (s == null) fail('Student not found.');

  for (final id in pointIds) {
    if (id.isEmpty) fail('A boarding-point ID is invalid.');
    final p = (await fs.doc('boardingPoints/$id').get()).data();

    if (p == null || p['approvalStatus'] != 'approved') {
      fail('Invalid or unapproved boarding point: $id');
    }
  }

  final currentStop = s['approvedBoardingPointId'];
  if (s['allocationId'] != null) {
    final allocation = await fs.doc('allocations/${s['allocationId']}').get();
    final active =
        allocation.exists && allocation.data()?['status'] == 'active';
    if (active && currentStop != null && !pointIds.contains('$currentStop')) {
      fail(
        'The student has an active bus allocation. Keep their current stop assigned until the Route Admin explicitly reallocates them.',
      );
    }
  }

  await sRef.update({'availableBoardingPointIds': pointIds});

  await audit(
    actor,
    'assignStudentBoardingPoints',
    'students/$studentId',
    s['availableBoardingPointIds'],
    pointIds,
  );

  return {'ok': true, 'assignedCount': pointIds.length};
}

// ---------------- Dedicated GPS trackers: each signs in with its own account ----------------
Future<M> registerDevice(M d) async {
  final actor = await need(adminRoles);
  final busId = '${d['busId'] ?? ''}', deviceId = '${d['deviceId'] ?? ''}';
  if (!RegExp(r'^[A-Za-z0-9_-]{4,40}$').hasMatch(deviceId)) {
    fail('Device ID must be 4 to 40 letters, numbers, - or _.');
  }
  final busRef = fs.doc('buses/$busId'), bus = (await busRef.get()).data();
  if (bus == null) fail('Bus not found.');
  final devRef = fs.doc('devices/$deviceId'), old = (await devRef.get()).data();
  if (old != null && old['status'] == 'active' && old['busId'] != busId) {
    fail(
      'This device is already linked to bus ${old['busId']}. Revoke it first.',
    );
  }
  final m = <String, Object?>{};
  if (old != null && old['status'] == 'active') {
    // replacing the key: retire the old account
    await fs.doc('users/${old['uid']}').update({'status': 'disabled'});
    m.addAll(Mirror.writer('${old['busId']}', '${old['uid']}', false));
  }
  final email =
      '${deviceId.toLowerCase()}-${randomToken(4).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), 'x')}@devices.routesync.app';
  final password = randomToken(18);
  final uid = await createAuthAccount(email, password);
  await writeAll([
    (b) => b.set(fs.doc('users/$uid'), {
      'role': 'device',
      'name': 'GPS device $deviceId',
      'email': email,
      'status': 'active',
      'busId': busId,
      'createdAt': FieldValue.serverTimestamp(),
    }),
    (b) => b.set(devRef, {
      'deviceId': deviceId,
      'busId': busId,
      'uid': uid,
      'email': email,
      'status': 'active',
      'createdAt': FieldValue.serverTimestamp(),
    }),
    (b) => b.update(busRef, {'gpsDeviceId': deviceId}),
  ]);
  m.addAll(Mirror.writer(busId, uid, true));
  await Mirror.apply(m);
  await audit(actor, 'registerDevice', 'devices/$deviceId', null, {
    'busId': busId,
  });
  final o = Firebase.app().options;
  return {
    'deviceId': deviceId,
    'busId': busId,
    'email': email,
    'password': password,
    'apiKey': o.apiKey,
    'databaseUrl': o.databaseURL ?? '',
    'projectId': o.projectId,
  };
}

Future<M> revokeDevice(M d) async {
  final actor = await need(adminRoles);
  final ref = fs.doc('devices/${d['deviceId']}'), v = (await ref.get()).data();
  if (v == null) fail('Device not found.');
  await ref.update({'status': 'revoked'});
  await fs.doc('users/${v['uid']}').update({'status': 'disabled'});
  await Mirror.apply(Mirror.writer('${v['busId']}', '${v['uid']}', false));
  final busRef = fs.doc('buses/${v['busId']}');
  if ((await busRef.get()).data()?['gpsDeviceId'] == v['deviceId']) {
    await busRef.update({'gpsDeviceId': null});
  }
  await audit(actor, 'revokeDevice', 'devices/${v['deviceId']}');
  return {'ok': true};
}
