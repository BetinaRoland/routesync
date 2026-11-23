import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'common.dart';

Future<M> importStudents(M d) async {
  final actor = await need(adminRoles);
  final rows = (d['rows'] as List?) ?? [];
  final dry = d['dryRun'] != false;
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
    });
  }
  final existing = await fs.collection('students').get();
  final ids = {for (final e in existing.docs) e.id},
      mails = {for (final e in existing.docs) '${e.data()['email']}'};
  final fresh = valid.where((v) {
    if (ids.contains(v['studentId'])) {
      errors.add({
        'registerNumber': v['registerNumber'],
        'error': 'Student already registered.',
      });
      return false;
    }
    if (mails.contains(v['email'])) {
      errors.add({
        'registerNumber': v['registerNumber'],
        'error': 'Email already used by another student.',
      });
      return false;
    }
    return true;
  }).toList();
  if (dry) return {'valid': fresh.length, 'errors': errors};

  final base = '${(await cfg())['webBaseUrl']}'.replaceAll(RegExp(r'/$'), '');
  final invites = <M>[], ops = <void Function(WriteBatch)>[];
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
