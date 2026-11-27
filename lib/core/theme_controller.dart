import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app-wide light / dark / system choice. The top bar toggle changes it
/// and it is remembered between launches.
final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.system);

const _themeKey = 'themeMode';

/// Reads the saved choice. Call once before runApp.
Future<void> loadThemeMode() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    themeMode.value = switch (prefs.getString(_themeKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  } catch (_) {
    // Preferences unavailable: keep following the device setting.
  }
}

/// Applies the choice immediately and saves it.
Future<void> setThemeMode(ThemeMode mode) async {
  themeMode.value = mode;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, mode.name);
  } catch (_) {
    // The change still applies for this session.
  }
}
