import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';
import 'dart:io';

void main() {
  test('RouteSync test environment is working', () {
    expect(true, isTrue);
  });

  test('boarding request query has a matching composite index', () {
    final file = File('firestore.indexes.json');
    final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final indexes = (data['indexes'] as List).cast<Map<String, dynamic>>();
    final matches = indexes.where((index) {
      if (index['collectionGroup'] != 'boardingRequests') return false;
      final fields = (index['fields'] as List).cast<Map<String, dynamic>>();
      return fields.length == 2 &&
          fields[0]['fieldPath'] == 'status' &&
          fields[0]['order'] == 'ASCENDING' &&
          fields[1]['fieldPath'] == 'submittedAt' &&
          fields[1]['order'] == 'DESCENDING';
    });
    expect(matches, isNotEmpty);
  });
}
