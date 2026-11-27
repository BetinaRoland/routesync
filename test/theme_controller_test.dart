import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:routesync/core/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the chosen theme is saved and restored after a restart', () async {
    SharedPreferences.setMockInitialValues({});
    await setThemeMode(ThemeMode.dark);
    themeMode.value = ThemeMode.system; // simulate closing and reopening the app
    await loadThemeMode();
    expect(themeMode.value, ThemeMode.dark);
  });

  test('with nothing saved the app follows the device setting', () async {
    SharedPreferences.setMockInitialValues({});
    themeMode.value = ThemeMode.light;
    await loadThemeMode();
    expect(themeMode.value, ThemeMode.system);
  });
}
