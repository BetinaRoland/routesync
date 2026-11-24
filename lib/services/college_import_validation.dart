typedef ImportMap = Map<String, dynamic>;

String stableImportId(String value) =>
    value.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

class CollegeImportPreview {
  final List<ImportMap> busesToWrite;
  final List<ImportMap> studentsToWrite;
  final List<ImportMap> allocationsToCreate;
  final List<ImportMap> errors;
  final List<ImportMap> notAllocated;

  const CollegeImportPreview({
    required this.busesToWrite,
    required this.studentsToWrite,
    required this.allocationsToCreate,
    required this.errors,
    required this.notAllocated,
  });
}

CollegeImportPreview validateCollegeImport({
  required List<ImportMap> busRows,
  required List<ImportMap> studentRows,
  required Map<String, ImportMap> existingBuses,
  required Map<String, ImportMap> existingStudents,
  required Map<String, ImportMap> authenticatedUsers,
  required Map<String, ImportMap> routes,
  required Map<String, ImportMap> boardingPoints,
  required Map<String, ImportMap> drivers,
  required Map<String, int> activeAllocationCounts,
  required String duplicatePolicy,
}) {
  final errors = <ImportMap>[];
  final busesToWrite = <ImportMap>[];
  final effectiveBuses = <String, ImportMap>{
    for (final entry in existingBuses.entries)
      entry.key: {'busId': entry.key, ...entry.value},
  };
  final busNumbers = <String, String>{};
  final seenDriverIds = <String, String>{};
  for (final entry in existingBuses.entries) {
    final number = '${entry.value['busNumber'] ?? ''}'.trim();
    if (number.isNotEmpty) busNumbers[number] = entry.key;
  }
  final seenBusIds = <String>{};

  for (var index = 0; index < busRows.length; index++) {
    final row = busRows[index];
    final line = index + 2;
    String text(String key) => '${row[key] ?? ''}'.trim();
    final number = text('busNumber');
    final id = text('busId').isEmpty ? stableImportId(number) : text('busId');
    final capacity = int.tryParse(text('capacity'));
    void issue(String message) => errors.add({
      'category': 'bus',
      'line': line,
      'id': id,
      'error': message,
    });

    if (number.isEmpty || id.isEmpty) {
      issue('Bus number is required to identify the bus.');
      continue;
    }
    if (number.length > 80 ||
        id.length > 128 ||
        id.contains('/') ||
        id == '.' ||
        id == '..') {
      issue('Bus number or ID has an invalid length or document-ID format.');
      continue;
    }
    if (!seenBusIds.add(id)) {
      issue('Duplicate bus ID in CSV.');
      continue;
    }
    if (capacity == null || capacity < 1 || capacity > 120) {
      issue('Seating capacity must be between 1 and 120.');
      continue;
    }
    final existing = existingBuses[id];
    if (existing != null && duplicatePolicy == 'skip') {
      errors.add({
        'category': 'bus',
        'line': line,
        'id': id,
        'error': 'Existing bus skipped; existing data is preserved.',
      });
      continue;
    }
    final numberOwner = busNumbers[number];
    if (numberOwner != null && numberOwner != id) {
      issue('Bus number is already used by bus ID $numberOwner.');
      continue;
    }
    final routeId = text('routeId');
    if (routeId.isNotEmpty && !routes.containsKey(routeId)) {
      issue('Route ID "$routeId" does not exist.');
      continue;
    }
    final effectiveRoute = routeId.isEmpty
        ? '${existing?['routeId'] ?? ''}'
        : routeId;
    if (effectiveRoute.isEmpty) {
      errors.add({
        'category': 'bus',
        'line': line,
        'id': id,
        'warning': true,
        'error': 'No route ID supplied; the bus cannot receive allocations until linked.',
      });
    }
    final driverId = text('driverId');
    if (driverId.isNotEmpty && !drivers.containsKey(driverId)) {
      issue('Driver ID "$driverId" does not exist.');
      continue;
    }
    if (driverId.isNotEmpty) {
      final driver = drivers[driverId]!;
      if (driver['status'] != 'active') {
        issue('Driver "$driverId" is not active.');
        continue;
      }
      final assignedBusId = driver['assignedBusId'];
      if (assignedBusId != null && assignedBusId != id) {
        issue('Driver "$driverId" is already assigned to another bus.');
        continue;
      }
      final region = text('permittedRegionId').isEmpty
          ? (existing == null ? null : existing['permittedRegionId'])
          : text('permittedRegionId');
      if (region != null &&
          !((driver['permittedRegionIds'] as List?) ?? const [])
              .map((value) => '$value')
              .contains('$region')) {
        issue('Driver "$driverId" is not permitted in this bus region.');
        continue;
      }
      final previousBus = seenDriverIds[driverId];
      if (previousBus != null && previousBus != id) {
        issue('Driver "$driverId" is assigned to multiple buses in this CSV.');
        continue;
      }
      seenDriverIds[driverId] = id;
    } else if ('${existing?['driverId'] ?? ''}'.isEmpty) {
      errors.add({
        'category': 'bus',
        'line': line,
        'id': id,
        'warning': true,
        'error': 'No driver assignment supplied; the bus cannot receive allocations until assigned.',
      });
    }
    final active = activeAllocationCounts[id] ?? 0;
    if (capacity < active) {
      issue('$active existing active allocations exceed this capacity.');
      continue;
    }
    final effectiveRouteId = routeId.isEmpty
        ? '${existing?['routeId'] ?? ''}'
        : routeId;
    if (existing != null &&
        active > 0 &&
        effectiveRouteId != '${existing['routeId'] ?? ''}') {
      issue('Route cannot change while the bus has active allocations.');
      continue;
    }

    final status = text('status').toLowerCase();
    if (status.isNotEmpty &&
        !['active', 'inactive', 'available', 'unavailable'].contains(status)) {
      issue('Bus status must be active, inactive, available, or unavailable.');
      continue;
    }
    final isAvailable =
        status != 'inactive' && status != 'unavailable';
    final data = <String, dynamic>{
      'busId': id,
      'busNumber': number,
      'capacity': capacity,
      if (text('registrationNumber').isNotEmpty)
        'registrationNumber': text('registrationNumber'),
      if (routeId.isNotEmpty) 'routeId': routeId,
      if (driverId.isNotEmpty) 'driverId': driverId,
      if (text('permittedRegionId').isNotEmpty)
        'permittedRegionId': text('permittedRegionId'),
      if (status.isNotEmpty) 'availability': isAvailable,
      if (existing == null) ...{
        'availability': isAvailable,
        'maintenanceStatus': 'ok',
        'driverId': driverId.isEmpty ? null : driverId,
        'routeId': routeId.isEmpty ? null : routeId,
        'allocated': 0,
      },
    };
    busesToWrite.add({
      'id': id,
      'line': line,
      'existing': existing != null,
      'data': data,
    });
    effectiveBuses[id] = {
      ...?existing,
      ...data,
      if (driverId.isNotEmpty &&
          drivers[driverId]?['assignedBusId'] == null)
        'driverAssignmentPending': true,
    };
    busNumbers[number] = id;
  }

  final studentsToWrite = <ImportMap>[];
  final studentsForAllocation = <ImportMap>[];
  final seenStudentIds = <String>{};
  final seenEmails = <String>{};
  for (var index = 0; index < studentRows.length; index++) {
    final row = studentRows[index];
    final line = index + 2;
    String text(String key) => '${row[key] ?? ''}'.trim();
    final registerNumber = text('registerNumber');
    final id = stableImportId(registerNumber);
    final name = text('name');
    final department = text('departmentId');
    final email = text('email').toLowerCase();
    final mobile = text('mobile');
    final year = int.tryParse(text('academicYear'));
    void issue(String message) => errors.add({
      'category': 'student',
      'line': line,
      'id': id,
      'registerNumber': registerNumber,
      'error': message,
    });

    if (registerNumber.isEmpty ||
        name.isEmpty ||
        department.isEmpty ||
        email.isEmpty ||
        text('academicYear').isEmpty) {
      issue('Required roster fields are missing.');
      continue;
    }
    if (registerNumber.length > 128 ||
        name.length > 120 ||
        department.length > 120 ||
        email.length > 254) {
      issue('Register number, name, department, or email is too long.');
      continue;
    }
    if (id.isEmpty) {
      issue('Register number cannot form a valid student ID.');
      continue;
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      issue('Email address is invalid.');
      continue;
    }
    if (year == null || year < 1 || year > 6) {
      issue('Academic year must be from 1 to 6.');
      continue;
    }
    if (mobile.isNotEmpty && !RegExp(r'^\+?[0-9]{8,15}$').hasMatch(mobile)) {
      issue('Mobile number is invalid.');
      continue;
    }
    if (!seenStudentIds.add(id)) {
      issue('Duplicate student ID in CSV.');
      continue;
    }
    if (!seenEmails.add(email)) {
      issue('Duplicate email address in CSV.');
      continue;
    }
    final old = existingStudents[id];
    if (old != null && duplicatePolicy == 'skip') {
      errors.add({
        'category': 'student',
        'line': line,
        'id': id,
        'registerNumber': registerNumber,
        'error': 'Existing student skipped; existing data and allocation are preserved.',
      });
      continue;
    }
    String? oldEmailOwner;
    for (final entry in existingStudents.entries) {
      if (entry.key != id &&
          '${entry.value['email'] ?? ''}'.toLowerCase() == email) {
        oldEmailOwner = entry.key;
        break;
      }
    }
    if (oldEmailOwner != null) {
      issue('Email address is already used by student $oldEmailOwner.');
      continue;
    }
    final student = <String, dynamic>{
      'studentId': id,
      'registerNumber': registerNumber,
      'name': name,
      'departmentId': department,
      'academicYear': year,
      'email': email,
      if (mobile.isNotEmpty) 'mobile': mobile,
      if (text('place').isNotEmpty) 'place': text('place'),
      if (text('busId').isNotEmpty) 'importBusId': text('busId'),
      if (text('busNumber').isNotEmpty) 'importBusNumber': text('busNumber'),
      if (text('boardingPointId').isNotEmpty)
        'importBoardingPointId': text('boardingPointId'),
    };
    studentsToWrite.add({
      'id': id,
      'line': line,
      'existing': old != null,
      'data': student,
    });

    final allocationReasons = <String>[];
    final oldAllocationId = old?['allocationId'];
    if (oldAllocationId != null) {
      studentsForAllocation.add({
        'studentId': id,
        'registerNumber': registerNumber,
        'line': line,
        'busId': old?['busId'],
        'allocationId': oldAllocationId,
        'reason': 'Existing allocation preserved.',
        'alreadyAllocated': true,
      });
      continue;
    }
    final authUid = old?['authUid'];
    if (authUid == null || '$authUid'.isEmpty) {
      allocationReasons.add('Student has no existing authenticated account.');
    } else {
      final user = authenticatedUsers['$authUid'];
      if (user == null ||
          user['status'] != 'active' ||
          user['role'] != 'student' ||
          user['studentId'] != id) {
        allocationReasons.add(
          'Student has no matching active authenticated account.',
        );
      }
    }
    final requestedBusId = text('busId');
    final requestedBusNumber = text('busNumber');
    String? resolvedBusId;
    if (requestedBusId.isNotEmpty) {
      if (effectiveBuses.containsKey(requestedBusId)) {
        resolvedBusId = requestedBusId;
      } else {
        allocationReasons.add('Bus ID "$requestedBusId" does not exist.');
      }
    } else if (requestedBusNumber.isNotEmpty) {
      final matches = effectiveBuses.entries
          .where(
            (entry) =>
                '${entry.value['busNumber'] ?? ''}'.trim() ==
                requestedBusNumber,
          )
          .toList();
      if (matches.length == 1) {
        resolvedBusId = matches.single.key;
      } else if (matches.isEmpty) {
        allocationReasons.add(
          'Bus number "$requestedBusNumber" does not exist.',
        );
      } else {
        allocationReasons.add(
          'Bus number "$requestedBusNumber" is ambiguous; use bus ID.',
        );
      }
    } else {
      allocationReasons.add('No bus was specified in the CSV.');
    }
    final bus = resolvedBusId == null
        ? null
        : effectiveBuses[resolvedBusId];
    if (bus != null &&
        requestedBusId.isNotEmpty &&
        requestedBusNumber.isNotEmpty &&
        '${bus['busNumber'] ?? ''}'.trim() != requestedBusNumber) {
      allocationReasons.add('Bus ID and bus number refer to different buses.');
    }
    String? pointId = text('boardingPointId');
    final oldApprovedPointId = old?['approvedBoardingPointId'];
    if (pointId.isNotEmpty &&
        oldApprovedPointId is String &&
        oldApprovedPointId.isNotEmpty &&
        pointId != oldApprovedPointId) {
      allocationReasons.add(
        'CSV boarding point does not match the student\'s existing approved boarding point.',
      );
    }
    if (pointId.isEmpty) {
      final existingPoint = oldApprovedPointId;
      if (existingPoint is String && existingPoint.isNotEmpty) {
        pointId = existingPoint;
      }
    }
    if (pointId.isEmpty) {
      allocationReasons.add('No boarding-point ID was provided or approved.');
    } else {
      final point = boardingPoints[pointId];
      if (point == null) {
        allocationReasons.add('Boarding-point ID "$pointId" does not exist.');
      } else if (point['status'] == 'inactive' ||
          point['approvalStatus'] != 'approved') {
        allocationReasons.add('Boarding point "$pointId" is not active and approved.');
      }
    }
    final busRouteId = '${bus?['routeId'] ?? ''}'.trim();
    final requestedRouteId = text('routeId');
    final routeId = busRouteId.isNotEmpty ? busRouteId : null;
    if (requestedRouteId.isNotEmpty && busRouteId.isEmpty) {
      allocationReasons.add('Selected bus has no route assignment.');
    }
    if (requestedRouteId.isNotEmpty &&
        busRouteId.isNotEmpty &&
        requestedRouteId != busRouteId) {
      allocationReasons.add('Student route ID does not match the selected bus route.');
    }
    final route = routeId == null ? null : routes[routeId];
    if (routeId == null) {
      allocationReasons.add('The selected bus has no route ID.');
    } else if (route == null) {
      allocationReasons.add('Route ID "$routeId" does not exist.');
    } else if (route['status'] != null && route['status'] != 'active') {
      allocationReasons.add('Selected route is not active.');
    } else if (!((route['stopIds'] as List?) ?? const []).contains(pointId)) {
      allocationReasons.add('The selected route does not serve boarding point "$pointId".');
    }
    final busDriverId = '${bus?['driverId'] ?? ''}'.trim();
    final requestedDriverId = text('driverId');
    final driverId = busDriverId.isNotEmpty ? busDriverId : null;
    if (requestedDriverId.isNotEmpty && busDriverId.isEmpty) {
      allocationReasons.add('Selected bus has no driver assignment.');
    }
    if (requestedDriverId.isNotEmpty &&
        busDriverId.isNotEmpty &&
        requestedDriverId != busDriverId) {
      allocationReasons.add('Student driver ID does not match the selected bus driver.');
    }
    final driver = driverId == null ? null : drivers[driverId];
    if (driverId == null) {
      allocationReasons.add('The selected bus has no driver assignment.');
    } else if (driver == null) {
      allocationReasons.add('Driver ID "$driverId" does not exist.');
    } else {
      if (driver['status'] != 'active') {
        allocationReasons.add('Assigned driver is not active.');
      }
      final assignedBusId = driver['assignedBusId'];
      if (assignedBusId != null && assignedBusId != resolvedBusId) {
        allocationReasons.add('Assigned driver is assigned to another bus.');
      }
      if (assignedBusId == null &&
          bus?['driverAssignmentPending'] != true) {
        allocationReasons.add('Assigned driver is not assigned to this bus.');
      }
      final region = bus?['permittedRegionId'];
      if (region != null &&
          !((driver['permittedRegionIds'] as List?) ?? const [])
              .map((e) => '$e')
              .contains('$region')) {
        allocationReasons.add('Assigned driver is not permitted in the bus region.');
      }
    }
    if (bus == null) {
      if (resolvedBusId != null) {
        allocationReasons.add('Bus could not be resolved.');
      }
    } else {
      if (bus['availability'] == false ||
          (bus['status'] != null && bus['status'] != 'active') ||
          (bus['maintenanceStatus'] != null &&
              bus['maintenanceStatus'] != 'ok')) {
        allocationReasons.add('Selected bus is unavailable.');
      }
      final capacity = (bus['capacity'] as num?)?.toInt();
      if (capacity == null || capacity < 1) {
        allocationReasons.add('Selected bus has no valid seating capacity.');
      }
    }
    if (allocationReasons.isEmpty && bus != null && resolvedBusId != null) {
      studentsForAllocation.add({
        'studentId': id,
        'registerNumber': registerNumber,
        'line': line,
        'authUid': authUid,
        'busId': resolvedBusId,
        'routeId': routeId,
        'driverId': driverId,
        'boardingPointId': pointId,
        'academicYear': year,
      });
    } else {
      studentsForAllocation.add({
        'studentId': id,
        'registerNumber': registerNumber,
        'line': line,
        'busId': resolvedBusId,
        'reason': allocationReasons.join(' '),
      });
    }
  }

  final proposedByBus = <String, List<ImportMap>>{};
  for (final student in studentsForAllocation) {
    if (student['alreadyAllocated'] == true) continue;
    final reason = '${student['reason'] ?? ''}';
    final busId = '${student['busId'] ?? ''}';
    if (reason.isEmpty && busId.isNotEmpty) {
      (proposedByBus[busId] ??= []).add(student);
    }
  }
  final allocationsToCreate = <ImportMap>[];
  final notAllocated = <ImportMap>[];
  for (final student in studentsForAllocation) {
    if (student['alreadyAllocated'] == true) continue;
    final reason = '${student['reason'] ?? ''}';
    final busId = '${student['busId'] ?? ''}';
    if (reason.isNotEmpty || busId.isEmpty) {
      notAllocated.add({
        ...student,
        'allocationStatus': 'Not Allocated',
        'reason': reason.isEmpty ? 'No valid bus assignment.' : reason,
      });
      continue;
    }
    final bus = effectiveBuses[busId]!;
    final capacity = (bus['capacity'] as num).toInt();
    final occupied = activeAllocationCounts[busId] ?? 0;
    final proposed = proposedByBus[busId]!.length;
    if (occupied + proposed > capacity) {
      final error =
          'Bus ${bus['busNumber'] ?? busId} would have ${occupied + proposed} students for $capacity seats; no new students assigned to this bus.';
      notAllocated.add({
        ...student,
        'allocationStatus': 'Not Allocated',
        'reason': error,
      });
      errors.add({
        'category': 'capacity',
        'line': student['line'],
        'id': student['studentId'],
        'error': error,
      });
      continue;
    }
    allocationsToCreate.add(student);
  }

  return CollegeImportPreview(
    busesToWrite: busesToWrite,
    studentsToWrite: studentsToWrite,
    allocationsToCreate: allocationsToCreate,
    errors: errors,
    notAllocated: notAllocated,
  );
}
