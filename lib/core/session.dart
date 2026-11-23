import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

enum Role { superAdmin, routeAdmin, driver, student, unknown }

class Session {
  final User user;
  final Role role;
  final String name;
  final String? busId; // driver's bus
  final bool disabled;
  Session(this.user, this.role, this.name, this.busId, this.disabled);

  /// Reads this person's record. A brand-new student account may need a moment while registration finishes.
  static Future<Session> load(User user) async {
    Map<String, dynamic>? x;
    final fresh = user.metadata.creationTime != null && DateTime.now().difference(user.metadata.creationTime!).inMinutes < 3;
    for (var i = 0; i < (fresh ? 6 : 1); i++) {
      try {
        x = (await FirebaseFirestore.instance.doc('users/${user.uid}').get()).data();
      } catch (_) {
        x = null;
      }
      if (x != null) break;
      await Future.delayed(const Duration(milliseconds: 700));
    }
    if (x == null) return Session(user, Role.unknown, '', null, false);
    if (x['status'] != 'active') return Session(user, Role.unknown, '${x['name'] ?? ''}', null, true);
    final role = switch (x['role']) {
      'superAdmin' => Role.superAdmin,
      'routeAdmin' => Role.routeAdmin,
      'driver' => Role.driver,
      'student' => Role.student,
      _ => Role.unknown,
    };
    return Session(user, role, '${x['name'] ?? ''}', x['busId'] as String?, false);
  }
}
