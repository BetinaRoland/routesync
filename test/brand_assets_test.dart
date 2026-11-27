import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the RouteSync outline bus sketch is present and registered', () {
    const path = 'assets/brand/routesync_bus_outline.png';
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '$path is missing');
    expect(file.lengthSync(), greaterThan(10000));
    // PNG signature, so a corrupted or replaced file is caught.
    expect(file.readAsBytesSync().sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    expect(File('pubspec.yaml').readAsStringSync(), contains(path));
  });
}
