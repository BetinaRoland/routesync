import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/widgets.dart';
import 'scan_page.dart';

/// Student onboarding: enter the single-use code from the college, confirm details, set a password.
class RegisterPage extends StatefulWidget {
  final String? initialCode;
  const RegisterPage({super.key, this.initialCode});
  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _code = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  Map<String, dynamic>? _who;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final c = widget.initialCode;
    if (c != null && c.isNotEmpty) {
      _code.text = c;
      WidgetsBinding.instance.addPostFrameCallback((_) => _check()); // invitation link: verify straight away
    }
  }

  Future<void> _scan() async {
    final code = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const ScanPage()));
    if (code == null || !mounted) return;
    _code.text = code;
    await _check();
  }

  Future<void> _check() async {
    setState(() => _busy = true);
    await runAction(context, () async {
      _who = await Api.call('previewInvite', {'token': _code.text.trim()});
      return null;
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _create() async {
    if (_pass.text != _pass2.text) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Passwords do not match.')));
      return;
    }
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    final ok = await runAction(context, () async {
      final r = await Api.call('redeemInvite', {'token': _code.text.trim(), 'password': _pass.text});
      await FirebaseAuth.instance.signInWithEmailAndPassword(email: r['email'] as String, password: _pass.text);
      return null;
    });
    if (ok) navigator.popUntil((r) => r.isFirst);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Student registration')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          if (_who == null) ...[
            const Text('Enter the invitation code you received from the college. It works once.'),
            const SizedBox(height: 12),
            TextField(controller: _code, decoration: const InputDecoration(labelText: 'Invitation code')),
            if (!kIsWeb) Padding(padding: const EdgeInsets.only(top: 8), child: OutlinedButton.icon(onPressed: _busy ? null : _scan, icon: const Icon(Icons.qr_code_scanner), label: const Text('Scan QR code'))),
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : _check, child: const Text('Continue')),
          ] else ...[
            Card(child: ListTile(title: Text('${_who!['name']}'), subtitle: Text('${_who!['registerNumber']}\nDepartment ${_who!['departmentId']}, year ${_who!['academicYear']}\n${_who!['email']}'), isThreeLine: true)),
            const SizedBox(height: 8),
            const Text('Check these details, then choose a password for your account.'),
            const SizedBox(height: 12),
            TextField(controller: _pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password (8+ characters)')),
            const SizedBox(height: 12),
            TextField(controller: _pass2, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm password')),
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : _create, child: const Text('Create account')),
          ],
        ]),
      );
}
