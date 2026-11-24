import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthStorage {
  static const _rememberKey = 'routesync_remember_me';
  static const _emailKey = 'routesync_remembered_email';
  static const _passwordKey = 'routesync_remembered_password';

  final FlutterSecureStorage secure;

  AuthStorage({FlutterSecureStorage? secure})
    : secure =
          secure ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              encryptedSharedPreferences: true,
              sharedPreferencesName: 'routesync_secure_credentials',
              preferencesKeyPrefix: 'routesync_',
            ),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  Future<bool> getRememberMe() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_rememberKey) ?? false;
  }

  Future<String> getRememberedEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_emailKey) ?? '';
  }

  Future<String?> getRememberedPassword(String email) async {
    if (kIsWeb || email.isEmpty) return null;
    return secure.read(key: '$_passwordKey:${email.toLowerCase()}');
  }

  Future<void> rememberEmailPassword({
    required String email,
    required String password,
  }) async {
    final normalized = email.trim().toLowerCase();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_rememberKey, true);
    await prefs.setString(_emailKey, normalized);
    if (kIsWeb) {
      await forgetPassword();
      return;
    }
    await secure.write(key: '$_passwordKey:$normalized', value: password);
  }

  Future<void> rememberEmail(String email) async {
    final normalized = email.trim().toLowerCase();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_rememberKey, true);
    await prefs.setString(_emailKey, normalized);
  }

  Future<void> forgetPassword() async {
    final prefs = await SharedPreferences.getInstance();
    final email = prefs.getString(_emailKey)?.toLowerCase();
    if (!kIsWeb && email != null && email.isNotEmpty) {
      await secure.delete(key: '$_passwordKey:$email');
    }
  }

  Future<void> clearRememberMe() async {
    await forgetPassword();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_rememberKey);
    await prefs.remove(_emailKey);
  }

  Future<void> forgetThisDevice() async {
    final prefs = await SharedPreferences.getInstance();
    final email = prefs.getString(_emailKey)?.toLowerCase();
    if (!kIsWeb && email != null && email.isNotEmpty) {
      await secure.delete(key: '$_passwordKey:$email');
    }
    await prefs.remove(_rememberKey);
    await prefs.remove(_emailKey);
  }
}
