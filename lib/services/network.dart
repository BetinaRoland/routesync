import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'common.dart';
import '../core/logic.dart' show haversineM;

int _int(Object? v) => v is num ? v.toInt() : (int.tryParse('$v') ?? 0);

const defaultBoardingPointDuplicateDistanceMeters = 150;
DateTime? _lastPlaceRequest;

String _firstText(Iterable<Object?> values) {
  for (final value in values) {
    final text = '$value'.trim();
    if (text.isNotEmpty && text.toLowerCase() != 'null') return text;
  }
  return '';
}

M boardingPointPlace(Map<String, dynamic> raw, {required String fallback}) {
  final address = raw['address'] is Map
      ? Map<String, dynamic>.from(raw['address'] as Map)
      : <String, dynamic>{};
  final named = raw['namedetails'] is Map
      ? Map<String, dynamic>.from(raw['namedetails'] as Map)
      : <String, dynamic>{};
  final name = _firstText([
    raw['name'],
    named['name'],
    address['amenity'],
    address['public_transport'],
    address['station'],
    address['leisure'],
    address['shop'],
    address['tourism'],
    address['building'],
    address['road'],
    address['suburb'],
    address['town'],
    address['city'],
  ]);
  return {
    'name': name.isEmpty ? fallback : name,
    'address': '${raw['display_name'] ?? ''}'.trim(),
    'district': _firstText([
      address['state_district'],
      address['district'],
      address['county'],
      address['city'],
      address['town'],
    ]),
  };
}

double boardingPointDistanceMeters(
  double latitude,
  double longitude,
  double otherLatitude,
  double otherLongitude,
) => haversineM(latitude, longitude, otherLatitude, otherLongitude);

Future<void> _waitForPlaceRequestSlot() async {
  final last = _lastPlaceRequest;
  if (last != null) {
    final wait =
        const Duration(milliseconds: 1100) - DateTime.now().difference(last);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }
  _lastPlaceRequest = DateTime.now();
}

