import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'session.dart';

/// Signs the user out when their sign-in is older than the limit for their role
/// (admins 12 h, drivers 24 h, students 72 h). Checked on start and every 5 minutes.
class SessionGuard extends StatefulWidget {
  final Role role;
  final Widget child;
  const SessionGuard({super.key, required this.role, required this.child});
  @override
  State<SessionGuard> createState() => _SessionGuardState();
}

class _SessionGuardState extends State<SessionGuard> {
  Timer? _t;

  int get _maxHours => switch (widget.role) {
        Role.superAdmin || Role.routeAdmin => 12,
        Role.driver => 24,
        _ => 72,
      };

  @override
  void initState() {
    super.initState();
    _check();
    _t = Timer.periodic(const Duration(minutes: 5), (_) => _check());
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final at = (await user.getIdTokenResult()).authTime;
      if (at != null && DateTime.now().difference(at).inHours >= _maxHours) await FirebaseAuth.instance.signOut();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
