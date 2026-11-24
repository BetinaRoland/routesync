import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:routesync/services/expenses.dart';

void main() {
  group('expense validation', () {
    ExpenseDraft draft({
      String busId = 'bus-1',
      String category = 'Fuel',
      String amount = '1250.50',
      DateTime? date,
      String description = 'Diesel refill',
    }) => ExpenseDraft(
      busId: busId,
      category: category,
      amount: amount,
      expenseDate: date ?? DateTime(2026, 6, 1),
      description: description,
    );

    test('accepts a complete expense and all predefined categories', () {
      expect(draft().validate(), isNull);
      expect(expenseCategories, hasLength(9));
      expect(
        expenseCategories,
        contains('Driver Allowances and Trip Expenses'),
      );
    });

    test(
      'requires a bus, valid category, positive amount, date and description',
      () {
        expect(draft(busId: '').validate(), 'Select a bus.');
        expect(draft(category: 'Student fees').validate(), isNotNull);
        expect(draft(amount: '0').validate(), isNotNull);
        expect(draft(amount: 'NaN').validate(), isNotNull);
        expect(
          ExpenseDraft(
            busId: 'bus-1',
            category: 'Fuel',
            amount: '1',
            expenseDate: null,
            description: 'Fuel',
          ).validate(),
          'Select an expense date.',
        );
        expect(draft(description: '  ').validate(), isNotNull);
      },
    );

    test('receipt validation checks extension and actual file signature', () {
      expect(
        isValidExpenseReceipt(Uint8List.fromList([0xff, 0xd8, 0xff, 0]), 'jpg'),
        isTrue,
      );
      expect(
        isValidExpenseReceipt(
          Uint8List.fromList([0x25, 0x50, 0x44, 0x46, 0x2d]),
          'pdf',
        ),
        isTrue,
      );
      expect(
        isValidExpenseReceipt(Uint8List.fromList([1, 2, 3]), 'png'),
        isFalse,
      );
      expect(
        isValidExpenseReceipt(Uint8List.fromList([1, 2, 3]), 'exe'),
        isFalse,
      );
    });
  });

  group('expense role permissions', () {
    test('Route Admins can manage; Super Admins can only view', () {
      expect(canManageExpenseRecords('routeAdmin'), isTrue);
      expect(canViewExpenseRecords('routeAdmin'), isTrue);
      expect(canManageExpenseRecords('superAdmin'), isFalse);
      expect(canViewExpenseRecords('superAdmin'), isTrue);
    });

    test('students and drivers have no expense access', () {
      for (final role in ['student', 'driver', 'unknown']) {
        expect(canViewExpenseRecords(role), isFalse);
        expect(canManageExpenseRecords(role), isFalse);
      }
    });
  });

  group('expense summaries', () {
    test('totals, category, bus, monthly and yearly amounts use records', () {
      final summary = ExpenseSummary.fromRecords([
        {
          'amount': 1000,
          'category': 'Fuel',
          'busNumber': '21',
          'expenseDate': Timestamp.fromDate(DateTime(2026, 5, 2)),
        },
        {
          'amount': 2500.5,
          'category': 'Maintenance and Repairs',
          'busNumber': '21',
          'expenseDate': Timestamp.fromDate(DateTime(2026, 5, 20)),
        },
        {
          'amount': 300,
          'category': 'Tolls',
          'busNumber': '34',
          'expenseDate': Timestamp.fromDate(DateTime(2025, 12, 31)),
        },
        {'amount': -5, 'category': 'Fuel', 'busNumber': '21'},
      ]);

      expect(summary.total, 3800.5);
      expect(summary.fuel, 1000);
      expect(summary.maintenance, 2500.5);
      expect(summary.other, 300);
      expect(summary.byCategory['Fuel'], 1000);
      expect(summary.byBus['21'], 3500.5);
      expect(summary.byMonth['2026-05'], 3500.5);
      expect(summary.byYear['2025'], 300);
      expect(summary.byYear['2026'], 3500.5);
    });

    test('reads the original date and note fields on legacy records', () {
      expect(
        expenseDateFrom({'date': Timestamp.fromDate(DateTime(2024, 1, 4))}),
        DateTime(2024, 1, 4),
      );
      expect(expenseDescriptionFrom({'note': 'Older cost'}), 'Older cost');
    });
  });
}
