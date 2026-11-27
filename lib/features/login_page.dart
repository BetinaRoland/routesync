import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import '../core/api.dart';
import '../core/auth_storage.dart';
import '../core/components.dart';
import 'register_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  bool _rememberMe = false;
  bool _obscurePassword = true;
  bool _invitationExpanded = false;
  String? _error;
  final _invitationCode = TextEditingController();
  final _authStorage = AuthStorage();

  @override
  void initState() {
    super.initState();
    _restoreRememberedCredentials();
  }

  Future<void> _restoreRememberedCredentials() async {
    final rememberMe = await _authStorage.getRememberMe();
    final email = await _authStorage.getRememberedEmail();
    if (!mounted) return;
    setState(() {
      _rememberMe = rememberMe;
      if (rememberMe) _email.text = email;
    });
    if (rememberMe) {
      final password = await _authStorage.getRememberedPassword(email);
      if (mounted && password != null) _pass.text = password;
    }
  }

  Future<void> _saveSuccessfulSignIn() async {
    final email = _email.text.trim();
    if (_rememberMe) {
      await _authStorage.rememberEmailPassword(
        email: email,
        password: _pass.text,
      );
    } else {
      await _authStorage.clearRememberMe();
    }
  }

  Future<void> _forgetThisDevice() async {
    await _authStorage.forgetThisDevice();
    if (!mounted) return;
    setState(() {
      _rememberMe = false;
      _email.clear();
      _pass.clear();
      _error = null;
    });
  }

  Future<void> _signIn() async {
    if (_email.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Enter your email and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _email.text.trim(),
        password: _pass.text,
      );
      await _saveSuccessfulSignIn();
    } on FirebaseAuthException catch (e) {
      setState(() => _error = _friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _google() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final provider = GoogleAuthProvider();
      if (kIsWeb) {
        await FirebaseAuth.instance.signInWithPopup(provider);
      } else {
        await FirebaseAuth.instance.signInWithProvider(provider);
      }
      final user = FirebaseAuth.instance.currentUser;
      if (user?.email != null) {
        if (_rememberMe) {
          await _authStorage.rememberEmail(user!.email!);
          if (mounted) _email.text = user.email!;
        } else {
          await _authStorage.clearRememberMe();
        }
      }
    } on FirebaseAuthException catch (e) {
      const quiet = [
        'popup-closed-by-user',
        'cancelled-popup-request',
        'canceled',
        'web-context-canceled',
      ];
      if (!quiet.contains(e.code)) setState(() => _error = _friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendly(FirebaseAuthException e) => switch (e.code) {
    'invalid-credential' ||
    'wrong-password' ||
    'user-not-found' ||
    'invalid-email' => 'Email or password is not correct.',
    'user-disabled' =>
      'This account has been disabled. Contact the college transport office.',
    'too-many-requests' =>
      'Too many attempts. Wait a few minutes or reset your password.',
    'network-request-failed' =>
      'No connection. Check your internet and try again.',
    'operation-not-allowed' =>
      'This sign-in method is not turned on in Firebase.',
    _ => e.message ?? 'Sign-in failed. Try again.',
  };

  Future<void> _reset() async {
    if (_email.text.trim().isEmpty) {
      setState(() => _error = 'Enter your email first.');
      return;
    }
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(
        email: _email.text.trim(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'If that email has an account, a reset link is on its way.',
            ),
          ),
        );
      }
    } on FirebaseAuthException catch (e) {
      setState(() => _error = _friendly(e));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              children: [
                const Align(
                  alignment: Alignment.centerRight,
                  child: ThemeToggleButton(),
                ),
                Text(
                  'RouteSync',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                const Text('College bus tracking and management'),
                const SizedBox(height: 12),
                const BusOutline(height: 64, opacity: 0.85),
                const SizedBox(height: 20),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pass,
                  obscureText: _obscurePassword,
                  onSubmitted: (_) => _signIn(),
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(
                    labelText: 'Password',
                    suffixIcon: IconButton(
                      tooltip: _obscurePassword
                          ? 'Show password'
                          : 'Hide password',
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _rememberMe,
                  onChanged: (value) async {
                    final selected = value == true;
                    setState(() => _rememberMe = selected);
                    if (!selected) {
                      await _authStorage.clearRememberMe();
                      if (mounted) _pass.clear();
                    }
                  },
                  title: const Text('Remember me on this device'),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _forgetThisDevice,
                    child: const Text('Forget this device'),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy ? null : _signIn,
                    child: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Sign in'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _google,
                    icon: const Icon(Icons.account_circle_outlined),
                    label: const Text('Continue with Google'),
                  ),
                ),
                TextButton(
                  onPressed: _reset,
                  child: const Text('Forgot password'),
                ),
                const Divider(height: 28),
                OutlinedButton(
                  onPressed: () => setState(
                    () => _invitationExpanded = !_invitationExpanded,
                  ),
                  child: const Text('I have an invitation code'),
                ),
                if (_invitationExpanded) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _invitationCode,
                    decoration: const InputDecoration(
                      labelText: 'Invitation code',
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              final code = _invitationCode.text.trim();
                              if (code.isEmpty) {
                                setState(
                                  () => _error = 'Enter the invitation code.',
                                );
                                return;
                              }
                              setState(() {
                                _busy = true;
                                _error = null;
                              });
                              try {
                                await Api.call('previewInvite', {
                                  'token': code,
                                });
                                if (!context.mounted) return;
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        RegisterPage(initialCode: code),
                                  ),
                                );
                              } catch (e) {
                                if (mounted) {
                                  setState(() => _error = '$e');
                                }
                              } finally {
                                if (mounted) {
                                  setState(() => _busy = false);
                                }
                              }
                            },
                      child: const Text('Continue with invitation'),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                const Text(
                  'Google sign-in works for accounts the college has already set up.',
                  style: TextStyle(fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
