import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:routesync/core/theme.dart';

double _channel(double v) =>
    v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) =>
    0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

double _contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Color _over(Color fg, Color bg, double alpha) =>
    Color.lerp(bg, fg.withValues(alpha: 1), alpha)!;

void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('status colours are readable in $brightness', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      );
      final page = brightness == Brightness.light
          ? const Color(0xFFFFFFFF)
          : const Color(0xFF121212);
      for (final tone in [Tone.success, Tone.warning, Tone.danger, Tone.info]) {
        final c = toneColor(ctx, tone);
        expect(
          _contrast(c, page),
          greaterThanOrEqualTo(4.5),
          reason: '$tone on the page',
        );
        // statusPill draws the text on a 12% tint of its own colour.
        expect(
          _contrast(c, _over(c, page, 0.12)),
          greaterThanOrEqualTo(4.5),
          reason: '$tone on its pill',
        );
      }
    });
  }

  testWidgets('legacy Material colours map onto status tones', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(toneFor(ctx, Colors.red), toneColor(ctx, Tone.danger));
    expect(toneFor(ctx, Colors.orange), toneColor(ctx, Tone.warning));
    expect(toneFor(ctx, Colors.amber.shade800), toneColor(ctx, Tone.warning));
    expect(toneFor(ctx, Colors.green), toneColor(ctx, Tone.success));
    expect(toneFor(ctx, Colors.grey), toneColor(ctx, Tone.neutral));
    expect(toneFor(ctx, Colors.blueGrey), toneColor(ctx, Tone.neutral));
    // Brand colours are not status colours and stay as they are.
    expect(toneFor(ctx, navy), navy);
    expect(toneFor(ctx, teal), teal);
  });
}
