import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:routesync/core/auth_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('remember me stores email and password in secure storage', () async {
    final storage = AuthStorage();

    await storage.rememberEmailPassword(
      email: 'student@college.edu',
      password: 'test-password',
    );

    expect(await storage.getRememberMe(), isTrue);
    expect(await storage.getRememberedEmail(), 'student@college.edu');
    expect(
      await storage.getRememberedPassword('student@college.edu'),
      'test-password',
    );
  });

  test('forget this device clears remembered email and password', () async {
    final storage = AuthStorage();
    await storage.rememberEmailPassword(
      email: 'student@college.edu',
      password: 'test-password',
    );

    await storage.forgetThisDevice();

    expect(await storage.getRememberMe(), isFalse);
    expect(await storage.getRememberedEmail(), isEmpty);
    expect(await storage.getRememberedPassword('student@college.edu'), isNull);
  });

  test('clearing remember me removes password and remembered state', () async {
    final storage = AuthStorage();
    await storage.rememberEmailPassword(
      email: 'student@college.edu',
      password: 'test-password',
    );

    await storage.clearRememberMe();

    expect(await storage.getRememberMe(), isFalse);
    expect(await storage.getRememberedEmail(), isEmpty);
  });
}
