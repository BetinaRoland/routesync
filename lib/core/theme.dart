import 'package:material_ui/material_ui.dart';
import 'package:google_fonts/google_fonts.dart';

// Brand: royal blue and white.
// White text on royal is 5.7:1; royal on the dark page is 3.2:1, which is fine for icons.
// For text in dark mode use Theme.of(context).colorScheme.primary instead.
const royal = Color(0xFF2A5BE0);

/// Old name, kept so existing screens keep compiling. It is the royal blue now.
const navy = royal;

// Kept only for map markers (current / upcoming stop).
const amber = Color(0xFFFFB400);
const teal = Color(0xFF12A5C4);

/// RouteSync palette: deep navy, royal blue, white and soft pastel blues.
abstract final class Brand {
  static const navy = Color(0xFF0B2A5B); // deep navy
  static const royal = Color(0xFF2A5BE0); // royal blue
  static const paleBlue = Color(0xFFF3F6FF); // very light pastel blue
  static const powderBlue = Color(0xFFE4EBFF); // powder blue
  static const skyBlue = Color(0xFFBFD0F7); // muted sky blue
  static const blueGrey = Color(0xFF5B6478); // soft blue-grey
}

/// Corner radii used by every card and control.
abstract final class Rd {
  static const double card = 20, control = 12, pill = 24;
}

/// Soft floating-card shadow. Dark mode relies on the hairline border instead.
List<BoxShadow> softShadow(BuildContext context, {bool strong = false}) {
  if (Theme.of(context).brightness == Brightness.dark) return const [];
  return [
    BoxShadow(
      color: Brand.navy.withValues(alpha: strong ? 0.14 : 0.07),
      blurRadius: strong ? 24 : 16,
      offset: const Offset(0, 6),
    ),
  ];
}

/// Spacing scale. Use these instead of ad-hoc numbers so screens line up.
abstract final class Sp {
  static const double xs = 4, sm = 8, md = 12, lg = 16, xl = 24;
}

/// Meaning of a status. Always show it with an icon or a label too, never colour alone.
enum Tone { success, warning, danger, info, neutral }

/// Status colours that adapt to light and dark mode.
/// Each one is at least 4.5:1 against the page and against its own 12% tint (checked in test/tone_colors_test.dart).
Color toneColor(BuildContext context, Tone tone) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (tone) {
    Tone.success => dark ? const Color(0xFF6FD08C) : const Color(0xFF166A30),
    Tone.warning => dark ? const Color(0xFFFFB74D) : const Color(0xFF965000),
    Tone.danger => dark ? const Color(0xFFFF8A80) : const Color(0xFFB3261E),
    Tone.info => dark ? const Color(0xFF7CC4DA) : const Color(0xFF0B6B85),
    Tone.neutral => Theme.of(context).colorScheme.onSurfaceVariant,
  };
}

/// Maps a legacy Material colour (red, orange, green, grey...) onto the matching status tone.
/// Colours that are not status colours (navy, teal) are returned unchanged.
Color toneFor(BuildContext context, Color legacy) {
  final hsl = HSLColor.fromColor(legacy);
  if (hsl.saturation < 0.25) return toneColor(context, Tone.neutral);
  final h = hsl.hue;
  if (h < 20 || h >= 340) return toneColor(context, Tone.danger);
  if (h < 55) return toneColor(context, Tone.warning);
  if (h >= 80 && h < 170) return toneColor(context, Tone.success);
  return legacy;
}

/// Royal blue and white. Clear, minimal, with every tappable thing shaped like a button.
/// Dark mode uses a lighter blue on a near-black page so text and icons stay readable.
ThemeData buildTheme([Brightness brightness = Brightness.light]) {
  final dark = brightness == Brightness.dark;
  final base = ColorScheme.fromSeed(
    seedColor: royal,
    brightness: brightness,
    tertiary: teal,
  );
  final scheme = dark
      ? base.copyWith(
          primary: const Color(0xFF8FAAFF),
          onPrimary: const Color(0xFF0A1F66),
          primaryContainer: const Color(0xFF1B2F78),
          onPrimaryContainer: const Color(0xFFDDE5FF),
          secondary: const Color(0xFF8FAAFF),
          secondaryContainer: const Color(0xFF1B2F78),
          onSecondaryContainer: const Color(0xFFDDE5FF),
          surface: const Color(0xFF0F131C),
          onSurface: const Color(0xFFE6E9F2),
          onSurfaceVariant: const Color(0xFFAAB3C8),
          outlineVariant: const Color(0xFF2A3347),
        )
      : base.copyWith(
          primary: royal,
          onPrimary: Colors.white,
          primaryContainer: const Color(0xFFE4EBFF),
          onPrimaryContainer: const Color(0xFF0A2A8C),
          secondary: royal,
          secondaryContainer: const Color(0xFFE4EBFF),
          onSecondaryContainer: const Color(0xFF0A2A8C),
          surface: Colors.white,
          onSurface: const Color(0xFF111827),
          onSurfaceVariant: const Color(0xFF5B6478),
          outlineVariant: const Color(0xFFD5DCEB),
        );
  final line = scheme.outlineVariant;
  final baseText = ThemeData(brightness: brightness).textTheme.apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );
  final textTheme = baseText.copyWith(
    headlineLarge: GoogleFonts.sora(
      textStyle: baseText.headlineLarge,
      fontWeight: FontWeight.w700,
    ),
    headlineMedium: GoogleFonts.sora(
      textStyle: baseText.headlineMedium,
      fontWeight: FontWeight.w700,
    ),
    headlineSmall: GoogleFonts.sora(
      textStyle: baseText.headlineSmall,
      fontWeight: FontWeight.w700,
    ),
    titleLarge: GoogleFonts.sora(
      textStyle: baseText.titleLarge,
      fontWeight: FontWeight.w600,
    ),
    titleMedium: GoogleFonts.sora(
      textStyle: baseText.titleMedium,
      fontWeight: FontWeight.w600,
    ),
  );
  final radius = BorderRadius.circular(12);
  // Royal blue header in light mode; plain dark surface in dark mode.
  final barBg = dark ? scheme.surface : royal;
  final barFg = dark ? scheme.onSurface : Colors.white;
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? scheme.surface : Brand.paleBlue,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: barBg,
      foregroundColor: barFg,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: GoogleFonts.sora(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: barFg,
      ),
      shape: dark ? Border(bottom: BorderSide(color: line)) : null,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: line),
      ),
    ),
    dividerTheme: DividerThemeData(color: line, space: 1, thickness: 1),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
      minVerticalPadding: 8,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: scheme.primary,
      unselectedLabelColor: scheme.onSurfaceVariant,
      labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
      unselectedLabelStyle: const TextStyle(
        fontWeight: FontWeight.w500,
        fontSize: 14,
      ),
      indicatorSize: TabBarIndicatorSize.tab,
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(color: scheme.primary, width: 3),
      ),
      dividerColor: line,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(88, 48),
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(88, 48),
        side: BorderSide(color: scheme.primary.withValues(alpha: 0.6)),
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 2,
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: radius),
    ),
  );
}