Future<dynamic> _nominatim(Uri uri) async {
  await _waitForPlaceRequestSlot();
  try {
    final response = await http
        .get(
          uri,
          headers: const {
            'Accept': 'application/json',
            'Accept-Language': 'en',
            'User-Agent': 'RouteSync/1.0 (college transport app)',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      fail('Location search is temporarily unavailable. Please try again.');
    }
    return jsonDecode(response.body);
  } on Fail {
    rethrow;
  } catch (_) {
    fail(
      'Could not reach the location service. Check your internet and retry.',
    );
  }
}

Future<M> searchBoardingPlaces(M d) async {
  await need(adminRoles);
  final query = '${d['query'] ?? ''}'.trim();
  if (query.length < 3) fail('Enter at least 3 letters to search.');
  final result = await _nominatim(
    Uri.https('nominatim.openstreetmap.org', '/search', {
      'format': 'jsonv2',
      'addressdetails': '1',
      'namedetails': '1',
      'limit': '6',
      'q': query,
    }),
  );
  if (result is! List) {
    fail('The location service returned an unexpected result.');
  }
  return {
    'places': [
      for (final item in result)
        if (item is Map) _parseSearchPlace(Map<String, dynamic>.from(item)),
    ],
  };
}

M _parseSearchPlace(Map<String, dynamic> raw) {
  final place = boardingPointPlace(raw, fallback: '');
  return {
    ...place,
    'latitude': double.tryParse('${raw['lat']}'),
    'longitude': double.tryParse('${raw['lon']}'),
  };
}

Future<M> reverseGeocodeBoardingPoint(M d) async {
  await need(adminRoles);
  final lat = d['latitude'], lng = d['longitude'];
  if (lat is! num ||
      lng is! num ||
      !lat.isFinite ||
      !lng.isFinite ||
      lat < -90 ||
      lat > 90 ||
      lng < -180 ||
      lng > 180) {
    fail('Choose a valid point on the map.');
  }
  final result = await _nominatim(
    Uri.https('nominatim.openstreetmap.org', '/reverse', {
      'format': 'jsonv2',
      'addressdetails': '1',
      'namedetails': '1',
      'zoom': '18',
      'lat': '${lat.toDouble()}',
      'lon': '${lng.toDouble()}',
    }),
  );
  if (result is! Map) {
    return {'name': '', 'address': '', 'district': ''};
  }
  return boardingPointPlace(Map<String, dynamic>.from(result), fallback: '');
}

Future<M> saveBus(M d) async {
  final actor = await need(adminRoles);
  final busNumber = '${d['busNumber'] ?? ''}'.trim(),
      capacity = _int(d['capacity']);
  if (busNumber.isEmpty || capacity < 1 || capacity > 120) {
    fail('Bus number and a capacity of 1 to 120 are required.');
  }
  final busId = (d['busId'] as String?) ?? safeId(busNumber);
  final ref = fs.doc('buses/$busId'), snap = await ref.get();
  final rid = '${d['routeId'] ?? ''}', routeId = rid.isEmpty ? null : rid;
  var stops = <String>[];
  if (routeId != null) {
    final r = (await fs.doc('routes/$routeId').get()).data();
    if (r == null) fail('Route not found.');
    stops = List<String>.from(r['stopIds'] as List);
  }
  String? warning;
  if (snap.exists) {
    final n = await activeCount(busId), old = snap.data()!;
    if (capacity < n) {
      fail('$n students are already allocated; capacity cannot be lower.');
    }
    if (n > 0 && routeId != old['routeId']) {
      fail(
        'This bus has allocated students. Use Emergency to change its route.',
      );
    }
    if (n > 0 &&
        (d['availability'] == false ||
            (d['maintenanceStatus'] ?? 'ok') != 'ok')) {
      warning =
          '$n students are still allocated to this bus. Use Emergency to move them.';
    }
  }
  final gps = '${d['gpsDeviceId'] ?? ''}'.trim();
  final data = <String, dynamic>{
    'busId': busId,
    'busNumber': busNumber,
    'capacity': capacity,
    'permittedRegionId': '${d['permittedRegionId'] ?? ''}'.isEmpty
        ? null
        : d['permittedRegionId'],
    'routeId': routeId,
    'availability': d['availability'] != false,
    'maintenanceStatus': d['maintenanceStatus'] ?? 'ok',
    'version': FieldValue.increment(1),
  };
  if (gps.isNotEmpty || !snap.exists) {
    data['gpsDeviceId'] = gps.isEmpty ? null : gps;
  }
  if (!snap.exists) {
    data.addAll({
      'driverId': null,
      'driverName': null,
      'driverContact': null,
      'trackingStatus': 'offline',
      'allocated': 0,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
  await ref.set(data, SetOptions(merge: true));
  await Mirror.apply(Mirror.busStops(busId, stops));
  await audit(
    actor,
    snap.exists ? 'updateBus' : 'createBus',
    'buses/$busId',
    snap.data(),
    {...data, 'version': null},
  );
  return {'busId': busId, 'warning': warning};
}

Future<M> removeBus(M d) async {
  final actor = await need(adminRoles);
  final busId = '${d['busId']}', n = await activeCount(busId);
  if (n > 0) fail('$n students are still allocated to this bus.');
  final bus = (await fs.doc('buses/$busId').get()).data();
  final m = <String, Object?>{
    'busStops/$busId': null,
    'riders/$busId': null,
    'busWriters/$busId': null,
    'liveLocations/$busId': null,
  };
  final ops = <void Function(WriteBatch)>[];
  if (bus?['driverId'] != null) {
    ops.add(
      (b) => b.update(fs.doc('drivers/${bus!['driverId']}'), {
        'assignedBusId': null,
      }),
    );
    ops.add(
      (b) => b.update(fs.doc('users/${bus!['driverId']}'), {'busId': null}),
    );
  }
  ops.add((b) => b.delete(fs.doc('buses/$busId')));
  await writeAll(ops);
  try {
    await Mirror.apply(m);
  } catch (_) {}
  await audit(actor, 'removeBus', 'buses/$busId', bus);
  return {'ok': true};
}

Future<M> assignDriver(M d) async {
  final actor = await need(adminRoles);
  final busId = '${d['busId']}', driverId = d['driverId'] as String?;
  final busRef = fs.doc('buses/$busId'), bus = (await busRef.get()).data();
  if (bus == null) fail('Bus not found.');
  final prev = bus['driverId'] as String?;
  Map<String, dynamic>? dr;
  if (driverId != null) {
    dr = (await fs.doc('drivers/$driverId').get()).data();
    if (dr == null || dr['status'] != 'active') fail('Driver is not active.');
    final region = bus['permittedRegionId'];
    if (region != null &&
        !((dr['permittedRegionIds'] as List?) ?? []).contains(region)) {
      fail('Driver is not authorised for this bus region.');
    }
    if (dr['assignedBusId'] != null && dr['assignedBusId'] != busId) {
      fail('Driver is already assigned to bus ${dr['assignedBusId']}.');
    }
  }
  final m = <String, Object?>{}, ops = <void Function(WriteBatch)>[];
  if (prev != null && prev != driverId) {
    ops.add((b) => b.update(fs.doc('drivers/$prev'), {'assignedBusId': null}));
    ops.add((b) => b.update(fs.doc('users/$prev'), {'busId': null}));
    m.addAll(Mirror.writer(busId, prev, false));
  }
  if (driverId != null) {
    ops.add(
      (b) => b.update(fs.doc('drivers/$driverId'), {'assignedBusId': busId}),
    );
    ops.add((b) => b.update(fs.doc('users/$driverId'), {'busId': busId}));
    m.addAll(Mirror.writer(busId, driverId, true));
  }
  ops.add(
    (b) => b.update(busRef, {
      'driverId': driverId,
      'driverName': dr?['name'],
      'driverContact': dr?['contact'],
      'version': FieldValue.increment(1),
    }),
  );
  await writeAll(ops);
  if (m.isNotEmpty) await Mirror.apply(m);
  if (driverId != null) {
    await notify(
      driverId,
      'Bus assigned',
      'You are assigned to bus ${bus['busNumber']}. Tap refresh to see it.',
    );
  }
  await audit(
    actor,
    'assignDriver',
    'buses/$busId',
    {'driverId': prev},
    {'driverId': driverId},
  );
  return {'ok': true};
}

Future<M> saveBoardingPoint(M d) async {
  final actor = await need(adminRoles);
  final name = '${d['name'] ?? ''}'.trim(),
      latitude = d['latitude'],
      longitude = d['longitude'],
      address = '${d['address'] ?? ''}'.trim(),
      district = '${d['district'] ?? ''}'.trim(),
      pointId = '${d['boardingPointId'] ?? ''}'.trim();
  if (name.isEmpty || name.length > 120) {
    fail('Enter a boarding point name (up to 120 characters).');
  }
  if (latitude is! num ||
      longitude is! num ||
      !latitude.isFinite ||
      !longitude.isFinite ||
      latitude < -90 ||
      latitude > 90 ||
      longitude < -180 ||
      longitude > 180) {
    fail('Choose a valid location on the map.');
  }
  if (address.length > 500 || district.length > 120) {
    fail('The detected location details are too long. Please try again.');
  }
  final collection = fs.collection('boardingPoints');
  final isEdit = pointId.isNotEmpty;
  final ref = isEdit ? collection.doc(pointId) : collection.doc();
  final snapshot = isEdit ? await ref.get() : null;
  if (isEdit && !snapshot!.exists) {
    fail('This boarding point no longer exists.');
  }
  final previous = snapshot?.data();
  final oldLatitude = (previous?['latitude'] as num?)?.toDouble();
  final oldLongitude = (previous?['longitude'] as num?)?.toDouble();
  final moved =
      oldLatitude != null &&
      oldLongitude != null &&
      boardingPointDistanceMeters(
            oldLatitude,
            oldLongitude,
            latitude.toDouble(),
            longitude.toDouble(),
          ) >
          0.5;
  final oldStatus = '${previous?['status'] ?? 'active'}';
  final status = '${d['status'] ?? oldStatus}';
  if (status != 'active' && status != 'inactive') {
    fail('Choose active or inactive status.');
  }
  final operations = (await fs.doc('config/operations').get()).data() ?? {};
  final rawRadius = operations['boardingPointDuplicateDistanceMeters'];
  final radius = rawRadius is num && rawRadius >= 25 && rawRadius <= 5000
      ? rawRadius.toDouble()
      : defaultBoardingPointDuplicateDistanceMeters.toDouble();
  if (!isEdit && d['allowDuplicate'] != true) {
    final existing = await collection.get();
    final duplicates = <M>[];
    for (final point in existing.docs) {
      final p = point.data();
      final lat = p['latitude'], lng = p['longitude'];
      if (p['status'] == 'inactive' || lat is! num || lng is! num) continue;
      final distance = boardingPointDistanceMeters(
        latitude.toDouble(),
        longitude.toDouble(),
        lat.toDouble(),
        lng.toDouble(),
      );
      if (distance <= radius) {
        duplicates.add({
          'boardingPointId': point.id,
          'name': p['name'] ?? 'Unnamed boarding point',
          'address': p['address'] ?? '',
          'latitude': lat,
          'longitude': lng,
          'distanceMeters': distance.round(),
        });
      }
    }
    if (duplicates.isNotEmpty) {
      return {'duplicates': duplicates, 'nearbyDistanceMeters': radius.round()};
    }
  }
  final willAffectStudents =
      isEdit &&
      ((moved && oldStatus != 'inactive') ||
          (status == 'inactive' && oldStatus != 'inactive'));
  var affectedStudentCount = 0;
  if (willAffectStudents) {
    final assigned = await fs
        .collection('students')
        .where('approvedBoardingPointId', isEqualTo: pointId)
        .get();
    final permitted = await fs
        .collection('students')
        .where('availableBoardingPointIds', arrayContains: pointId)
        .get();
    affectedStudentCount = {
      for (final student in [...assigned.docs, ...permitted.docs]) student.id,
    }.length;
    if (affectedStudentCount > 0 && d['confirmAffected'] != true) {
      return {
        'needsReviewConfirmation': true,
        'affectedStudentCount': affectedStudentCount,
      };
    }
  }

  double? roadDistanceKm = (previous?['roadDistanceKm'] as num?)?.toDouble();
  String? distanceWarning;
  final collegeData = (await fs.doc('config/college').get()).data();
  final hasCollegeLocation =
      collegeData?['lat'] is num && collegeData?['lng'] is num;
  if (hasCollegeLocation && (!isEdit || moved)) {
    try {
      final distance = await osrm([
        [longitude.toDouble(), latitude.toDouble()],
        [
          (collegeData!['lng'] as num).toDouble(),
          (collegeData['lat'] as num).toDouble(),
        ],
      ]);
      roadDistanceKm = (distance.km * 100).round() / 100;
    } on Fail {
      roadDistanceKm = null;
      distanceWarning =
          'The boarding point was saved, but road distance could not be calculated.';
    }
  } else if (!hasCollegeLocation && (!isEdit || moved)) {
    roadDistanceKm = null;
    distanceWarning =
        'The boarding point was saved. Add the college location later to calculate road distance.';
  }
  final alreadyFlagged = previous?['reviewRequired'] == true;
  final reviewRequired =
      alreadyFlagged || (willAffectStudents && affectedStudentCount > 0);
  final reviewReason = moved
      ? 'location_moved'
      : status == 'inactive' && oldStatus != 'inactive'
      ? 'deactivated'
      : previous?['reviewReason'];
  final now = FieldValue.serverTimestamp();
  final values = <String, dynamic>{
    'boardingPointId': ref.id,
    'name': name,
    'nameManuallyEdited': d['nameManuallyEdited'] == true,
    'address': address,
    'district': district,
    'latitude': latitude.toDouble(),
    'longitude': longitude.toDouble(),
    'status': status,
    'approvalStatus': 'approved',
    'roadDistanceKm': roadDistanceKm,
    'updatedBy': actor.uid,
    'updatedAt': now,
    'reviewRequired': reviewRequired,
    if (reviewRequired) ...{
      'reviewReason': reviewReason,
      'reviewAffectedStudentCount': affectedStudentCount > 0
          ? affectedStudentCount
          : previous?['reviewAffectedStudentCount'] ?? 0,
      if (!alreadyFlagged || willAffectStudents) ...{
        'reviewFlaggedBy': actor.uid,
        'reviewFlaggedAt': now,
      },
    },
  };
  if (!isEdit) {
    values.addAll({
      'createdBy': actor.uid,
      'createdAt': now,
      'verifiedBy': actor.uid,
      'verifiedAt': now,
    });
  }
  await ref.set(values, SetOptions(merge: true));
  await audit(
    actor,
    isEdit ? 'updateBoardingPoint' : 'createBoardingPoint',
    'boardingPoints/${ref.id}',
    previous,
    values,
  );
  return {
    'boardingPointId': ref.id,
    'roadDistanceKm': roadDistanceKm,
    'distanceWarning': distanceWarning,
    'reviewRequired': reviewRequired,
    'affectedStudentCount': affectedStudentCount,
  };
}

Future<M> setBoardingPointDuplicateDistance(M d) async {
  final actor = await need(adminRoles);
  final meters = _int(d['meters']);
  if (meters < 25 || meters > 5000) {
    fail('Set the nearby duplicate check between 25 and 5,000 metres.');
  }
  await fs.doc('config/operations').set({
    'boardingPointDuplicateDistanceMeters': meters,
    'updatedBy': actor.uid,
    'updatedAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));
  await audit(
    actor,
    'setBoardingPointDuplicateDistance',
    'config/operations',
    null,
    {'boardingPointDuplicateDistanceMeters': meters},
  );
  return {'meters': meters};
}

Future<M> saveRoute(M d) async {
  final actor = await need(adminRoles);
  final stopIds = List<String>.from((d['stopIds'] as List?) ?? []),
      name = '${d['routeName'] ?? ''}'.trim();
  if (name.isEmpty || stopIds.isEmpty) {
    fail('Route name and at least one stop are required.');
  }
  final stops = <M>[];
  for (final id in stopIds) {
    final p = (await fs.doc('boardingPoints/$id').get()).data();
    if (p == null ||
        p['approvalStatus'] != 'approved' ||
        p['status'] == 'inactive') {
      fail('Every stop must be an active, approved boarding point.');
    }
    stops.add(p);
  }
  final routeId = (d['routeId'] as String?) ?? fs.collection('routes').doc().id,
      ref = fs.doc('routes/$routeId'),
      snap = await ref.get();
  if (snap.exists &&
      d['baseVersion'] != null &&
      _int(snap.data()!['version']) != _int(d['baseVersion'])) {
    fail('Someone else changed this route. Reload and try again.');
  }
  final onRoute = await fs
      .collection('buses')
      .where('routeId', isEqualTo: routeId)
      .get();
  if (snap.exists) {
    for (final b in onRoute.docs) {
      final al = await fs
          .collection('allocations')
          .where('busId', isEqualTo: b.id)
          .where('status', isEqualTo: 'active')
          .get();
      if (al.docs.any((a) => !stopIds.contains(a.data()['boardingPointId']))) {
        fail(
          'Bus ${b.data()['busNumber']} has students at a stop you removed.',
        );
      }
    }
  }
  final c = await college();
  final r = await osrm([
    for (final s in stops)
      [(s['longitude'] as num).toDouble(), (s['latitude'] as num).toDouble()],
    [(c['lng'] as num).toDouble(), (c['lat'] as num).toDouble()],
  ]);
  final arrival = '${d['arrivalBy'] ?? ''}';
  await ref.set({
    'routeId': routeId,
    'routeName': name,
    'origin': stops.first['name'],
    'destination': c['name'] ?? 'College',
    'stopIds': stopIds,
    'permittedRegionId': '${d['permittedRegionId'] ?? ''}'.isEmpty
        ? null
        : d['permittedRegionId'],
    'routeGeometry': r.geometry,
    'routeKm': (r.km * 10).round() / 10,
    'arrivalBy': RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(arrival)
        ? arrival
        : null,
    'status': 'active',
    'version': FieldValue.increment(1),
  }, SetOptions(merge: true));
  for (final b in onRoute.docs) {
    await Mirror.apply(Mirror.busStops(b.id, stopIds));
  }
  await audit(
    actor,
    snap.exists ? 'updateRoute' : 'createRoute',
    'routes/$routeId',
    snap.data()?['stopIds'],
    stopIds,
  );
  return {'routeId': routeId};
}

Future<M> deleteBoardingPoint(M d) async {
  final actor = await need(adminRoles);
  final id = '${d['boardingPointId']}';
  if (id.isEmpty) fail('Boarding-point ID is required.');
  final used = await fs
      .collection('routes')
      .where('stopIds', arrayContains: id)
      .limit(1)
      .get();
  if (used.docs.isNotEmpty) {
    fail('This stop is used by a route. Remove it from the route first.');
  }
  final stu = await fs
      .collection('students')
      .where('approvedBoardingPointId', isEqualTo: id)
      .limit(1)
      .get();
  if (stu.docs.isNotEmpty) {
    fail(
      'A student currently has this stop selected. The student must change stops first.',
    );
  }
  final permitted = await fs
      .collection('students')
      .where('availableBoardingPointIds', arrayContains: id)
      .limit(1)
      .get();
  if (permitted.docs.isNotEmpty) {
    fail(
      'This stop is assigned in a student permitted-options list. Remove it from that student first.',
    );
  }
  await fs.doc('boardingPoints/$id').delete();
  await audit(actor, 'deleteBoardingPoint', 'boardingPoints/$id');
  return {'ok': true};
}

Future<M> deleteRoute(M d) async {
  final actor = await need(adminRoles);
  final id = '${d['routeId']}';
  final buses = await fs
      .collection('buses')
      .where('routeId', isEqualTo: id)
      .limit(1)
      .get();
  if (buses.docs.isNotEmpty) {
    fail('A bus uses this route. Change the bus route first.');
  }
  await fs.doc('routes/$id').delete();
  await audit(actor, 'deleteRoute', 'routes/$id');
  return {'ok': true};
}

/// Route Admins may only narrow the window the Super Admin allows.
Future<M> setOperationalHours(M d) async {
  final actor = await need(adminRoles);
  final s = '${d['start'] ?? ''}',
      e = '${d['end'] ?? ''}',
      re = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
  if (!re.hasMatch(s) || !re.hasMatch(e) || s.compareTo(e) >= 0) {
    fail('Use 24-hour times, with the start before the end.');
  }
  final g = (await fs.doc('config/app').get()).data() ?? {},
      gs = '${g['trackingStart'] ?? '06:00'}',
      ge = '${g['trackingEnd'] ?? '20:00'}';
  if (s.compareTo(gs) < 0 || e.compareTo(ge) > 0) {
    fail('Hours must stay inside the college limit of $gs to $ge.');
  }
  await fs.doc('config/operations').set({
    'trackingStart': s,
    'trackingEnd': e,
    'updatedBy': actor.uid,
    'updatedAt': FieldValue.serverTimestamp(),
  });
  await audit(actor, 'setOperationalHours', 'config/operations', null, {
    'start': s,
    'end': e,
  });
  return {'ok': true};
}

// ---------------- Boarding points (student side and review) ----------------
Future<M> requestBoardingPoint(M d) async {
  await need(['student']);
  fail(
    'Boarding-point changes are handled through the college. No database request is created.',
  );
}

Future<M> selectBoardingPoint(M d) async {
  await need(['student']);
  fail(
    'Students cannot select boarding points. Assignments come from the college.',
  );
}

Future<M> reviewBoardingRequest(M d) async {
  final actor = await need(adminRoles);
  final rRef = fs.doc('boardingRequests/${d['requestId']}'),
      r = (await rRef.get()).data();
  if (r == null || r['status'] != 'pending') fail('Request is not pending.');
  final note = d['note'];
  if (d['approve'] != true) {
    await rRef.update({
      'status': 'rejected',
      'note': note,
      'reviewedBy': actor.uid,
      'reviewedAt': FieldValue.serverTimestamp(),
    });
    await notify(
      '${r['authUid']}',
      'Boarding point rejected',
      '${note ?? 'Your requested boarding point was not approved.'}',
    );
    await audit(
      actor,
      'rejectBoardingRequest',
      'boardingRequests/${rRef.id}',
      null,
      null,
      '$note',
    );
    return {'ok': true};
  }
  final c = await college();
  final sRef = fs.doc('students/${r['studentId']}'),
      s = (await sRef.get()).data();
  if (s == null) fail('Student record not found.');
  final road = await osrm([
    [
      (r['requestedLongitude'] as num).toDouble(),
      (r['requestedLatitude'] as num).toDouble(),
    ],
    [(c['lng'] as num).toDouble(), (c['lat'] as num).toDouble()],
  ]);
  final km = (road.km * 100).round() / 100;
  await fs.doc('boardingPoints/${rRef.id}').set({
    'boardingPointId': rRef.id,
    'name': r['requestedName'],
    'latitude': r['requestedLatitude'],
    'longitude': r['requestedLongitude'],
    'roadDistanceKm': km,
    'approvalStatus': 'approved',
    'verifiedBy': actor.uid,
    'verifiedAt': FieldValue.serverTimestamp(),
  });
  final permittedUpdate = <Object?>[rRef.id];
  if (s['allocationId'] != null) {
    final allocation = await fs.doc('allocations/${s['allocationId']}').get();
    if (allocation.exists &&
        allocation.data()?['status'] == 'active' &&
        s['approvedBoardingPointId'] != null) {
      permittedUpdate.add(s['approvedBoardingPointId']);
    }
  }
  await sRef.update({
    'availableBoardingPointIds': FieldValue.arrayUnion(permittedUpdate),
  });
  await rRef.update({
    'status': 'approved',
    'note': note,
    'reviewedBy': actor.uid,
    'reviewedAt': FieldValue.serverTimestamp(),
  });
  final fee = await feeFor('${(await cfg())['academicYear']}', km);
  await notify(
    '${r['authUid']}',
    'Boarding point approved',
    fee == null
        ? 'Your stop is approved at $km km.'
        : 'Your stop is approved. Annual fee Rs ${fee['amount']} for $km km, payable at the college office.',
  );
  await audit(
    actor,
    'approveBoardingRequest',
    'students/${r['studentId']}',
    {'availableBoardingPointIds': s['availableBoardingPointIds']},
    {
      'availableBoardingPointIds': [
        ...(s['availableBoardingPointIds'] as List? ?? []),
        rRef.id,
      ],
    },
  );
  return {'amount': fee?['amount'], 'distanceKm': km};
}
