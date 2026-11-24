import 'package:flutter_test/flutter_test.dart';
import 'package:routesync/core/widgets.dart';
import 'package:routesync/features/live_map.dart';

void main() {
  group('csvCell', () {
    test('leaves plain text alone', () => expect(csvCell('abc'), 'abc'));
    test('quotes commas', () => expect(csvCell('a,b'), '"a,b"'));
    test('doubles quotes', () => expect(csvCell('say "hi"'), '"say ""hi"""'));
    test('handles null', () => expect(csvCell(null), ''));
  });

  group('BusPos', () {
    test(
      'rejects incomplete data',
      () => expect(BusPos.from('B1', {'lat': 1.0}), isNull),
    );
    test('fresh position is live', () {
      final p = BusPos.from('B1', {
        'lat': 13.0,
        'lng': 80.0,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
      expect(p, isNotNull);
      expect(p!.stale, isFalse);
    });
    test('old position is stale', () {
      final old = DateTime.now()
          .subtract(const Duration(minutes: 5))
          .millisecondsSinceEpoch;
      expect(
        BusPos.from('B1', {'lat': 13.0, 'lng': 80.0, 'ts': old})!.stale,
        isTrue,
      );
    });
    test('uses the configured stale threshold', () {
      final old = DateTime.now()
          .subtract(const Duration(seconds: 90))
          .millisecondsSinceEpoch;
      final raw = {'lat': 13.0, 'lng': 80.0, 'ts': old};
      expect(BusPos.from('B1', raw, staleAfterSeconds: 120)!.stale, isFalse);
      expect(BusPos.from('B1', raw, staleAfterSeconds: 60)!.stale, isTrue);
    });
  });

  group('route map progress', () {
    test('handles a route without points', () {
      expect(clampRouteProgress(0, 0), 0);
    });

    test('keeps progress within available points', () {
      expect(clampRouteProgress(0, 3), 1);
      expect(clampRouteProgress(5, 3), 3);
    });
  });
}
